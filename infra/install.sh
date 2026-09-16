#!/usr/bin/env bash
# Idempotent provisioning for a schermes host (Debian 13 "trixie").
# Run from the Dockerfile, or as root on a fresh Debian install without Docker.
set -euo pipefail

SCHERMES_HOME=/var/lib/schermes
SHARED_DIR=/srv/schermes/shared
NODE_MAJOR=24
PNPM_VERSION=11.15.1

log() { printf '\n== %s\n' "$*"; }

here=$(cd -- "$(dirname -- "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "install.sh must run as root" >&2; exit 1; }

log "apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg sudo procps psmisc iproute2 less vim git openssh-client \
  build-essential python3 python3-venv python3-pip \
  jq ripgrep htop zip unzip tar xz-utils file poppler-utils imagemagick \
  tigervnc-standalone-server openbox xterm dbus-x11 \
  tint2 pcmanfm lxterminal hsetroot \
  x11-utils x11-xserver-utils xdotool scrot xclip xauth \
  chromium \
  fonts-dejavu fonts-liberation fonts-noto-color-emoji
rm -rf /var/lib/apt/lists/*

log "chromium defaults"
# Chromium caps a new window at 1050px wide whatever the screen size, which gets sites to serve
# their tablet layout. The Debian launcher sources every file in /etc/chromium.d.
# The debugging port is 9222 + display, loopback only; daemon/src/browser.ts derives the same
# number. It is honoured only with an explicit --user-data-dir, which every launcher here passes.
cat > /etc/chromium.d/schermes <<'EOF'
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --start-maximized"
case "$DISPLAY" in
  :[0-9]*) d="${DISPLAY#:}"; export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --remote-debugging-port=$((9222 + ${d%%.*}))" ;;
esac
EOF

log "node ${NODE_MAJOR} + pnpm"
if ! /opt/node/bin/node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
  case "$(uname -m)" in
    aarch64|arm64) node_arch=arm64 ;;
    x86_64|amd64)  node_arch=x64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  index=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/")
  tarball=$(grep -o "node-v${NODE_MAJOR}\.[0-9.]*-linux-${node_arch}\.tar\.xz" <<<"$index" | head -1)
  [ -n "$tarball" ] || { echo "could not resolve a node ${NODE_MAJOR} tarball" >&2; exit 1; }
  rm -rf /opt/node
  mkdir -p /opt/node
  curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${tarball}" \
    | tar -xJ -C /opt/node --strip-components=1
fi
# Linking outside the block above keeps the symlinks correct after a node upgrade.
for bin in node npm npx; do ln -sfn "/opt/node/bin/$bin" "/usr/local/bin/$bin"; done
# Pinned to the packageManager field of the repo's package.json, so the lockfile and the
# installer agree. Update both together.
pnpm --version 2>/dev/null | grep -qx "$PNPM_VERSION" \
  || npm install -g --silent "pnpm@${PNPM_VERSION}"
# npm installs pnpm into /opt/node/bin, which is not on PATH.
ln -sfn /opt/node/bin/pnpm /usr/local/bin/pnpm

log "uv"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh \
  | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null

log "users, groups and directories"
getent group agents >/dev/null || groupadd agents
id -u schermes >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir "$SCHERMES_HOME" --shell /bin/bash schermes
install -d -o schermes -g schermes -m 0755 \
  "$SCHERMES_HOME/desktops" "$SCHERMES_HOME/logs"
install -d -o root -g agents -m 2775 /srv/schermes "$SHARED_DIR" "$SHARED_DIR/skills"
# X clients need this before the first Xvnc starts; an unprivileged Xvnc cannot create it.
install -d -m 1777 /tmp/.X11-unix

log "sudoers"
# The daemon (schermes) may create agent users, install packages, and act as any agent user.
# create-agent-user.sh is root-owned under /opt/schermes, so this is not a path to arbitrary root.
cat > /etc/sudoers.d/schermes.tmp <<'EOF'
schermes ALL=(root) NOPASSWD: /opt/schermes/infra/desktop/create-agent-user.sh, /opt/schermes/infra/desktop/rename-agent-user.sh, /usr/bin/apt-get
schermes ALL=(%agents) NOPASSWD: ALL
EOF
# Agent users are the operators of their own machine; the spec allows passwordless sudo.
cat > /etc/sudoers.d/agents.tmp <<'EOF'
%agents ALL=(ALL) NOPASSWD: ALL
EOF
for f in schermes agents; do
  visudo -c -q -f "/etc/sudoers.d/$f.tmp"
  install -o root -g root -m 0440 "/etc/sudoers.d/$f.tmp" "/etc/sudoers.d/$f"
  rm -f "/etc/sudoers.d/$f.tmp"
done

log "daemon"
install -o root -g root -m 0644 "$here/schermes.service" /etc/systemd/system/schermes.service
# In the Docker image this runs before any source exists, so it is a no-op there and the
# Dockerfile installs dependencies in a stage of its own instead. On a real host the repository
# is already in place, which makes install.sh the single provisioning path.
# CI=true because a re-run changes which projects have a modules directory, and pnpm refuses to
# remove one without a TTY unless it is told it is unattended. It is.
if [ -f /opt/schermes/package.json ]; then
  ( cd /opt/schermes
    export CI=true
    pnpm install --frozen-lockfile --prod )
fi
# systemctl is unavailable in the Docker harness, where the daemon is the container command.
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable schermes.service
fi

log "done: $(node --version), $(chromium --version), openbox $(openbox --version | head -1 | awk '{print $2}')"
