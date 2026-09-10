# Next slice — schermes-mvp

Read `docs/slides/schermes-mvp/OVERVIEW.md` (north star) and
`docs/slides/schermes-mvp/PROGRESS.md` (what's already shipped) first.

## This slice
Give the daemon hands. An agent's desktop and shell become things the daemon can act on:
screenshot, mouse, keyboard, clipboard, and running a command as the agent user. These are the
two tool interfaces the OVERVIEW names as boundaries, and everything after this slice — the
agent loop, the browser, human takeover — calls through them.

Slice 3 gave every agent a Linux user and a live X display. Nothing has touched either yet.

No model calls, no agent loop, no UI.

## Scope boundaries
- Do:
  - A computer-use module in the daemon: `screenshot`, `move`, `click`, `drag`, `scroll`,
    `type`, `key`, and clipboard read/write, driven by `xdotool`, `scrot` and `xclip`, which
    `install.sh` already provisions. One implementation behind a small interface, because the
    OVERVIEW names this as a provider-agnostic boundary.
  - A terminal module: run a command as the agent user, return stdout, stderr and the exit
    code, enforce a timeout that actually kills the process, and support a background option
    that returns without waiting. `sudo` strips the environment, so every invocation carries
    `HOME`, `USER`, `LOGNAME`, `DISPLAY` and `XAUTHORITY` explicitly — the same rule
    `start-desktop.sh` follows.
  - Decide once how a screenshot crosses the API (base64 in JSON, or an image response) and
    record the choice in `docs/architecture.md`. Whichever it is, the bytes must not go through
    the logger.
  - REST behind the session guard, per agent: one endpoint for a computer action and one for a
    command. A request for an unknown agent is a 404; a request whose action or command is
    malformed is a 400, decided in the daemon before anything reaches a shell.
  - Unit tests with the spawn boundary faked: action validation (including rejecting an
    unknown action and out-of-range coordinates), the argument list each action produces, the
    timeout path, and a non-zero exit code being reported rather than thrown.
  - Extend `infra/smoke.sh`: through the API, screenshot one of the smoke agents, perform an
    action that visibly changes its desktop, screenshot again, and assert the two images
    differ. Run a command and check its output and exit code; run one that exceeds its timeout
    and check it is killed; run one in the background and check the call returns immediately.
    `apt-get install` of a small package belongs here too — the sudoers rule already allows it
    and the OVERVIEW's Definition of Done names it.
- Don't:
  - Any model provider or agent loop. Messaging, task workers, the VNC WebSocket proxy, noVNC,
    or any UI. Input ownership and human takeover — that is its own slice and this one must not
    guess at its shape.
  - A browser tool or Chromium CDP. Launching Chromium is a use of the terminal tool, not a new
    capability, and CDP is deferred in the OVERVIEW.
  - tmux-backed persistent terminals. The OVERVIEW defers them; one command at a time is the
    contract.
  - Widening the sudoers rules. Everything this slice needs is already allowed: the daemon may
    become any `agents` member, and agent users have passwordless sudo.
  - Spawning desktops from anywhere new. If something in this slice needs its own display, it
    needs its own range — the daemon owns `:1` upwards and `check.sh` owns `:101`-`:103`.

## Done when
Through the API, a caller with a session can take a screenshot of a running agent's desktop,
drive its mouse and keyboard so that a second screenshot differs from the first, read and write
its clipboard, run a shell command and get its output and exit code, have a command killed at
its timeout, and install a package with `apt-get`. Unit tests pass, `pnpm check` is clean,
`./infra/smoke.sh` exits 0, and
`docker compose exec schermes /opt/schermes/infra/desktop/check.sh` still exits 0.

Note: the Docker VM sits near 90% disk. `docker builder prune -f` is the safe lever; leave
images and volumes alone, they belong to other projects.

When finished, run `/handoff`.
