# Next slice — schermes-mvp

Read `docs/slides/schermes-mvp/OVERVIEW.md` first — it's the north star and guardrail.
(`docs/slides/schermes-mvp/PROGRESS.md` does not exist yet; this is the first slice.)

## This slice
Prove the desktop foundation, the riskiest piece: a Debian container built by the real
`install.sh` in which three separate Linux users each run their own Xvnc desktop with a
window manager, each drive a Chromium with a persistent profile, and each are controllable
via xdotool and screenshottable via scrot, all at the same time. Pure shell and Docker.
No Node code yet.

## Scope boundaries
- Do:
  - `infra/install.sh`: idempotent, apt-based, installs the baseline (X11/Xvnc/WM, Chromium,
    xdotool, scrot, xclip, fonts, terminal, git, ssh, curl, build-essential, python3 + pip +
    uv, node 24 + pnpm, zip/unzip/tar, jq, ripgrep, htop, less, vim, poppler-utils,
    imagemagick, sudo). Creates service user `schermes`, group `agents`, `/srv/schermes/shared`,
    sudoers rules for the daemon user. Keep the package list practical, not enormous.
  - `Dockerfile` + `docker-compose.yml` that build from `debian:trixie`, run `install.sh`,
    and start a placeholder entrypoint (keeps the container alive).
  - `infra/desktop/create-agent-user.sh <name>`: create `agent-<name>` user, home, workspace,
    uploads, chromium profile dir, group membership.
  - `infra/desktop/start-desktop.sh <name> <display>`: spawn Xvnc on `:<display>` bound to
    127.0.0.1 with a WM, detached, as the agent user; write a pidfile; idempotent (adopts if alive).
  - `infra/desktop/check.sh`: the runnable check. Creates three agents, starts three desktops,
    launches Chromium per user with `--user-data-dir` in the home, uses xdotool to type into
    Chromium and scrot to capture, asserts three distinct non-blank screenshots exist, sets a
    cookie via a local page (or `--app` data URL) and verifies it survives a Chromium restart,
    asserts VNC ports only listen on 127.0.0.1. Exit non-zero on any failure.
  - Decide the WM (Openbox first; fall back to xfce4 minimal only if Openbox is unusable) and record it.
  - Decide privilege model (plain sudoers rules for `schermes` vs helper) and record it.
  - `README.md` stub and `docs/architecture.md` with the decisions from OVERVIEW.md, tagged
    Requirement / Recommendation / Deferred.
  - `.gitignore`, first commit.
- Don't:
  - Any daemon, API, UI, noVNC, model calls or persistence. Those are later slices.
  - Packer template (later slice, needs Linux host).
  - Per-agent systemd units, containers per agent, Wayland.

## Done when
`docker compose build && docker compose up -d && docker compose exec schermes
/opt/schermes/infra/desktop/check.sh` exits 0 on this Mac, printing the three screenshot
paths and the cookie-persistence result. `docs/architecture.md` exists and records the WM and
privilege decisions. Running `check.sh` twice in a row also passes (idempotency).

When finished, run `/handoff` to record progress and write the next slice.
