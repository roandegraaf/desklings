# Progress — schermes-mvp

## Current state
The desktop foundation, the daemon spine, the agent lifecycle and the tool layer are committed.
Creating an agent through the API creates its Linux user, home layout and Xvnc desktop; the
daemon adopts live desktops on restart. Through the API you can now screenshot an agent's
desktop, drive its mouse and keyboard, use its clipboard and run shell commands as it. Nothing
calls a model yet and there is no UI.

**Invariants future slices must respect**
- `infra/install.sh` is the single provisioning path. The Docker harness and a real VM run the
  same script. It must stay idempotent — re-running it is the upgrade path.
- The daemon runs as the unprivileged system user `schermes`. Its only root powers are
  `create-agent-user.sh` and `apt-get`; it becomes agent users via `sudo -u agent-<name>`,
  authorised by the `%agents` runas rule. Do not widen this without recording why.
- Agent users are `agent-<name>` where name matches `^[a-z0-9][a-z0-9-]{0,30}$`. Validate at
  every boundary that accepts a name.
- One `Xvnc` per agent, VNC on `5900 + display`, loopback only, spawned detached with `setsid`.
  Desktops outlive the daemon. `start-desktop.sh` prints `adopted` or `started` and the daemon
  reads that word rather than probing itself. No per-agent systemd units.
- **Display ranges are partitioned.** The daemon allocates from `:1` up; `check.sh` owns
  `:101`-`:103`. A new script that spawns desktops needs its own range.
- **`docker compose restart` cannot demonstrate adoption**: it destroys the container's pid
  namespace. Only a second daemon against the same database reaches the adopt path.
- Every command run as an agent carries `HOME`, `USER`, `LOGNAME`, `DISPLAY` and `XAUTHORITY`
  explicitly — `sudo` strips them — and `env --chdir` before them. `daemon/src/agents.ts`'s
  `asAgent()` is the one place that assembles this; do not hand-roll a second one.
- **Anything that detaches must drop the daemon's stdout pipe.** `close` fires on stdio EOF, not
  on exit, so a child holding the pipe hangs the request. Detach through the terminal tool's
  `background` option, or use an `exec` redirect inside the shell — a redirect on the *command*
  leaves the shell itself holding the pipe. This bit `xclip` and the background command.
- **`redact()` has no `Buffer` branch**, so an exec result passed to `log` explodes into per-byte
  JSON. Routes log the exit code and the action name, never the result. Nothing enforces this.
- **All shell access goes through `daemon/src/exec.ts`.** Modules above it take it as a
  parameter, which is what lets tests assert the exact argv. Tools are deliberately *not* behind
  a `ComputerOps`-style object: a capability-level fake would hide the argv.
- **No build step.** Node 24 strips types on load; the container runs `daemon/src/main.ts` from
  source. Never introduce `dist/`. Paths resolve from `import.meta.dirname`.
- The auth guard is registered before any route and denies by default.
- Only the web port may bind off loopback. `check.sh` compares the full `address:port`.
- The pinned pnpm version moves together in `package.json`, `install.sh` and `pnpm-lock.yaml`.
- `docker compose exec schermes /opt/schermes/infra/desktop/check.sh` and `./infra/smoke.sh`
  must both keep exiting 0, and both must stay re-runnable.

**Key files**
```
daemon/src/{main,app,auth,agents,secrets,settings,db,schema,config,log}.ts   the service
daemon/src/{exec,computer,terminal}.ts   the tool layer: spawn boundary, desktop, shell
daemon/migrations/                   Drizzle migrations, committed, applied on boot
shared/src/index.ts                  API contract types
infra/install.sh                     provisioning: packages, node 24, uv, users, sudoers, unit
infra/smoke.sh                       runnable check for the API, agent lifecycle and tools
infra/desktop/*.sh                   per-agent user creation, desktop spawn/adopt, check.sh
docs/architecture.md                 decisions, tagged requirement / recommendation / deferred
```

**Gotchas already paid for** — see `docs/architecture.md`: Chromium's `SIGTERM` path does not
flush pending cookie writes, and only the browser process should be signalled; Docker's DNS
resolver listens on `127.0.0.11`, which is loopback; scrypt above N=16384 exceeds Node's default
32 MiB `maxmem`; a `Secure` session cookie would be dropped over the plain HTTP schermes speaks;
a killed X server leaves `/tmp/.X<n>-lock` behind; `ss -p` shows no pids in this container
because Docker does not grant `CAP_SYS_PTRACE`; `scrot -` opens `/dev/stdout` **by path**, which
an agent user cannot do across a uid change, so captures land in the agent's home and are
`cat`'d back; a bare Openbox desktop screenshots to roughly 3 KB, so any size floor above ~4100
base64 characters is a false failure.

