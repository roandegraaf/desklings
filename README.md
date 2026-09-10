# schermes

A single self-hosted Linux machine that runs persistent AI agents. Each agent gets its own
Linux user, X display, browser and terminal, and you drive and watch all of them from one web
UI. Point it at any OpenAI-compatible model endpoint and the agents work.

MIT licensed. One repository. No Kubernetes, no container per agent, no cloud account.

## Status

Early. Three pieces work. The desktop foundation: `install.sh` provisions a Debian 13 host, and
several agents run concurrent Xvnc desktops with their own Chromium profiles, controllable
through xdotool and observable through scrot. The daemon: a Node service under systemd that
owns the single web port, persists to SQLite, makes you set an owner password on first visit,
and stores the model provider settings with the API key encrypted at rest. Agent lifecycle:
creating an agent through the API creates its Linux user, home layout and X display, and a
restarted daemon adopts the desktops that are still running instead of respawning them.

Model calls, computer use and the UI are not built yet.

## Try the dev harness

Requires Docker. The container is a real Debian 13 host provisioned by the same
`infra/install.sh` that a VM or VPS would run.

```sh
docker compose build
docker compose up -d
./infra/smoke.sh                                                  # the daemon
docker compose exec schermes /opt/schermes/infra/desktop/check.sh # the desktops
```

`smoke.sh` walks the API: health, the first-run password, the second setup attempt being
refused, an unauthenticated request being rejected, login, and the settings round-trip with the
API key going in but never coming back. It then creates two agents and proves they get their own
desktops on loopback-only VNC ports, that they survive a container restart, that a second daemon
adopts them rather than respawning them, and that a desktop killed underneath the daemon comes
back.

`check.sh` creates three agents, gives each a desktop and a Chromium profile, types a URL into
each browser, captures a screenshot per desktop, verifies a cookie survives a Chromium restart,
and verifies that the web port is the only socket bound outside loopback.

Both are safe to run repeatedly, including after `docker compose restart`.

To work on the daemon:

```sh
pnpm install
pnpm test    # unit tests, no framework
pnpm check   # TypeScript, strict
```

## Configuration

| Variable             | Default              | Meaning                             |
| -------------------- | -------------------- | ----------------------------------- |
| `SCHERMES_PORT`      | `7777`               | The one port schermes exposes       |
| `SCHERMES_DATA_DIR`  | `/var/lib/schermes`  | SQLite database and the master key   |

schermes speaks plain HTTP. Put Caddy or nginx in front of it for TLS.

## Layout

```
daemon/src/                          the service: HTTP, auth, secrets, agents, persistence
daemon/migrations/                   Drizzle migrations, committed and applied on boot
shared/src/                          types the daemon and the future UI both use
infra/install.sh                     idempotent Debian 13 provisioning
infra/schermes.service               systemd unit for the daemon
infra/smoke.sh                       runnable check for the daemon API
infra/desktop/create-agent-user.sh   create agent-<name>, home, workspace, uploads, profile
infra/desktop/start-desktop.sh       spawn or adopt an agent's Xvnc display and window manager
infra/desktop/check.sh               runnable check for the whole desktop foundation
docs/architecture.md                 decisions, with requirement / recommendation / deferred tags
```

There is no build step. Node 24 strips TypeScript types on load, so the daemon runs from
source and `tsc` only type-checks.

## Deploying to a real machine

Install Debian 13, copy this repository to `/opt/schermes`, and run `infra/install.sh` as
root. It provisions the host, installs the daemon's dependencies, and enables the
`schermes.service` unit. The script is idempotent, so re-running it after an update is the
upgrade path.

```sh
systemctl start schermes
SCHERMES_URL=http://127.0.0.1:7777 /opt/schermes/infra/smoke.sh
```
