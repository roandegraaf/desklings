#!/usr/bin/env bash
# Move a permanent agent's Linux user, home and sandbox layer to a new name. Runs as root. The
# sandbox is retired first: usermod refuses a user that still has processes, and a running
# sandbox has its home bound by the old path.
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
  echo "$new already exists" >&2
  exit 3
fi

boxes=/var/lib/schermes-sandboxes
if [ -e "$boxes/$to" ]; then
  echo "$boxes/$to already exists; remove it first" >&2
  exit 3
fi

here=$(dirname -- "$(readlink -f -- "$0")")
"$here/sandbox.sh" retire "$from"
# Until the move is done the old name stays unstartable; a move that fails gives it back.
trap 'rm -f "$boxes/$from/disabled"' EXIT
if pid=$(cat "$boxes/$from/pid" 2>/dev/null) && [ -d "/proc/$pid" ] \
   && [ "$(stat -c %u "/proc/$pid")" = "$(cat "$boxes/$from/subid" 2>/dev/null)" ]; then
  echo "the sandbox of $from is still running; stop it first" >&2
  exit 1
fi

home=$(getent passwd "$old" | cut -d: -f6)
usermod --login "$new" --home "$(dirname "$home")/$new" --move-home "$old"
groupmod --new-name "$new" "$old"
[ -d "$boxes/$from" ] && mv "$boxes/$from" "$boxes/$to"
# create-agent-user.sh writes the new name's lines from the layer's recorded block.
for file in /etc/subuid /etc/subgid; do
  [ -f "$file" ] || continue
  grep -v -e "^$old:" -e "^$new:" "$file" > "$file.new" || true
  chmod 0644 "$file.new"
  mv "$file.new" "$file"
done
trap - EXIT
rm -f "$boxes/$to/disabled"
echo "$new $(getent passwd "$new" | cut -d: -f6)"
