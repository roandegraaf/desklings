#!/usr/bin/env bash
# Idempotent provisioning for a schermes host (Debian 13 "trixie").
# Run as root on a fresh Debian install, or from the Dockerfile for the dev harness.
set -euo pipefail

SCHERMES_HOME=/var/lib/schermes
SHARED_DIR=/srv/schermes/shared
NODE_MAJOR=24

log() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "install.sh must run as root" >&2; exit 1; }

log "apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg sudo procps psmisc iproute2 less vim git openssh-client \
  build-essential python3 python3-venv python3-pip \
  jq ripgrep htop zip unzip tar xz-utils file poppler-utils imagemagick \
  tigervnc-standalone-server openbox xterm dbus-x11 \
  x11-utils x11-xserver-utils xdotool scrot xclip xauth \
  chromium \
  fonts-dejavu fonts-liberation fonts-noto-color-emoji
rm -rf /var/lib/apt/lists/*

log "node ${NODE_MAJOR} + pnpm"
if ! node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
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
  ln -sfn /opt/node/bin/node /usr/local/bin/node
  ln -sfn /opt/node/bin/npm /usr/local/bin/npm
  ln -sfn /opt/node/bin/npx /usr/local/bin/npx
fi
command -v pnpm >/dev/null || npm install -g --silent pnpm

log "uv"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh \
  | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null

log "users, groups and directories"
getent group agents >/dev/null || groupadd agents
id -u schermes >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir "$SCHERMES_HOME" --shell /bin/bash schermes
install -d -o schermes -g schermes -m 0755 \
  "$SCHERMES_HOME/desktops" "$SCHERMES_HOME/logs"
install -d -o root -g agents -m 2775 /srv/schermes "$SHARED_DIR"
# X clients need this before the first Xvnc starts; an unprivileged Xvnc cannot create it.
install -d -m 1777 /tmp/.X11-unix

log "sudoers"
# The daemon (schermes) may create agent users, install packages, and act as any agent user.
# create-agent-user.sh is root-owned under /opt/schermes, so this is not a path to arbitrary root.
cat > /etc/sudoers.d/schermes.tmp <<'EOF'
schermes ALL=(root) NOPASSWD: /opt/schermes/infra/desktop/create-agent-user.sh, /usr/bin/apt-get
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

log "done: $(node --version), $(chromium --version), openbox $(openbox --version | head -1 | awk '{print $2}')"
