# Architecture

Decisions are tagged **Requirement** (the product does not work without it), **Recommendation**
(a considered default that a deployment may override), or **Deferred** (deliberately out of
scope for now, with the trigger that would bring it back).

## Shape of the system

One Linux machine runs everything: a Node daemon under systemd, one Linux user per permanent
agent, one X display per agent, and a single web port. There is no per-agent container, no VM
per agent, and no orchestrator.

- **Requirement** — one machine, one exposed port. Everything else binds to loopback and is
  reached through the daemon.
- **Requirement** — durable state lives in SQLite, not in daemon memory. Agent loops are
  in-process async tasks that can be killed and rebuilt from the database.
- **Recommendation** — Debian 13 (trixie) as the base. Chromium and Firefox are real `.deb`
  packages rather than snaps, so profile paths and automation are predictable.
- **Deferred** — multi-user, RBAC, billing, Kubernetes, autoscaling, plugin marketplace. Revisit
  only if schermes stops being a single-owner personal machine.

## Display stack

- **Requirement** — X11, not Wayland. `xdotool`, `scrot` and VNC are mature and scriptable on
  X11. Wayland would need a different input-injection path per compositor.
- **Requirement** — one `Xvnc` process per agent. TigerVNC's `Xvnc` is an X server and a VNC
  server in one process, so a desktop is a single thing to spawn, adopt and kill.
- **Requirement** — VNC binds loopback only (`-localhost -rfbport $((5900 + display))`), plus
  `-nolisten tcp` so the X protocol itself is reachable only over the Unix socket. The daemon
  proxies VNC to the browser over its own WebSocket, which is where ownership is enforced.
- **Requirement** — desktops are spawned detached with `setsid` as the agent user and adopted
  on daemon restart by probing the display with `xdpyinfo`. No per-agent systemd units, so the
  same code path works in the Docker harness and on a VM.

### Window manager: Openbox

**Recommendation** — Openbox. Decided in slice 1 by measurement, not preference: it starts in
well under a second, needs no session bus, and gives Chromium the window management it expects
(focus, `_NET_ACTIVE_WINDOW`, resizing). Measured in the harness, a desktop costs about 18 MB
resident for Openbox and 28 MB for Xvnc, before the browser. XFCE was the fallback and was not
needed. Swapping it means changing one line in `infra/desktop/start-desktop.sh`.

A window manager is not optional. Without one, Chromium windows never receive focus and
`xdotool` keystrokes go nowhere.

## Privilege model

**Requirement** — plain sudoers rules, no setuid helper. This was the other open question from
the overview, and a helper binary turned out to buy nothing: everything the daemon needs is
expressible as two sudoers lines, and a helper would be one more thing to audit.

`/etc/sudoers.d/schermes`:

```
schermes ALL=(root) NOPASSWD: /opt/schermes/infra/desktop/create-agent-user.sh, /usr/bin/apt-get
schermes ALL=(%agents) NOPASSWD: ALL
```

- The daemon runs as the unprivileged system user `schermes`.
- It may become any member of the `agents` group. A `%group` entry in a runas list matches every
  member of that group, which is how one rule covers every present and future agent user.
- Its only root powers are creating an agent user and installing packages. `create-agent-user.sh`
  lives under `/opt/schermes`, is owned by root, and validates its argument against
  `^[a-z0-9][a-z0-9-]{0,30}$`, so the rule is not a path to arbitrary root.

`/etc/sudoers.d/agents` gives agent users passwordless sudo. That is intentional: an agent is
the operator of its own machine and needs to install packages and edit system files to be
useful. The isolation boundary of schermes is the machine, not the agent user. Deploy it
somewhere you would be comfortable giving a person root.

## File model

- `~agent-<name>/workspace` — the agent's own files.
- `~agent-<name>/uploads` — files the user hands to the agent.
- `~agent-<name>/.chromium-profile` — persistent browser profile: cookies, logins, extensions.
- `/srv/schermes/shared` — group-writable by `agents`, setgid, for cross-agent files.
- Task workers get a subdirectory under their parent's workspace and run as the parent's user.

## Runtime and toolchain

**Requirement** — Node 24 and TypeScript in strict mode for the daemon, React and Vite for the
UI, Hono for HTTP and WebSockets, better-sqlite3 with Drizzle for persistence, pnpm workspaces.
No Next.js and no SSR: the UI is a static bundle the daemon serves.

Node is installed from the official tarball into `/opt/node` rather than from Debian, which
ships an older major. `install.sh` resolves the current 24.x release at install time.

The host also carries the tools an agent is expected to reach for: Python with `uv`, git, ssh,
build-essential, jq, ripgrep, poppler-utils, ImageMagick, and an xterm.

## Docker dev harness

**Recommendation** — the harness is a convenience for developing on macOS, not a deployment
target. It builds `debian:trixie`, runs the real `infra/install.sh`, and is therefore the same
machine a VM would be.

Two container settings are load-bearing:

- `init: true` — `setsid` reparents detached Xvnc and Chromium processes to PID 1. Without an
  init that reaps them, dead browsers linger as zombies and process checks misfire.
- `security_opt: seccomp=unconfined` — Chromium's own sandbox needs `unshare(CLONE_NEWNET)`,
  which Docker's default seccomp profile denies. Relaxing the container is the better trade:
  the alternative is `--no-sandbox`, which would also weaken Chromium on real VM deployments
  where the sandbox works fine.

## Cookie persistence and Chromium shutdown

Worth knowing before writing browser automation against this stack. Chromium batches cookie
writes and commits them to the profile on a timer. Its `SIGTERM` handler takes the fast
session-end path and does **not** flush pending writes, so a cookie set seconds before a
restart is lost while an older one survives. `check.sh` therefore waits until the cookie has
actually reached the profile database before restarting the browser.

Sending `SIGTERM` to the browser process alone is still the right way to stop Chromium: it is
the only chromium process without a `--type=` argument, and signalling it exits the whole tree
in about two seconds. Signalling every chromium process at once is what corrupts the shutdown.

## Deferred

- Packer template and the qcow2 image build. Needs a Linux host with QEMU.
- Chromium CDP automation. The computer-use tools cover the MVP; CDP would be an add-on.
- tmux-backed persistent terminals. The terminal tool runs one command at a time for now.
- Desktop idle shutdown. Desktops stay up for the life of the daemon.
- TLS inside the product. Run Caddy or nginx in front.
