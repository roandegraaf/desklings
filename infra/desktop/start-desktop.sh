#!/usr/bin/env bash
# Spawn (or adopt) an agent's Xvnc display plus window manager. Runs as schermes or root.
set -euo pipefail

name=${1:?usage: start-desktop.sh <name> <display>}
display=${2:?usage: start-desktop.sh <name> <display>}
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid agent name: $name" >&2; exit 2; }
[[ $display =~ ^[0-9]{1,3}$ ]] || { echo "invalid display: $display" >&2; exit 2; }

user="agent-$name"
home=$(getent passwd "$user" | cut -d: -f6) || { echo "no such user: $user" >&2; exit 1; }
geometry=${SCHERMES_GEOMETRY:-1280x800}
rfbport=$((5900 + display))
state_dir=${SCHERMES_STATE_DIR:-/var/lib/schermes}
log="$state_dir/logs/$name.log"
pidfile="$state_dir/desktops/$name.pid"

as_agent() {
  sudo -n -u "$user" env \
    HOME="$home" USER="$user" LOGNAME="$user" \
    DISPLAY=":$display" XAUTHORITY="$home/.Xauthority" "$@"
}

mkdir -p "$state_dir/logs" "$state_dir/desktops"

if as_agent xdpyinfo >/dev/null 2>&1; then
  as_agent pgrep -u "$user" -f "Xvnc :$display( |$)" | head -1 > "$pidfile"
  echo "adopted $user display :$display (vnc 127.0.0.1:$rfbport)"
  exit 0
fi

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

as_agent pgrep -u "$user" -f "openbox" >/dev/null 2>&1 || \
  as_agent setsid --fork openbox >>"$log" 2>&1

as_agent pgrep -u "$user" -f "Xvnc :$display( |$)" | head -1 > "$pidfile"
echo "started $user display :$display (vnc 127.0.0.1:$rfbport)"
