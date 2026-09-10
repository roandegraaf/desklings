FROM debian:trixie

# install.sh first and on its own layer: it is a full apt cycle plus a Node download, and it
# must not be invalidated by a source edit.
COPY infra /opt/schermes/infra
RUN /opt/schermes/infra/install.sh

# Manifests before sources, so dependency installs are cached across source edits.
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml /opt/schermes/
COPY shared/package.json /opt/schermes/shared/
COPY daemon/package.json /opt/schermes/daemon/
RUN cd /opt/schermes && pnpm install --frozen-lockfile --prod

COPY . /opt/schermes

# setpriv execs in place, so signals from the container reach the daemon directly.
CMD ["setpriv", "--reuid", "schermes", "--regid", "schermes", "--init-groups", \
     "env", "HOME=/var/lib/schermes", "USER=schermes", "LOGNAME=schermes", \
     "node", "/opt/schermes/daemon/src/main.ts"]
