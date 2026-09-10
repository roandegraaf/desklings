# Progress — schermes-mvp

## Current state
The desktop foundation and the daemon spine are committed. Agents are not wired to the daemon
yet: `create-agent-user.sh` and `start-desktop.sh` exist and work, but only `check.sh` calls them.

**Invariants future slices must respect**
- `infra/install.sh` is the single provisioning path. The Docker harness and a real VM run the
  same script. It must stay idempotent — re-running it is the upgrade path.
- The daemon runs as the unprivileged system user `schermes`. Its only root powers are
  `create-agent-user.sh` and `apt-get`; it becomes agent users via `sudo -u agent-<name>`,
  authorised by the `%agents` runas rule. Do not widen this without recording why.
- Agent users are `agent-<name>` where name matches `^[a-z0-9][a-z0-9-]{0,30}$`. Validate at
  every boundary that accepts a name.
- One `Xvnc` per agent, VNC on `5900 + display`, loopback only, `-nolisten tcp`. Desktops are
  spawned detached with `setsid` and adopted on restart by probing with `xdpyinfo`. No
  per-agent systemd units.
- Every command run as an agent must carry `HOME`, `USER`, `LOGNAME`, `DISPLAY` and
  `XAUTHORITY` explicitly. `sudo` strips them.
- **No build step.** Node 24 strips TypeScript types on load; systemd and the container both run
  `daemon/src/main.ts` from source and `tsc` only type-checks. Never introduce `dist/`. Anything
  the daemon reads from disk resolves from `import.meta.dirname`, never the working directory —
  systemd starts services from `/`.
- The auth guard is registered before any route and denies by default. Adding a public route
  means deliberately adding it to the allowlist in `daemon/src/app.ts`.
- Only the web port may bind off loopback. `check.sh` compares the full `address:port`, so a new
  listener needs a real reason, not a widened assertion.
- The pinned pnpm version lives in three places that move together: `packageManager` in
  `package.json`, `PNPM_VERSION` in `install.sh`, and `pnpm-lock.yaml`.
- `docker compose exec schermes /opt/schermes/infra/desktop/check.sh` and `./infra/smoke.sh`
  must both keep exiting 0.

**Key files**
```
daemon/src/{main,app,auth,secrets,settings,db,schema,config,log}.ts   the service
daemon/migrations/                   Drizzle migrations, committed, applied on boot
shared/src/index.ts                  API contract types
infra/install.sh                     provisioning: packages, node 24, uv, users, sudoers, unit
infra/schermes.service               systemd unit (no NoNewPrivileges: the daemon needs sudo)
infra/smoke.sh                       runnable check for the daemon API
infra/desktop/*.sh                   per-agent user creation, desktop spawn/adopt, check.sh
docs/architecture.md                 decisions, tagged requirement / recommendation / deferred
```

**Gotchas already paid for** — see `docs/architecture.md`: Chromium's `SIGTERM` path does not
flush pending cookie writes, and only the browser process (the one without `--type=`) should be
signalled; Docker's DNS resolver listens on `127.0.0.11`, which is loopback; scrypt above
N=16384 exceeds Node's default 32 MiB `maxmem` and throws; a `Secure` session cookie would be
dropped over the plain HTTP schermes speaks by design.

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
