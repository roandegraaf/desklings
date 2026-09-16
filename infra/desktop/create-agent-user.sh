#!/usr/bin/env bash
# Create the Linux user and home layout for a permanent agent. Idempotent. Runs as root.
set -euo pipefail

name=${1:?usage: create-agent-user.sh <name>}
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid agent name: $name" >&2; exit 2; }

user="agent-$name"
[ "$(id -u)" -eq 0 ] || { echo "create-agent-user.sh must run as root" >&2; exit 1; }

if ! id -u "$user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups agents "$user"
  # A home that outlived its user, on the /home volume under a replaced container, still
  # carries whatever uid the user had last time.
  chown -R "$user:$user" "$(getent passwd "$user" | cut -d: -f6)"
fi
usermod --append --groups agents "$user"

home=$(getent passwd "$user" | cut -d: -f6)
install -d -o "$user" -g "$user" -m 0755 \
  "$home/workspace" "$home/uploads" "$home/.chromium-profile" "$home/memory" "$home/skills"

echo "$user $home"