## Slice 1: desktop foundation
- Shipped: `infra/install.sh` provisions Debian 13 (X11/Xvnc, Openbox, Chromium, xdotool,
  scrot, xclip, Node 24, pnpm, uv, python3, dev tooling), creates the `schermes` service user,
  the `agents` group, `/srv/schermes/shared` and the sudoers rules. `create-agent-user.sh` and
  `start-desktop.sh` build and run per-agent desktops. `check.sh` proves three agents run
  concurrent desktops with their own Chromium profiles, driven by xdotool, captured by scrot,
  with a cookie surviving a browser restart and nothing listening off loopback. Dockerfile and
  docker-compose harness build from `debian:trixie` via the real install script. README and
  `docs/architecture.md` written.
- Key decisions: **Openbox** as the window manager (measured: ~18 MB resident, no session bus,
  gives Chromium the focus handling it needs). **Plain sudoers rules, no privileged helper** —
  two lines cover everything the daemon needs. Both open questions in `OVERVIEW.md` are now
  closed. The harness needs `init: true` (reap setsid'd processes) and
  `security_opt: seccomp=unconfined` (Chromium's own sandbox needs `unshare(CLONE_NEWNET)`;
  preferred over shipping `--no-sandbox`, which would also weaken real VM deployments).
- Notes / leftovers: the container entrypoint is still `sleep infinity` — slice 2 replaces it
  with the daemon. Chromium's cookie commit is timer-based and can take ~25s, so `check.sh`
  waits for the write to reach the profile before restarting the browser. Packer template
  still deferred (needs a Linux host with QEMU).
- Runtime-unverified: nothing on this Mac. Never run on a real Debian 13 VM or a VPS —
  `install.sh` idempotency was verified inside the container only.

## Slice 2: daemon spine
- Shipped: pnpm workspace (`daemon`, `shared`) on Node 24 and TypeScript strict. A Hono server
  on `SCHERMES_PORT` (default 7777) bound to `0.0.0.0`, the only socket off loopback.
  better-sqlite3 + Drizzle at `/var/lib/schermes/schermes.db`, migrations committed and applied
  on boot. Owner auth: health reports `setupRequired`, a one-shot setup endpoint claims the
  owner row, login issues an HttpOnly session cookie, sessions live in SQLite. Provider settings
  (base URL, model, API key) with the key AES-256-GCM encrypted under
  `/var/lib/schermes/master.key` (0600, generated on first boot with an exclusive open) and
  never returned by the API. Structured JSON logging with one recursive redaction step.
  `infra/schermes.service`, `infra/smoke.sh`, and the container now runs the daemon instead of
  `sleep infinity`. 16 unit tests (`node:test`, no framework) cover secrets, redaction, the auth
  guard, setup-cannot-reset, and the settings round-trip.
- Key decisions: **no build step** — Node 24's type stripping means the daemon runs from source,
  so there is no `dist/` and no cwd-relative migrations path. **Sessions in SQLite**, not memory,
  so a restart does not log the owner out. **No Docker volume for `/var/lib/schermes`** — it is
  the service user's home and a fresh volume would mask the directories `install.sh` creates
  with the right ownership, which the unprivileged daemon could not repair. **`setpriv`, not
  `su`**, as the container's privilege drop, so signals reach the daemon (`docker compose stop`
  measured at 0.34s, i.e. a real SIGTERM, not a 10s SIGKILL timeout). The Dockerfile installs
  dependencies in its own layer before copying sources; `install.sh` only installs them when the
  repository is already present, so the two paths never do it twice. `check.sh`'s loopback
  assertion now compares full `address:port` and allows exactly the web port — verified
  non-vacuous by binding a rogue `0.0.0.0:9999` and watching it fail.
- Notes / leftovers: fixed a slice-1 bug — `pnpm` was installed into `/opt/node/bin` but never
  symlinked onto `PATH`; the symlinks also now sit outside the "is node 24 present" branch so a
  node upgrade cannot leave them stale. pnpm's key for allowing install scripts is `allowBuilds`
  in `pnpm-workspace.yaml` on pnpm 11, not `onlyBuiltDependencies`. Redaction is by key name, so
  routes deliberately never log request bodies. No UI yet, so the owner password and settings
  are only reachable over the API.
- Runtime-unverified: the `pnpm install --frozen-lockfile --prod` line in `install.sh` has only
  ever run against an already-complete `node_modules` (the Dockerfile installs first). On a real
  VM it does the actual install. The systemd unit has never been started by systemd — the
  harness runs the daemon as the container command.
- Housekeeping: the Docker VM was at 94% disk and the image build failed until `docker builder
  prune -f` freed 2.4GB. It now sits at ~93% with ~3GB free, so slice 3 will likely hit the same
  wall. Build cache has already been pruned once; images and volumes were left untouched because
  they belong to other projects.

