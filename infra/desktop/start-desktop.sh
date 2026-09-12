#!/usr/bin/env bash
# Spawn (or adopt) an agent's Xvnc display with its window manager, wallpaper and dock. Runs as
# schermes or root.
set -euo pipefail

name=${1:?usage: start-desktop.sh <name> <display>}
display=${2:?usage: start-desktop.sh <name> <display>}
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid agent name: $name" >&2; exit 2; }
[[ $display =~ ^[0-9]{1,3}$ ]] || { echo "invalid display: $display" >&2; exit 2; }

here=$(cd -- "$(dirname -- "$0")" && pwd)
user="agent-$name"
home=$(getent passwd "$user" | cut -d: -f6) || { echo "no such user: $user" >&2; exit 1; }
geometry=${SCHERMES_GEOMETRY:-1920x1200}
rfbport=$((5900 + display))
state_dir=${SCHERMES_STATE_DIR:-/var/lib/schermes}
log="$state_dir/logs/$name.log"
pidfile="$state_dir/desktops/$name.pid"

as_agent() {
  sudo -n -u "$user" env --chdir="$home" \
    HOME="$home" USER="$user" LOGNAME="$user" \
    DISPLAY=":$display" XAUTHORITY="$home/.Xauthority" "$@"
}

mkdir -p "$state_dir/logs" "$state_dir/desktops"

if as_agent xdpyinfo >/dev/null 2>&1; then
  if [ "$(as_agent xdpyinfo | awk '/dimensions:/ {print $2}')" = "$geometry" ]; then
    as_agent pgrep -u "$user" -f "Xvnc :$display( |$)" | head -1 > "$pidfile"
    echo "adopted $user display :$display (vnc 127.0.0.1:$rfbport)"
    exit 0
  fi
  # The daemon maps the model's clicks onto $geometry, so a desktop left running at another size
  # would take every click in the wrong place.
  as_agent pkill -u "$user" -f "Xvnc :$display( |$)"
  for _ in $(seq 30); do
    as_agent xdpyinfo >/dev/null 2>&1 || break
    sleep 1
  done
fi

# The probe above proved nothing is serving this display, so any lock left here is stale. The
# X server clears a stale lock only when the pid inside it is dead, and pids recycle — after a
# container restart a leftover lock can name a pid that now belongs to something else, which
# aborts Xvnc with "server is already active".
as_agent rm -f "/tmp/.X$display-lock" "/tmp/.X11-unix/X$display" || true

as_agent sh -c 'touch "$XAUTHORITY" && xauth -q -f "$XAUTHORITY" add "$DISPLAY" . "$(mcookie)"'

as_agent setsid --fork Xvnc ":$display" \
  -geometry "$geometry" -depth 24 \
  -SecurityTypes None -localhost -rfbport "$rfbport" -nolisten tcp \
  -auth "$home/.Xauthority" -desktop "schermes-$name" >>"$log" 2>&1

for _ in $(seq 30); do
  as_agent xdpyinfo >/dev/null 2>&1 && break
  sleep 1
done
as_agent xdpyinfo >/dev/null 2>&1 || { echo "Xvnc :$display did not come up; see $log" >&2; exit 1; }

# No "already running" guard: the session of a display that just died can still be exiting, and
# a guard that saw it would leave this one without a window manager.
as_agent setsid --fork openbox >>"$log" 2>&1
as_agent hsetroot -add '#0b1320' -add '#1b3350' -add '#2f5f7a' -gradient 20 >>"$log" 2>&1
as_agent setsid --fork tint2 -c "$here/tint2rc" >>"$log" 2>&1

as_agent pgrep -u "$user" -f "Xvnc :$display( |$)" | head -1 > "$pidfile"
echo "started $user display :$display (vnc 127.0.0.1:$rfbport)"
