# schermes

A single self-hosted Linux machine that runs persistent AI agents. Each agent gets its own
Linux user, X display, browser and terminal, and you drive and watch all of them from one web
UI. Point it at any OpenAI-compatible model endpoint and the agents work.

MIT licensed. One repository. No Kubernetes, no container per agent, no cloud account.

## Status

Feature-complete against what it set out to be, and verified end to end only against a scripted
model endpoint. Every piece below runs in the Docker harness on every smoke run.

The desktop foundation: `install.sh` provisions a Debian 13 host, and
several agents run concurrent Xvnc desktops with their own Chromium profiles, controllable
through xdotool and observable through scrot. The daemon: a Node service under systemd that
owns the single web port, persists to SQLite, makes you set an owner password on first visit,
and stores the model provider settings with the API key encrypted at rest. Agent lifecycle:
creating an agent through the API creates its Linux user, home layout and X display, and a
restarted daemon adopts the desktops that are still running instead of respawning them. The
tool layer: through the API you can screenshot an agent's desktop, drive its mouse and keyboard,
read and write its clipboard, and run shell commands as it, with a timeout that kills the whole
process group and a background option that returns straight away. The agent loop: posting a
message to an agent reaches an OpenAI-compatible model, which calls those same tools and sees
the screenshots it asks for, and the whole exchange — every message, every tool call and its
result, every state transition — is stored and readable after a restart. Restart recovery: a
daemon killed while an agent was mid tool call comes back, answers the interrupted call so the
stored transcript is one a strict model endpoint will still accept, records that a restart
happened, and leaves the agent waiting for its owner rather than resuming on its own.

Agent-to-agent messaging and task workers: agents write to each other and to group threads,
and a permanent agent can hand a job to a disposable task worker that runs as it and reports
back. Human takeover: the agent desktops stream to the app over a WebSocket proxy on the
same port, and taking control stands the agent down until you give it back. The owner's side:
stop a turn where it stands, hand an agent a file, read and correct what it remembers, search
every thread, send a picture, see what each turn cost, and get a push on the phone when an
agent finishes, fails or asks to delete something — straight from the daemon to Apple, with
nothing in between. A new agent interviews its owner about what it is for and writes the answer as its profile,
which is in its system prompt from then on; it can put a form of questions to the owner at any
time, and the owner edits the profile from the app. The native app: log in, store the provider
settings and test them, create an agent, answer its questions, read its thread a page at a time
with Markdown and the screenshots it took inline, watch and drive its desktop, and follow what
it did.

One thing has never been run. **No real OpenAI-compatible endpoint has ever answered** — every
turn described above was served by `infra/provider-stub.py`, a scripted stand-in on loopback.

## Try it

Requires Docker. The container is a real Debian 13 host provisioned by `infra/install.sh`, and
the same image is what you deploy.

```sh
docker compose build
docker compose up -d
./infra/smoke.sh                                                  # the daemon
docker compose exec schermes /opt/schermes/infra/desktop/check.sh # the desktops
```

Then point the app at http://127.0.0.1:7777 and set the owner password.

`smoke.sh` walks the API: health, the first-run password, the second setup attempt being
refused, an unauthenticated request being rejected, login, and the settings round-trip with the
API key going in but never coming back. It then creates two agents and proves they get their own
desktops on loopback-only VNC ports, that they survive a container restart, that a second daemon
adopts them rather than respawning them, and that a desktop killed underneath the daemon comes
back. Finally it drives one of those agents: a screenshot of the bare desktop, an xterm launched
in the background, a second screenshot that differs, keystrokes that create a file inside that
xterm, a clipboard round-trip, a command reporting a non-zero exit code, a command killed at its
timeout with nothing left running, and `apt-get install`. Last, it points the provider settings
at a scripted OpenAI-compatible endpoint on loopback and posts a message: the agent screenshots
its own desktop, runs a command, and answers, and the run asserts that the model really received
the tool definitions, a bearer token and a base64 PNG, that the events describe every step, and
that the whole exchange is still there after `docker compose up --build --force-recreate` — a
container replaced from scratch, with the database, the master key, the encrypted settings and
the agents coming back out of the `/var/lib/schermes` volume, and the Linux users and their
desktops rebuilt from the surviving rows. It also reads that thread back a page at a time.
Finally it parks the second
agent inside a command that will not return, kills the daemon running that turn outright, and
asserts that a fresh daemon answers the interrupted call, repairs the agent's state, records the
restart, and leaves the agent able to finish another turn on the repaired history.

