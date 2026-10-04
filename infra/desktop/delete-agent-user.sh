#!/usr/bin/env bash
# Remove a permanent agent's Linux user, home, sandbox layer and subordinate ids, so a new agent
# with the same name starts empty. Runs as root. Idempotent: every step tolerates having been
# done already, so a delete that failed half-way is finished by running it again.
set -euo pipefail

name=${1:?usage: delete-agent-user.sh <name>}
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid agent name: $name" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "delete-agent-user.sh must run as root" >&2; exit 1; }

user="agent-$name"
boxes=/var/lib/schermes-sandboxes
box="$boxes/$name"
here=$(dirname -- "$(readlink -f -- "$0")")

"$here/sandbox.sh" retire "$name"

if id -u "$user" >/dev/null 2>&1; then
  home=$(getent passwd "$user" | cut -d: -f6)
  [ "$home" = "/home/$user" ] || { echo "refusing: $user has home $home, not /home/$user" >&2; exit 1; }
  # --force: a daemon `enter` racing the retire is an agent-uid process for a moment.
  userdel --force "$user"
fi
getent group "$user" >/dev/null && groupdel "$user"
rm -rf --one-file-system -- "/home/$user"

exec 8>>"$boxes/.subid.lock"
flock -w 60 8
rm -rf --one-file-system -- "$box"
for file in /etc/subuid /etc/subgid; do
  [ -f "$file" ] && grep -q "^$user:" "$file" || continue
  grep -v "^$user:" "$file" > "$file.new" || true
  chmod 0644 "$file.new"
  mv "$file.new" "$file"
done
exec 8>&-

echo "removed $user"
