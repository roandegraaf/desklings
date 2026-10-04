#!/usr/bin/env bash
# Create the Linux user, home layout and sandbox for a permanent agent. Idempotent. Runs as root.
set -euo pipefail

name=${1:?usage: create-agent-user.sh <name>}
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid agent name: $name" >&2; exit 2; }

user="agent-$name"
[ "$(id -u)" -eq 0 ] || { echo "create-agent-user.sh must run as root" >&2; exit 1; }

if ! id -u "$user" >/dev/null 2>&1; then
  # No automatic subordinate ids: the block below is the agent's own, recorded with its layer.
  useradd --create-home --shell /bin/bash --groups agents -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 "$user"
  # A home that outlived its user, on the /home volume under a replaced container, still
  # carries whatever uid the user had last time.
  chown -R "$user:$user" "$(getent passwd "$user" | cut -d: -f6)"
fi
usermod --append --groups agents "$user"

home=$(getent passwd "$user" | cut -d: -f6)
install -d -o "$user" -g "$user" -m 0755 \
  "$home/workspace" "$home/uploads" "$home/.chromium-profile" "$home/memory" "$home/skills"

# The sandbox's upper layer is owned by ids from this block, so the block must survive the
# container being recreated, which resets /etc/subuid. The first one assigned is recorded in the
# layer, on its own volume, and restored from there every time.
boxes=/var/lib/schermes-sandboxes
box="$boxes/$name"
install -d -m 0711 "$boxes"
install -d -o "$user" -g "$user" -m 0700 "$box"
# An agent that is still wanted, after a rename or delete that failed half-way.
rm -f "$box/disabled"
exec 8>>"$boxes/.subid.lock"
flock -w 60 8
if [ ! -s "$box/subid" ]; then
  start=100000
  while cat "$boxes"/*/subid 2>/dev/null | grep -qx "$start"; do start=$((start + 65536)); done
  echo "$start" > "$box/subid"
  chmod 0644 "$box/subid"
fi
start=$(cat "$box/subid")
[[ $start =~ ^[0-9]+$ ]] || { echo "corrupt $box/subid" >&2; exit 1; }
agents_gid=$(getent group agents | cut -d: -f3)
for file in /etc/subuid /etc/subgid; do
  want="$user:$start:65536"
  [ "$file" = /etc/subgid ] && want="$want"$'\n'"$user:$agents_gid:1"
  if [ "$(grep "^$user:" "$file" 2>/dev/null || true)" != "$want" ]; then
    { grep -v "^$user:" "$file" 2>/dev/null || true; printf '%s\n' "$want"; } > "$file.new"
    chmod 0644 "$file.new"
    mv "$file.new" "$file"
  fi
done
exec 8>&-

# A recreated container hands out uids afresh, so the agent can come back under another uid
# than the one its layer's files carry. The lock is always created as the agent, which makes its
# owner the record of the old one. Inside the sandbox the agent's uid maps to itself, so the
# files it owns there move with it.
uid=$(id -u "$user")
gid=$(id -g "$user")
if [ -e "$box/lock" ] && read -r old_uid old_gid < <(stat -c '%u %g' "$box/lock") \
   && [ "$old_uid:$old_gid" != "$uid:$gid" ]; then
  find "$box" -xdev -uid "$old_uid" -exec chown -h "$uid" {} +
  find "$box" -xdev -gid "$old_gid" -exec chgrp -h "$gid" {} +
fi

"$(dirname -- "$(readlink -f -- "$0")")/sandbox.sh" setup "$name" >/dev/null

echo "$user $home"