## Slice 3: agent lifecycle
- Shipped: an `agents` table (name, unique display, created timestamp) with a committed
  migration. `daemon/src/agents.ts` allocates displays lowest-free-first from `:1`, shells out
  to `create-agent-user.sh` and `start-desktop.sh`, and reconciles every agent on boot. REST
  behind the session guard: create, list and fetch an agent; no delete. `start-desktop.sh` now
  clears a stale `/tmp/.X<n>-lock` in the branch where the probe has already proved the display
  is unused. `check.sh` moved its agents to `:101`-`:103`. `smoke.sh` grew an agent section:
  invalid names refused, two agents created with their own users, homes, window managers and
  loopback-only VNC ports, both surviving a container restart, both adopted by a second daemon
  with unchanged Xvnc pids, and one killed desktop respawned while the other stays adopted.
  25 unit tests, up from 16.
- Key decisions: **the adopt-vs-respawn decision stays in `start-desktop.sh`.** It already
  probed with `xdpyinfo` and printed `adopted` or `started`; the daemon reads that word. A
  TypeScript probe would have duplicated the `getent` home lookup and the `XAUTHORITY`
  assembly for no gain. **Boot reconcile is the same call as create**, so there is one path.
  **A failed create drops the row**: the Linux user and home survive for a retry and the
  display goes back in the pool instead of being stranded. **No delete endpoint** — removing a
  Linux user and its home is destructive and can wait for a UI that confirms it.
- Notes / leftovers: the slice brief asked for adoption to be proven across
  `docker compose restart` with identical pids. That is impossible: the restart destroys the
  container's pid namespace. Proven instead by running a second daemon against the same
  database while the first one's desktops are up, which is what `systemctl restart schermes`
  creates. Reconcile runs after the server starts listening, so health answers before the
  desktops are back and anything checking them must poll. The second daemon in `smoke.sh`
  records its own pid before `exec` because `ss -p` cannot see pids in this container.
- Runtime-unverified: adoption has never run under real systemd — only the second-daemon
  simulation in Docker. `create-agent-user.sh` has never been called by the daemon on a real
  VM, only in the container.

## Slice 4: the tool layer
- Shipped: `daemon/src/exec.ts`, the single spawn boundary — every module above it takes it as
  a parameter, it caps collected output, feeds stdin, and drops the pipes two seconds after a
  process exits so a detached grandchild cannot hang a request. `daemon/src/computer.ts`:
  `screenshot`, `move`, `click`, `drag`, `scroll`, `type`, `key` and clipboard read/write over
  xdotool, scrot and xclip, validated in the daemon before anything reaches a shell.
  `daemon/src/terminal.ts`: run a command as the agent, with stdout, stderr, exit code, a
  timeout that kills the whole process group, and a background option. `POST
  /api/agents/:name/computer` and `/command` behind the session guard. `agentTarget()` and
  `asAgent()` in `agents.ts` assemble the sudo prefix. `SCHERMES_GEOMETRY` in `config.ts` is now
  the single source of both the Xvnc size and the coordinate bound. 41 unit tests, up from 25.
  `smoke.sh` grew a tool section: 404s and 400s, a screenshot of the bare desktop, an xterm
  launched in the background, a second screenshot that differs, typed keystrokes that create a
  file inside that xterm, a clipboard round-trip, a non-zero exit reported as data, a command
  killed at its timeout with no leftover process, and `apt-get install hello`.
- Key decisions: **a screenshot crosses the API as base64 PNG in the JSON body.** The model
  provider wants that encoding for a vision message, so returning bytes would mean encoding them
  again one layer up, and every action shares one response shape. **The seam is `Exec`, not a
  capability object.** Against the `DesktopOps` precedent, deliberately: the brief asks the tests
  to assert the argument list each action produces, and a `ComputerOps` fake would hide it. The
  agent-loop slice may want a capability-level fake; add the seam then rather than reopen this.
  **The timeout is GNU `timeout` inside the sudo**, which signals the whole process group, so a
  command that spawned children leaves nothing behind; killing `sudo` from Node would not reach
  them. The Node-side timer is only a backstop against a wedged `sudo`. **Free text travels on
  stdin** (`xdotool type --file -`, `xclip -i`), so it never needs shell quoting and never shows
  up in the process list.
- Notes / leftovers: known ceilings, none worth changing yet — a command that exits 124 on its
  own reads as a timeout; stderr truncates silently at 64 KiB while stdout gets a visible
  `[output truncated]` marker; the screenshot is captured to one fixed path per agent, so two
  concurrent screenshots for the same agent would race; the backstop `SIGKILL` lands on `sudo`
  and would orphan the command underneath it if it ever fired. Persistent terminals and a
  browser tool stay deferred: launching Chromium is a use of the terminal tool.
- Runtime-unverified: the backstop timer has never fired. A non-default `SCHERMES_GEOMETRY` has
  never been exercised, so the coordinate bound is untested against anything but 1280x800, and a
  desktop adopted under an older geometry can still disagree with it. The 32 MiB screenshot cap
  has never been approached.
- Housekeeping: the Docker VM sits at 91% with 4.2 GB free. Only the final `COPY` layer rebuilds
  after a source edit, so `docker compose up -d --build` is cheap; `docker builder prune -f` has
  little left to reclaim. Images and volumes belong to other projects — leave them alone.
