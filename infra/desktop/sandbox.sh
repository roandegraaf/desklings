#!/usr/bin/env bash
# The per-agent sandbox: an unprivileged user namespace with the agent's subordinate ids,
# fuse-overlayfs over the container root, private mounts and pasta networking. See
# docs/architecture.md, "Per-agent sandbox". Only `setup` and `retire` run as root; the rest run
# as the agent user itself (`sudo -n -u agent-<name> sandbox.sh ...`), and the only privilege it
# leans on is newuidmap/newgidmap carrying file capabilities.
#
#   sandbox.sh setup <name>          as root: layer dir and copies of root-only files
#   sandbox.sh start                 start or adopt the caller's sandbox and its network
#   sandbox.sh forward <display>     carry 127.0.0.1:5900+display and 9222+display into it
#   sandbox.sh unforward <display>
#   sandbox.sh enter <cmd...>        run cmd inside as the agent, starting the sandbox if needed
#   sandbox.sh stop                  everything the agent runs, its sandbox and network, stopped
#   sandbox.sh retire <name>         as root: stop it for good, until create-agent-user.sh runs
set -euo pipefail

boxes=/var/lib/schermes-sandboxes
self=$(readlink -f -- "$0")

usage() { sed -n '8,14p' "$self" >&2; exit 2; }
die() { echo "sandbox: $*" >&2; exit 1; }

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

agent() {
  name=$1
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid agent name: $name"
  user="agent-$name"
  uid=$(id -u "$user") || exit 1
  gid=$(id -g "$user")
  agents_gid=$(getent group agents | cut -d: -f3)
  home=$(getent passwd "$user" | cut -d: -f6)
  box="$boxes/$name"
  su=$(sub_start /etc/subuid)
  sg=$(sub_start /etc/subgid)
  [ -n "$su" ] && [ -n "$sg" ] || die "$user has no 65536-id block in /etc/subuid and /etc/subgid"
}

caller_agent() {
  local me
  me=$(id -un)
  [[ $me =~ ^agent-(.+)$ ]] || die "must run as an agent user, not $me"
  agent "${BASH_REMATCH[1]}"
}

sub_start() { awk -F: -v u="$user" '$1 == u && $3 >= 65536 { print $2; exit }' "$1"; }

lock() {
  exec 9>>"$box/lock"
  flock -w 120 9 || die "timed out waiting for the lock on $box"
}

# Every process the sandbox starts is handed fd 9 closed: an inherited lock fd would keep the
# lock held for as long as the sandbox lives.
unlock() { exec 9>&-; }

