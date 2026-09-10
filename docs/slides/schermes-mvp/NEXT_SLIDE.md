# Next slice — schermes-mvp

Read `docs/slides/schermes-mvp/OVERVIEW.md` (north star) and
`docs/slides/schermes-mvp/PROGRESS.md` (what's already shipped) first.

## This slice
Put agents under the daemon's control. Creating an agent through the API creates its Linux
user, home layout and Xvnc desktop; the daemon knows which display belongs to which agent,
survives a restart by adopting the desktops that are still alive, and respawns the ones that
are not. This connects slice 1's shell scripts to slice 2's service.

No model calls, no computer-use tools, no VNC in a browser yet — this slice is about the
lifecycle and the ownership of a desktop, not about doing anything on it.

## Scope boundaries
- Do:
  - An `agents` table: name, display number, created timestamp, and whatever the desktop
    supervisor needs to adopt a running display. Display numbers are allocated by the daemon
    and unique per agent; `:0` stays reserved.
  - A desktop module in the daemon that shells out to the existing
    `infra/desktop/create-agent-user.sh` (via the `sudo` rule that already allows it) and
    `infra/desktop/start-desktop.sh`, and probes a display with `xdpyinfo` to decide whether it
    is alive. Reuse those scripts — do not reimplement their logic in TypeScript.
  - Validate the agent name against `^[a-z0-9][a-z0-9-]{0,30}$` in the daemon before it reaches
    a shell, even though the script validates too. Two boundaries, both cheap.
  - REST behind the session guard: create an agent, list agents, fetch one. No delete — removing
    a Linux user and its home is destructive and can wait until there is a UI to confirm it.
  - On boot, reconcile: for every agent in the database, adopt its display if `xdpyinfo` answers
    and respawn it if not. This is the same code path the daemon uses when creating an agent.
  - Unit tests for name validation, display allocation (including reuse after a gap) and the
    adopt-vs-respawn decision, with the spawn/probe boundary faked so they stay fast.
  - Extend `infra/smoke.sh`, or add a sibling script, to create two agents through the API and
    assert two live displays with distinct VNC ports — then assert the same after
    `docker compose restart`, with the same process IDs, proving adoption rather than respawn.
- Don't:
  - Computer-use tools (screenshot, click, type), the terminal tool, or Chromium launching from
    the daemon. Any model provider or agent loop. Messaging, task workers, the VNC WebSocket
    proxy, noVNC, or any UI.
  - Per-agent systemd units, or a desktop-per-container. The OVERVIEW's non-goals still hold.
  - Widening `check.sh`'s loopback assertion. VNC stays on 127.0.0.1.

## Done when
Two `POST`s to the agents endpoint produce two Linux users with their own homes and their own
Xvnc displays, both listed by the API and both visible in `ss` on loopback-only VNC ports.
`docker compose restart` brings the daemon back with both desktops adopted, not restarted, and
killing one desktop before a restart gets it respawned. Unit tests pass, `pnpm check` is clean,
`./infra/smoke.sh` exits 0, and
`docker compose exec schermes /opt/schermes/infra/desktop/check.sh` still exits 0.

Note: the Docker VM was at ~93% disk at the end of slice 2. If the image build fails on space,
`docker builder prune -f` is the safe lever; leave images and volumes alone, they belong to
other projects.

When finished, run `/handoff`.
