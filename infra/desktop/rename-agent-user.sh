#!/usr/bin/env bash
# Move a permanent agent's Linux user and home to a new name. Runs as root, with the agent's
# desktop already stopped: usermod refuses a user that still has processes.
set -euo pipefail

from=${1:?usage: rename-agent-user.sh <from> <to>}
to=${2:?usage: rename-agent-user.sh <from> <to>}
for name in "$from" "$to"; do
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid agent name: $name" >&2; exit 2; }
done
[ "$(id -u)" -eq 0 ] || { echo "rename-agent-user.sh must run as root" >&2; exit 1; }

old="agent-$from"
new="agent-$to"
id -u "$old" >/dev/null 2>&1 || { echo "no such user: $old" >&2; exit 1; }
if id -u "$new" >/dev/null 2>&1; then
  echo "$new already exists: a deleted agent's user and home stay behind; remove them first" >&2
  exit 3
fi

home=$(getent passwd "$old" | cut -d: -f6)
usermod --login "$new" --home "$(dirname "$home")/$new" --move-home "$old"
groupmod --new-name "$new" "$old"
echo "$new $(getent passwd "$new" | cut -d: -f6)"
