# Progress — schermes-mvp

## Current state
The desktop foundation, the daemon spine and the agent lifecycle are committed. Creating an
agent through the API creates its Linux user, home layout and Xvnc desktop; the daemon adopts
live desktops on restart and respawns dead ones. Nothing calls a model yet and there is no UI.

**Invariants future slices must respect**
- `infra/install.sh` is the single provisioning path. The Docker harness and a real VM run the
  same script. It must stay idempotent — re-running it is the upgrade path.
- The daemon runs as the unprivileged system user `schermes`. Its only root powers are
  `create-agent-user.sh` and `apt-get`; it becomes agent users via `sudo -u agent-<name>`,
  authorised by the `%agents` runas rule. Do not widen this without recording why.
- Agent users are `agent-<name>` where name matches `^[a-z0-9][a-z0-9-]{0,30}$`. Validate at
  every boundary that accepts a name.
- One `Xvnc` per agent, VNC on `5900 + display`, loopback only, `-nolisten tcp`, spawned
  detached with `setsid`. Desktops outlive the daemon. The adopt-or-spawn decision lives in
  `start-desktop.sh`, which prints `adopted` or `started`; the daemon reads that word rather
  than probing itself. No per-agent systemd units.
- **Display ranges are partitioned.** The daemon allocates from `:1` up, lowest free first;
  `check.sh` owns `:101`-`:103` because its agents are not in the database. A new script that
  spawns desktops needs its own range — two X servers on one display is a collision.
- **`docker compose restart` cannot demonstrate adoption**: it destroys the container's pid
  namespace, so every desktop dies and is respawned on boot. Only a new daemon process while
  the desktops still run reaches the adopt path, which is what `systemctl restart schermes`
  creates and what `smoke.sh`'s second daemon simulates.
- Every command run as an agent must carry `HOME`, `USER`, `LOGNAME`, `DISPLAY` and
  `XAUTHORITY` explicitly. `sudo` strips them.
- **No build step.** Node 24 strips types on load; systemd and the container run
  `daemon/src/main.ts` from source and `tsc` only type-checks. Never introduce `dist/`. Paths
  resolve from `import.meta.dirname`, never the working directory — systemd starts from `/`.
  `config.desktopScripts` resolves to `/opt/schermes/infra/desktop`, the literal path in the
  sudoers rule; the two must keep agreeing.
- The auth guard is registered before any route and denies by default. A public route means
  deliberately adding it to the allowlist in `daemon/src/app.ts`.
- Only the web port may bind off loopback. `check.sh` compares the full `address:port`, so a new
  listener needs a real reason, not a widened assertion.
- The pinned pnpm version moves together in three places: `packageManager` in `package.json`,
  `PNPM_VERSION` in `install.sh`, and `pnpm-lock.yaml`.
- `docker compose exec schermes /opt/schermes/infra/desktop/check.sh` and `./infra/smoke.sh`
  must both keep exiting 0.

**Key files**
```
daemon/src/{main,app,auth,agents,secrets,settings,db,schema,config,log}.ts   the service
daemon/migrations/                   Drizzle migrations, committed, applied on boot
shared/src/index.ts                  API contract types
infra/install.sh                     provisioning: packages, node 24, uv, users, sudoers, unit
infra/schermes.service               systemd unit (no NoNewPrivileges: the daemon needs sudo)
infra/smoke.sh                       runnable check for the daemon API and the agent lifecycle
infra/desktop/*.sh                   per-agent user creation, desktop spawn/adopt, check.sh
docs/architecture.md                 decisions, tagged requirement / recommendation / deferred
```

**Gotchas already paid for** — see `docs/architecture.md`: Chromium's `SIGTERM` path does not
flush pending cookie writes, and only the browser process (the one without `--type=`) should be
signalled; Docker's DNS resolver listens on `127.0.0.11`, which is loopback; scrypt above
N=16384 exceeds Node's default 32 MiB `maxmem` and throws; a `Secure` session cookie would be
dropped over the plain HTTP schermes speaks by design; a killed X server leaves
`/tmp/.X<n>-lock` behind and the X server only clears it when the pid inside is dead, so
`start-desktop.sh` removes it once the probe has proved the display is unused; `ss -p` shows no
pids in this container because Docker does not grant `CAP_SYS_PTRACE`, so nothing can find a
process by the port it listens on.

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