holder_pid() {
  local pid
  pid=$(cat "$box/pid" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$su" ] || return 1
  [ "$(readlink "/proc/$pid/ns/user")" != "$(readlink /proc/self/ns/user)" ] || return 1
  echo "$pid"
}

# Pid files outlive a container restart, and pids are recycled.
pasta_pid() {
  local pid
  pid=$(cat "$1" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  [[ $(cat "/proc/$pid/comm" 2>/dev/null) == pasta* ]] || return 1
  [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$uid" ] || return 1
  echo "$pid"
}

in_block() { [ "$1" -ge "$su" ] && [ "$1" -lt $((su + 65536)) ]; }

block_pids() { ps -eo pid=,uid= | while read -r p u; do in_block "$u" && echo "$p"; done; true; }

# Kills the given pids and waits until they are gone; with --block, every process in the
# sandbox's id block as well. Two fuse-overlayfs daemons on one upper layer corrupt it, so
# nothing may start again before the old one has exited.
reap() {
  local p left block=false
  [ "${1:-}" = --block ] && { block=true; shift; }
  # shellcheck disable=SC2046
  $block && set -- "$@" $(block_pids)
  [ $# -gt 0 ] && kill -TERM "$@" 2>/dev/null || true
  for i in $(seq 100); do
    left=
    for p in "$@" $($block && block_pids); do kill -0 "$p" 2>/dev/null && left="$left $p"; done
    [ -z "$left" ] && return 0
    [ "$i" -eq 50 ] && kill -KILL $left 2>/dev/null || true
    sleep 0.1
  done
  die "processes of sandbox $name did not exit:$left"
}

map_args() {
  # Inner root and the system ids 1-999 that packages create come from the agent's subordinate
  # block, as do 60000-65534 for the few packages that pick ids up there. The agent keeps its
  # own uid inside, so its home has the same owner on both sides, and Chromium, which refuses to
  # run as root with its sandbox on, runs as a normal user.
  echo "--map-users=0:$su:1000 --map-users=$uid:$uid:1 --map-users=60000:$((su + 1000)):5535" \
       "--map-groups=0:$sg:1000 --map-groups=$gid:$gid:1 --map-groups=$agents_gid:$agents_gid:1" \
       "--map-groups=60000:$((sg + 1000)):5535"
}

network_up() {
  pasta_pid "$box/pasta.pid" >/dev/null && return 0
  rm -f "$box/pasta.pid"
  # --no-map-gw keeps the container's loopback out of reach from inside; -t/-u/-T/-U none
  # forward nothing. pasta answers DNS on 169.254.1.1, which the inner resolv.conf names.
  pasta --config-net --no-map-gw --no-netns-quit --quiet --pid "$box/pasta.pid" --dns-forward 169.254.1.1 \
    -t none -u none -T none -U none --userns "/proc/$1/ns/user" --netns "/proc/$1/ns/net" 9>&-
}

# Called with the lock held. A holder that is gone may have left processes in its namespaces
# and pastas bound to its ports; they go before anything new starts.
start_locked() {
  local pid own p u leftovers=
  if pid=$(holder_pid); then
    network_up "$pid"
    echo "adopted sandbox $name (pid $pid)" >&2
    return 0
  fi
  # Root sets this, under the lock, before a delete or a rename stops the sandbox: an `enter`
  # landing after the stop would otherwise bring it straight back.
  [ ! -e "$box/disabled" ] || die "sandbox $name is being removed or renamed"
  own=$(readlink /proc/self/ns/mnt)
  while read -r p u; do
    [ "$u" = "$uid" ] && [ "$p" != $$ ] || continue
    if [[ $(cat "/proc/$p/comm" 2>/dev/null) == pasta* ]] \
       || [ "$(readlink "/proc/$p/ns/mnt" 2>/dev/null || echo "$own")" != "$own" ]; then
      leftovers="$leftovers $p"
    fi
  done < <(ps -eo pid=,uid=)
  # shellcheck disable=SC2086
  reap --block $leftovers
  rm -f "$box/pid" "$box/pasta.pid" "$box"/ports.*.pid
  # shellcheck disable=SC2046
  setsid --fork unshare --user $(map_args) --setuid 0 --setgid 0 \
    --mount --propagation private --net --uts --ipc -- "$self" inner "$name" </dev/null >>"$box/log" 2>&1 9>&-
  for _ in $(seq 100); do pid=$(holder_pid) && break; sleep 0.1; done
  pid=$(holder_pid) || { tail -5 "$box/log" >&2; die "sandbox $name did not come up; see $box/log"; }
  network_up "$pid"
  echo "started sandbox $name (pid $pid)" >&2
}

# setup copies these out of the container's root-only files; the sandbox's own entries for the
# names the container does not know (system users a package added inside) are kept.
merge_accounts() {
  local file up
  for file in /etc/passwd /etc/group /etc/shadow /etc/gshadow; do
    up="$box/upper$file"
    [ -f "$up" ] || continue
    # Agent users are the container's to manage: a renamed or deleted one must not linger.
    awk -F: 'NR == FNR { seen[$1] = 1; print; next } !($1 in seen) && $1 !~ /^agent-/' "$file" "$up" > "$box/merge.tmp"
    cat "$box/merge.tmp" > "$up"
    rm -f "$box/merge.tmp"
  done
}

case $cmd in
setup)
  [ "$(id -u)" -eq 0 ] || die "setup must run as root"
  agent "${1:?usage: sandbox.sh setup <name>}"
  install -d -m 0711 "$boxes"
  install -d -o "$user" -g "$user" -m 0700 "$box"
  [ -e "$box/lock" ] || install -o "$user" -g "$user" -m 0600 /dev/null "$box/lock"
  lock
  install -d -o "$su" -g "$sg" -m 0755 "$box/upper"
  # Writing into a live upper layer is undefined for fuse-overlayfs; the refresh waits for the
  # next start from cold (a container restart, a rename).
  if holder_pid >/dev/null; then echo "set up $box (running, not refreshed)"; exit 0; fi

  # fuse-overlayfs reads the lower layer as the sandbox root's outside uid, so root-only files
  # (shadow, apt and dpkg locks) are unreadable through it. A readable copy goes into the upper
  # layer, owned by the matching id inside. A copy the agent has not changed since is refreshed,
  # so an image update reaches it; one it changed is its own.
  declare -A copied=()
  if [ -f "$box/setup.sums" ]; then
    while read -r sum path; do copied[$path]=$sum; done < "$box/setup.sums"
  fi
  inner_id() { if [ "$1" -lt 1000 ]; then echo $(($2 + $1)); else echo "$1"; fi; }
  : > "$box/setup.sums.new"
  while read -r path; do
    parent=
    for part in $(dirname "$path" | tr / ' '); do
      parent="$parent/$part"
      [ -d "$box/upper$parent" ] || install -d -m "$(stat -c %a "$parent")" -o "$su" -g "$sg" "$box/upper$parent"
    done
    target="$box/upper$path"
    if [ -d "$path" ]; then
      [ -d "$target" ] || mkdir "$target"
    else
      if [ -e "$target" ]; then
        current=$(sha256sum < "$target" | cut -d' ' -f1)
        if [ "${copied[$path]:-}" != "$current" ]; then
          [ -n "${copied[$path]:-}" ] && printf '%s %s\n' "${copied[$path]}" "$path" >> "$box/setup.sums.new"
          continue
        fi
      fi
      cp --preserve=mode,timestamps "$path" "$target"
      printf '%s %s\n' "$(sha256sum < "$target" | cut -d' ' -f1)" "$path" >> "$box/setup.sums.new"
    fi
    chmod "$(stat -c %a "$path")" "$target"
    chown "$(inner_id "$(stat -c %u "$path")" "$su"):$(inner_id "$(stat -c %g "$path")" "$sg")" "$target"
  done < <(find / -xdev \( -path /proc -o -path /sys -o -path /home -o -path /srv -o -path /tmp \
      -o -path /run -o -path /root -o -path /opt/schermes -o -path /var/lib/schermes \
      -o -path /etc/sudoers.d -o -path "$boxes" \) -prune \
      -o \( -type f -o -type d \) ! -perm -o+r -print)
  mv "$box/setup.sums.new" "$box/setup.sums"
  merge_accounts

  # The sandbox's sudoers is its own: the container's sudoers.d grants host root and stays out.
  printf '%s\n' 'Defaults env_reset' 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
    'root ALL=(ALL:ALL) ALL' '%agents ALL=(ALL:ALL) NOPASSWD: ALL' > "$box/upper/etc/sudoers"
  chown "$su:$sg" "$box/upper/etc/sudoers"
  chmod 0440 "$box/upper/etc/sudoers"
  echo "set up $box"
  ;;

start)
  caller_agent
  lock
  start_locked
  ;;

forward|unforward)
  display=${1:?usage: sandbox.sh $cmd <display>}
  [[ $display =~ ^[0-9]{1,3}$ ]] || die "invalid display: $display"
  caller_agent
  lock
  pidfile="$box/ports.$display.pid"
  if [ "$cmd" = unforward ]; then
    # Display numbers are recycled, and the next agent's forwarder needs these ports free.
    if p=$(pasta_pid "$pidfile"); then reap "$p"; fi
    rm -f "$pidfile"
    exit 0
  fi
  pid=$(holder_pid) || die "sandbox $name is not running"
  pasta_pid "$pidfile" >/dev/null && exit 0
  rm -f "$pidfile"
  # A second pasta per display, ports only: the daemon keeps talking to 127.0.0.1:5900+n and
  # 9222+n on the container's loopback, and --host-lo-to-ns-lo splices those into the
  # sandbox's own loopback, where -localhost Xvnc and Chromium listen.
  pasta --no-map-gw --no-netns-quit --host-lo-to-ns-lo --quiet --pid "$pidfile" -I "fwd$display" \
    -t "127.0.0.1/$((5900 + display))" -t "127.0.0.1/$((9222 + display))" \
    -u none -T none -U none --userns "/proc/$pid/ns/user" --netns "/proc/$pid/ns/net" 9>&-
  ;;

enter)
  [ $# -gt 0 ] || usage
  caller_agent
  if ! pid=$(holder_pid); then
    lock
    start_locked
    unlock
    pid=$(holder_pid) || die "sandbox $name is not running"
  fi
  # No --root/--wd: the FUSE root admits only callers already inside the namespace, and
  # entering the mount namespace sets the root anyway.
  exec nsenter --target "$pid" --user --mount --net --uts --ipc \
    setpriv --reuid "$uid" --regid "$gid" --init-groups --inh-caps=-all -- "$@"
  ;;

stop)
  caller_agent
  lock
  for f in "$box/pasta.pid" "$box"/ports.*.pid; do
    if p=$(pasta_pid "$f"); then kill "$p" 2>/dev/null || true; fi
  done
  # Everything the agent runs, in the sandbox or outside it, as the old `pkill -u` did.
  # shellcheck disable=SC2046
  reap --block $(ps -eo pid=,uid= | awk -v me=$$ -v uid="$uid" '$2 == uid && $1 != me { print $1 }')
  rm -f "$box/pid" "$box/pasta.pid" "$box"/ports.*.pid
  echo "stopped sandbox $name" >&2
  ;;

