# Progress — schermes-mvp

## Current state
The desktop foundation is proven and committed. No Node code exists yet.

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
- `docker compose exec schermes /opt/schermes/infra/desktop/check.sh` must keep exiting 0.

**Key files**
```
infra/install.sh                     provisioning: packages, node 24, uv, users, sudoers
infra/desktop/create-agent-user.sh   root; creates agent-<name> + home layout
infra/desktop/start-desktop.sh       schermes; spawns or adopts Xvnc + Openbox
infra/desktop/check.sh               the runnable check for all of the above
infra/desktop/testpage/index.html    local page used by the cookie-persistence check
Dockerfile, docker-compose.yml       dev harness (init: true, seccomp=unconfined, shm 1gb)
docs/architecture.md                 decisions, tagged requirement / recommendation / deferred
```

**Gotchas already paid for** — see `docs/architecture.md` for the full reasoning: Chromium's
`SIGTERM` path does not flush pending cookie writes; signal only the browser process (the one
without `--type=`); Docker's DNS resolver listens on `127.0.0.11`, which is loopback.

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
