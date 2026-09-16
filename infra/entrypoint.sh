#!/bin/sh
# Bind mounts arrive as empty root-owned directories; give them the ownership install.sh set
# on the image before dropping to the daemon user. Named volumes already carry it; this is a no-op there.
set -eu
chown schermes:schermes /var/lib/schermes
install -d -o schermes -g schermes -m 0755 /var/lib/schermes/desktops /var/lib/schermes/logs
install -d -o root -g agents -m 2775 /srv/schermes /srv/schermes/shared /srv/schermes/shared/skills

# setpriv execs in place, so signals from the container reach the daemon directly.
exec setpriv --reuid schermes --regid schermes --init-groups \
  env HOME=/var/lib/schermes USER=schermes LOGNAME=schermes \
  node /opt/schermes/daemon/src/main.ts