retire)
  [ "$(id -u)" -eq 0 ] || die "retire must run as root"
  name=${1:?usage: sandbox.sh retire <name>}
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid agent name: $name"
  user="agent-$name"
  box="$boxes/$name"
  uid=$(id -u "$user" 2>/dev/null) || exit 0
  block=$(cat "$box/subid" 2>/dev/null || true)
  [[ $block =~ ^[0-9]+$ ]] || block=-65536
  if [ -d "$box" ]; then
    # Under the lock, so no start is half-way through; released before `stop`, which takes it.
    exec 9>>"$box/lock"
    flock -w 120 9 || die "timed out waiting for the lock on $box"
    install -o root -g root -m 0644 /dev/null "$box/disabled"
    exec 9>&-
    runuser -u "$user" -- "$self" stop || echo "sandbox: stop of $name failed; killing what is left" >&2
  fi
  # The daemon keeps calling `enter` (search, idle, triggers), and each call is an agent-uid
  # process until the marker turns it away. usermod and userdel want none.
  for _ in $(seq 100); do
    left=$(ps -eo pid=,uid= | awk -v uid="$uid" -v lo="$block" \
      '$2 == uid || ($2 >= lo && $2 < lo + 65536) { print $1 }')
    [ -z "$left" ] && break
    # shellcheck disable=SC2086
    kill -KILL $left 2>/dev/null || true
    sleep 0.1
  done
  [ -z "$left" ] || die "processes of $user did not exit:" $left
  echo "retired sandbox $name" >&2
  ;;

