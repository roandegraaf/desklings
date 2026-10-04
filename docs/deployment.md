# Deployment

The Docker image is the deployment. Unraid runs Docker natively, so an Unraid box, a VPS with
Docker, or any Linux host with the Compose plugin is the same target. A Debian 13 host without
Docker is the alternative further down. Both end with the same machine, because both run
`infra/install.sh`, and that script is the only provisioning path there is.

On a Mac the same compose file is the dev harness: [development](development.md).

## Docker

```sh
git clone <this repository> schermes && cd schermes
echo SCHERMES_BIND=0.0.0.0 > .env
docker compose up -d --build
```

`SCHERMES_BIND` is the address the port is published on. It defaults to `127.0.0.1`, which is
right for a laptop and useless for a server, where nothing but the host itself could reach it.
`0.0.0.0` publishes it on every interface, so a bridged Unraid box answers at
`http://<host>:7777` from the LAN. Compose reads `.env` on its own, and git ignores it. To reach
it from anywhere else, skip that line and give it [a domain](#a-linked-domain) instead.

The build is a full apt cycle, a Node download and Chromium: several minutes and a few GB the
first time. Later builds reuse the base layer unless `infra/install.sh` changed.

Then confirm it:

```sh
./infra/smoke.sh
docker compose exec schermes /opt/schermes/infra/desktop/check.sh
docker compose logs -f schermes
```

On a fresh daemon `smoke.sh` claims the owner itself, with `SCHERMES_SMOKE_PASSWORD`, reading
the first-run setup token from the logs. To claim it with your own password, do it before
running smoke. A daemon with no owner prints the token in its log, and setup needs it:

```sh
docker compose logs schermes | grep 'first-run setup token'
# {"ts":"…","level":"info","msg":"first-run setup token","code":"<token>"}
```

Every boot without an owner prints a new one, so use the newest line. On a bare Debian host it
is in `journalctl -u schermes`. The app's setup screen asks for the password and that code.
Without the app, setup is one POST:

```sh
curl -sS http://<host>:7777/api/auth/setup -H 'content-type: application/json' \
  -d '{"password":"<at least 8 characters>","setupToken":"<token>"}'
```

Then point the app at `http://<host>:7777`, sign in, store the provider settings, and create an
agent.

### Unraid

Every push to `master` builds the image on GitHub Actions and publishes it as
`ghcr.io/roandegraaf/desklings:latest`, so Unraid pulls a finished image and never builds. In
the Docker tab, **Add Container**, switch to advanced view, and fill in:

| Field | Value |
| --- | --- |
| Repository | `ghcr.io/roandegraaf/desklings:latest` |
| Network type | Bridge |
| Port | container `7777`, host `7777` |
| Path | container `/var/lib/schermes`, host `/mnt/cache/appdata/schermes/data` |
| Path | container `/home`, host `/mnt/cache/appdata/schermes/home` |
| Path | container `/srv/schermes`, host `/mnt/cache/appdata/schermes/shared` |
| Path | container `/var/lib/schermes-sandboxes`, host `/mnt/cache/appdata/schermes/sandboxes` |
| Path (push, optional) | container `/run/secrets/AuthKey_<KEYID>.p8`, host `/mnt/cache/appdata/schermes/AuthKey_<KEYID>.p8`, read only |
| Variable (push, optional) | `SCHERMES_APNS_KEY_FILE` = `/run/secrets/AuthKey_<KEYID>.p8` |
| Extra parameters | `--hostname=schermes --init --shm-size=1g --security-opt=seccomp=unconfined --device=/dev/fuse --device=/dev/net/tun` |

The extra parameters are the load-bearing compose settings below, spelled for `docker run`.
Without the two devices every agent's sandbox fails to start, and every agent command fails
with it: an agent never falls back to running outside its sandbox. The sandboxes path holds
each agent's writable root layer and needs a filesystem with user xattrs. A btrfs or xfs pool
is fine; `/mnt/user` is not. The kernel must allow unprivileged user namespaces. See
[Architecture § Per-agent sandbox](architecture.md#per-agent-sandbox).

The paths are plain bind mounts: the entrypoint fixes their ownership on every start, so
an empty appdata directory is fine. Keep them on the pool (`/mnt/cache/...`, or whatever the
pool is called) rather than under `/mnt/user/...`: that path is a FUSE filesystem, and SQLite
memory-maps its WAL index, which FUSE handles badly. Updates are Unraid's own update button.

On first start the container's log (the Docker tab, the container's icon, **Logs**) has a
`first-run setup token` line. Claim the owner with its `code`, using the curl call above.

For push, drop the `AuthKey_<KEYID>.p8` from the developer portal into the appdata directory
(the `appdata` SMB share, or `cat > ... <<'EOF'` in the web terminal) and map it under its own
name: the daemon reads the key id off the filename, so `SCHERMES_APNS_KEY_ID` is not needed.
The daemon runs as `schermes`, not root, so the file has to be world-readable (`chmod 644`); the
appdata directory is what keeps it private. The boot log says `push key loaded`, or `push key
not read` with the reason.

Seven settings in the `schermes` service are load-bearing and have to survive any rewrite: the
four named volumes, `hostname`, `init`, `seccomp=unconfined` and the `/dev/fuse` and
`/dev/net/tun` devices.
[Architecture § Docker](architecture.md#docker) says why each one is there.

### Upgrading

```sh
git pull
docker compose up -d --build
```

Migrations are committed under `daemon/migrations/` and applied on boot, so there is no separate
migration step. The daemon runs from TypeScript source — Node 24 strips the types on load — so
there is no build step for it either. Everything durable lives in the named volumes, so the
container is disposable.

A replaced container does lose the running agent desktops and sandboxes, because they live in
its pid namespace. The daemon respawns them on boot from the database, recreates the Linux users
over their persisted homes, restarts each sandbox over its persisted layer (so packages an agent
installed are still there), and an agent caught mid tool call has that call marked interrupted and
answered, and is left waiting for you rather than resuming on its own.

## Bare Debian 13, without Docker

```sh
git clone <this repository> /opt/schermes
/opt/schermes/infra/install.sh          # as root
systemctl start schermes
```

`/opt/schermes` is not a preference. The sudoers rules the script writes name the scripts in
`/opt/schermes/infra/desktop` literally, and the daemon resolves the
desktop scripts relative to its own source path. Install it somewhere else and agent creation
fails at the first `sudo`.

The script needs root, an amd64 or arm64 Debian 13 ("trixie"), and outbound access to Debian's
mirrors, `nodejs.org` and `astral.sh`. It installs the desktop stack (TigerVNC, Openbox, tint2,
PCManFM, LXTerminal, Chromium, xdotool, scrot, xclip), Node 24, pnpm, uv, the `schermes` service
user and the `agents` group, two sudoers rules, the systemd unit and the daemon's dependencies.

Confirm it with `systemctl status schermes`, then the same `smoke.sh` and `check.sh` as above,
with `SCHERMES_URL=http://127.0.0.1:7777` set for the former. Upgrading is `git pull`, the
script again (it is idempotent, so a second run installs nothing it already has) and
`systemctl restart schermes`. That restart leaves the desktops running for the daemon to adopt.

## What to back up

Under Docker, the four named volumes, which hold the paths below:

- `schermes-data`, mounted at `/var/lib/schermes`. Both files in it matter: `schermes.db` holds
  the owner, sessions, settings, agents, conversations, messages and events, and `master.key`
  (0600, owned by `schermes`) is what decrypts the API key in the database. Backing up the
  database alone is not a backup.
- `schermes-homes`, mounted at `/home`. The agent homes under `/home/agent-*`: workspaces,
  uploads and Chromium profiles. A restore without them rebuilds the users and desktops from
  the surviving agent rows, with empty homes.
- `schermes-shared`, mounted at `/srv/schermes`. The group-writable cross-agent directory.
- `schermes-sandboxes`, mounted at `/var/lib/schermes-sandboxes`. Each agent's writable root
  layer (what it installed or changed outside its home) and the subordinate-id block it is
  owned by. Without it agents start over on a clean image.

The simplest copy is out of the running container, which reads them all as root:

```sh
docker compose cp schermes:/var/lib/schermes ./backup/data
docker compose cp schermes:/home ./backup/home
docker compose cp schermes:/srv/schermes ./backup/shared
docker compose exec -T schermes tar --xattrs --numeric-owner -C /var/lib -cf - schermes-sandboxes \
  > ./backup/sandboxes.tar
```

The layers go through `tar` because they only survive a copy that keeps numeric owners and the
overlay's xattrs. On a bare host, the same four paths straight off the disk.

## A linked domain

schermes speaks plain HTTP on one port and will not grow TLS. The compose file ships Caddy for
that instead, off by default and switched on by a profile. Four steps, in this order:

1. **Point the domain at the host.** An `A` (and, if you have one, `AAAA`) record for
   `schermes.example.com` to the public address of the box. Let's Encrypt has to be able to
   reach the name before Caddy can get a certificate for it.
2. **Let ports 80 and 443 through** to the host. On a home connection that is two port
   forwards on the router.
3. **Turn the profile on.** In `.env`, next to whatever is already there:

   ```sh
   SCHERMES_DOMAIN=schermes.example.com
   COMPOSE_PROFILES=domain
   ```

   Then `docker compose up -d`. Caddy starts, gets the certificate on its own, renews it on its
   own, and reaches the daemon over the compose network at `schermes:7777`. Leave
   `SCHERMES_BIND` out of `.env` (or at `127.0.0.1`): with a proxy in front, the daemon's own
   port has no business on the LAN.
4. **Type the domain into the app.** The connect screen turns a bare domain into `https://` by
   itself; only an IP, a single-label name or a `.local` name gets `http://`.

Confirm it from any machine:

```sh
curl https://schermes.example.com/api/health
```

**Unraid holds 80 and 443 for its own web UI.** Either move those in Unraid's settings, or
publish Caddy on other host ports and forward the router's 80 and 443 to them:

```sh
SCHERMES_HTTP_PORT=8080
SCHERMES_HTTPS_PORT=8443
```

Caddy still believes it is on 80 and 443, which is what the certificate challenge needs, and the
router makes that true from the outside.

If you already run a reverse proxy on the host, leave the profile off and point that proxy at
`127.0.0.1:7777`. It has to forward WebSocket upgrades: the desktop stream is a WebSocket on the
same port. Caddy does so unasked; with nginx, set the `Upgrade` and `Connection` headers on the
location and raise `proxy_read_timeout`, because an idle desktop stream is a long-lived socket.
On a bare host the daemon listens on `0.0.0.0`, so add a firewall rule too.

## Exposure

One port is exposed and everything else is loopback. Per-agent VNC servers bind `127.0.0.1` on
`5900 + display` and are reachable only through the daemon's proxy, which checks the session
cookie and the input-ownership state before it pipes a byte.

`infra/desktop/check.sh` asserts this: it enumerates every listening socket and fails if
anything but the web port is bound outside loopback. Run it after any change to the stack.

Do not put schermes on the public internet without a proxy that authenticates in front of it.
Agents have passwordless sudo inside their sandboxes — that is the product, not an oversight —
and the owner can tell any of them to run anything, so the owner password is the only thing
between a visitor and every agent's machine. See the
[security model](architecture.md#security-model).