`check.sh` creates three agents, gives each a desktop and a Chromium profile, types a URL into
each browser, captures a screenshot per desktop, verifies a cookie survives a Chromium restart,
and verifies that the web port is the only socket bound outside loopback.

Both are safe to run repeatedly, including after `docker compose restart` and after
`docker compose up --build`: `/var/lib/schermes` and `/home` are named volumes, so nothing wipes the
database or the agent homes between runs and the scripts reuse the owner and the agents they find.

To work on the daemon:

```sh
pnpm install
pnpm test    # unit tests, no framework
pnpm check   # TypeScript, strict
```

## Configuration

| Variable               | Default             | Meaning                                |
| ---------------------- | ------------------- | -------------------------------------- |
| `SCHERMES_PORT`        | `7777`              | The one port schermes exposes          |
| `SCHERMES_DATA_DIR`    | `/var/lib/schermes` | SQLite database and the master key     |
| `SCHERMES_GEOMETRY`    | `1920x1200`         | Desktop size                           |
| `SCHERMES_MAX_LOOPS`   | `8`                 | Concurrent agent turns                 |
| `SCHERMES_MAX_WORKERS` | `4`                 | Concurrent task workers                |

That is all of them. The model provider is not configured here: base URL, model and API key are
set in the app and stored encrypted, and so are the web search key and the APNs key. Full reference, including the limits that are constants
rather than variables, in [docs/configuration.md](docs/configuration.md).

schermes speaks plain HTTP. For a domain, the compose file ships Caddy behind a profile:
[docs/deployment.md](docs/deployment.md#a-linked-domain).

## Layout

```
daemon/src/                          the service: HTTP, auth, secrets, agents, persistence
daemon/migrations/                   Drizzle migrations, committed and applied on boot
shared/src/                          types the daemon and its clients both use
apple/                               the native SwiftUI app for iOS and macOS
infra/install.sh                     idempotent Debian 13 provisioning
infra/schermes.service               systemd unit for the daemon
infra/smoke.sh                       runnable check for the daemon API
infra/desktop/create-agent-user.sh   create agent-<name>, home, workspace, uploads, profile
infra/desktop/start-desktop.sh       spawn or adopt an agent's Xvnc display and window manager
infra/desktop/check.sh               runnable check for the whole desktop foundation
infra/provider-stub.py               scripted OpenAI-compatible endpoint, used by smoke.sh
docs/                                architecture, deployment, configuration, troubleshooting
```

The daemon has no build step: Node 24 strips TypeScript types on load, so it runs from source
and `tsc` only type-checks. It serves no static files either — the exposed port is the API and
nothing else. The client is the native app in `apple/`; see [apple/README.md](apple/README.md)
to build it.

## Deploying

The Docker image is the deployment. Unraid runs Docker natively, so an Unraid box, a VPS or any
Linux host with the Compose plugin is the same target:

```sh
git clone <this repository> schermes && cd schermes
echo SCHERMES_BIND=0.0.0.0 > .env
docker compose up -d --build
```

Point the app at `http://<host>:7777` and set the owner password. Whoever reaches the port
first becomes the owner, so claim it promptly on a network you trust — setup succeeds exactly
once. Upgrading is `git pull` and the same `up -d --build`: the database, the master key, the
agent homes and the shared directory live in named volumes and survive it.

For a domain, put `SCHERMES_DOMAIN=schermes.example.com` and `COMPOSE_PROFILES=domain` in
`.env` instead of the bind line, and Caddy handles the certificate. The app turns a bare domain
into `https://` on its own. Steps and the Unraid port note in
[docs/deployment.md](docs/deployment.md#a-linked-domain).

A Debian 13 host without Docker works too: copy the repository to `/opt/schermes` and run
`infra/install.sh` as root, which enables the `schermes.service` unit. Full deployment notes,
including TLS and what to back up, in [docs/deployment.md](docs/deployment.md).

## Documentation

[docs/README.md](docs/README.md) is the index. The short version:
[architecture](docs/architecture.md) for why it is shaped this way,
[development](docs/development.md) to work on it, [deployment](docs/deployment.md) to run it,
[configuration](docs/configuration.md) for every knob, and
[troubleshooting](docs/troubleshooting.md) when something is already wrong.