inner)
  # Runs as root of the new user namespace, still on the container's root.
  agent "${1:?}"
  root="$box/root"
  mkdir -p "$box/upper" "$box/work" "$root" "$box/var-tmp"
  # Kernel overlayfs refuses the container root as a lower layer from here ("failed to clone
  # lowerpath": it has locked child mounts); fuse-overlayfs reads it by path instead.
  # squash_to_root shows the host's root-owned files as owned by the sandbox's root, which is
  # what dpkg and sudo expect. nosuid because on this kernel execve of any file on a FUSE mount
  # made in a user namespace fails with EINVAL unless the mount is nosuid.
  fuse-overlayfs -o "lowerdir=/,upperdir=$box/upper,workdir=$box/work,squash_to_root,nosuid" "$root"

  mount -t tmpfs -o mode=0755 tmpfs "$root/home"
  mkdir -p "$root$home" && mount --bind "$home" "$root$home"
  mount -t tmpfs -o mode=0755 tmpfs "$root/srv"
  mkdir -p "$root/srv/schermes/shared" && mount --bind /srv/schermes/shared "$root/srv/schermes/shared"
  for hidden in /var/lib/schermes /var/lib/schermes-sandboxes /opt/schermes; do
    [ -d "$root$hidden" ] && mount -t tmpfs -o mode=0755,size=1m tmpfs "$root$hidden"
  done
  # The dock's launchers and tint2rc name files here; the rest of /opt/schermes stays hidden.
  desktop_dir=$(dirname "$self")
  mkdir -p "$root$desktop_dir"
  mount --bind "$desktop_dir" "$root$desktop_dir"
  mount -o remount,bind,ro "$root$desktop_dir"
  mount --rbind /proc "$root/proc"
  mount --rbind /sys "$root/sys"
  mount --rbind /dev "$root/dev"
  mount -t tmpfs -o mode=1777,size=1g tmpfs "$root/dev/shm"
  mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$root/dev/pts"
  mount --bind "$root/dev/pts/ptmx" "$root/dev/ptmx"
  mount -t tmpfs -o mode=1777 tmpfs "$root/tmp"
  # X clients need this before the first Xvnc starts; an unprivileged Xvnc cannot create it.
  install -d -m 1777 "$root/tmp/.X11-unix"
  mount -t tmpfs -o mode=0755 tmpfs "$root/run"
  chmod 1777 "$box/var-tmp" && mount --bind "$box/var-tmp" "$root/var/tmp"
  # pasta answers DNS on the address it configures; Docker's 127.0.0.11 is not reachable here.
  printf 'nameserver 169.254.1.1\n' > "$box/resolv.conf"
  mount --bind "$box/resolv.conf" "$root/etc/resolv.conf"
  # The root is nosuid, so sudo runs from a setuid copy on the sandbox's own /run tmpfs.
  mkdir -p "$root/run/sandbox"
  install -m 4755 "$root/usr/bin/sudo" "$root/run/sandbox/sudo"
  mount --bind "$root/run/sandbox/sudo" "$root/usr/bin/sudo"

  # The pivot happens in a nested mount namespace: pivot_root moves the root of every process
  # in its namespace, and a fuse-overlayfs daemon moved onto its own mount deadlocks in D state.
  exec unshare --mount --propagation private -- "$self" pivot "$name"
  ;;

pivot)
  agent "${1:?}"
  echo $$ > "$box/pid"
  # pivot_root rather than chroot: the kernel refuses CLONE_NEWUSER inside a chroot, and
  # Chromium's own sandbox needs it.
  mkdir "$box/root/run/oldroot"
  cd "$box/root"
  pivot_root . run/oldroot
  cd /
  umount --lazy /run/oldroot
  rmdir /run/oldroot
  exec sleep infinity
  ;;

*) usage ;;
esac
