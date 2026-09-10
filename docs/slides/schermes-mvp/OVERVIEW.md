# schermes — self-hosted AI agent computer (MVP)

## Goal
A single self-contained Linux machine (VM on Unraid first, plain VPS second) that
hosts persistent AI agents with their own desktop, browser and terminal, controllable
and observable from one web UI. Deploy it, point it at an OpenAI-compatible model,
open the UI, and agents work. Open source, MIT, one repository.

## Scope
- Debian 13 base + idempotent `install.sh` that produces the finished machine.
  Packer template producing a qcow2 for Unraid. VPS path = install Debian, run script.
- Docker dev harness (Debian container built by the same script) for local iteration on macOS.
- One Linux user + one X display (Xvnc + lightweight WM) + Chromium profile per permanent agent.
- Daemon (Node 24, TypeScript) under systemd: agent loops, task workers, desktop
  supervision, VNC WebSocket proxy, HTTP API, WebSocket events, SQLite persistence.
- Computer-use tool interface: screenshot, move, click, drag, scroll, type, key, clipboard
  (xdotool + scrot), provider-agnostic.
- Terminal tool: run command as agent user, streamed output, timeout, background option, sudo.
- Model provider interface with one OpenAI-compatible (chat completions + tools + vision) impl.
- Agent state machine: idle, thinking, using computer, using browser, using terminal,
  waiting for agent, waiting for task worker, waiting for user, paused, failed, completed.
- Messaging: user<->agent, agent<->agent, group chats, delegation, worker results. Stored in
  SQLite, not coupled to the UI.
- Task workers: disposable loops spawned by a permanent agent, run as parent's Linux user
  in a worker subdirectory, return result to parent, visible in UI.
- Human takeover: noVNC in UI, backend-owned `input_owner` per desktop, agent input
  rejected while human holds control, agent resumes on return.
- Owner auth (single password, session cookie), settings UI for base URL / API key / model.
- Secrets AES-GCM encrypted in SQLite, master key file 0600 owned by service user.
- Structured execution events (tool calls, commands, results, transitions, failures,
  messages), no chain-of-thought, no secrets in logs.
- File model: `~agent/workspace` (agent-owned), `~agent/uploads` (from user),
  `/srv/schermes/shared` (group-writable, cross-agent), worker dirs under parent workspace.
- Restart recovery: interrupted tool calls marked, agent gets "system restarted" observation,
  desktops adopted or respawned, running workers marked failed and parent notified.
- Resource caps: max concurrently active agent loops, max task workers; excess requests fail
  with a clear message.
- React + Vite UI: sidebar (agents, conversations, create), chat view, agent view with live
  desktop + Take control + pause/resume + activity + workers, desktop view, settings.
- Docs: README, architecture, dev guide, deployment, image build, config reference, agent
  lifecycle, desktop/session architecture, persistence model, security model, troubleshooting.
- Tests: unit for state machine, worker lifecycle, messaging, persistence, provider
  abstraction, ownership; integration (in Docker harness) for desktops, computer use,
  takeover, command execution, restart recovery.

## Non-goals
Multi-user, orgs, billing, RBAC, Kubernetes, microservices, VM or container per agent,
snapshots/rollback, plugin marketplace, credential vault beyond encrypted settings, multiple
simultaneous providers, autoscaling, mobile apps, network policy enforcement, TLS inside the
product (document Caddy in front), Wayland, tmux-backed persistent terminals (deferred),
Chromium CDP automation (deferred, optional add-on), desktop idle shutdown (deferred).

## Key decisions & constraints
- **Requirement vs recommendation vs deferred** tagging continues in `docs/architecture.md`.
- Debian 13 over Ubuntu: no snap Chromium/Firefox, predictable paths for profiles and automation.
- X11 over Wayland: xdotool, scrot and VNC are mature on X11.
- Xvnc (TigerVNC) = X server + VNC server in one process per agent. VNC binds 127.0.0.1 only.
- Desktops are spawned detached (setsid) as the agent user by the daemon and adopted on
  daemon restart by probing the display. No per-agent systemd units. Works in Docker and VM.
- Daemon runs as service user `schermes` with sudoers rules: create users, run commands as
  `agent-*`, apt. Agent users get passwordless sudo (personal system, spec allows it).
- Agent loops are in-process async tasks; durable state is the DB, not the process.
- Build the agent loop ourselves; OpenHands, Anthropic reference, LangGraph, Vercel AI SDK
  evaluated and rejected (provider lock-in, own sandbox/persistence models, no gain).
- Stack: Node 24, TypeScript strict, Hono (HTTP + WS), better-sqlite3 + Drizzle (migrations
  in repo), React + Vite, pnpm workspace (`daemon`, `ui`, `shared`). No Next.js, no SSR.
- Exactly one exposed port (web app). Everything else localhost.
- Ponytail rules apply: smallest working design, no speculative abstractions, one runnable
  check per non-trivial piece. The only interfaces that get an abstraction are the ones the
  spec names as boundaries (model provider, computer use, terminal, desktop, persistence,
  messaging, secrets).
- Project name is `schermes`. Use the term `task worker` everywhere.
- Every slice keeps `docker compose up` working end to end.
- Anything that must survive a daemon restart cannot be verified with `docker compose restart`:
  that destroys the container's pid namespace, so detached processes die with it. Verify by
  starting a second daemon against the same database, the way `systemctl restart schermes` does.

## Preconditions & external dependencies
- Docker on the dev Mac (present, 29.x). Docker container will run Xvnc/Chromium; no GPU needed.
- An OpenAI-compatible endpoint with tool calling and vision for slices that hit a real
  model (base URL, key, model name). Unit tests use a fake provider; one integration run
  against a real endpoint is `[user-gated]`.
- Final verification on the Unraid VM: user must create a Debian 13 VM (or import the
  Packer qcow2) and provide access. `[user-gated]`

## Building blocks
- `infra/install.sh` (idempotent Debian provisioning), `infra/packer/`, `Dockerfile`,
  `docker-compose.yml`
- Desktop manager: create agent user, spawn/adopt Xvnc + WM, display allocation, Chromium launch
- Computer-use provider (xdotool/scrot/xclip) behind tool interface
- Terminal tool (spawn as user, stream, timeout, background)
- Model provider (OpenAI-compatible) + fake provider for tests
- Agent runtime: loop, state machine, tool dispatch, context assembly, restart recovery
- Task worker orchestration
- Messaging: conversations, participants, messages, delivery to agents, group fan-out
- Persistence: SQLite schema, migrations, event log
- Secrets: encrypted settings
- Web layer: auth, REST, WebSocket events, VNC proxy with ownership gate
- UI: sidebar, chat, agent, desktop (noVNC), settings
- Docs and tests

## Definition of Done
- [ ] `docker compose up` builds a Debian image via `infra/install.sh` and starts the daemon
- [ ] `install.sh` runs idempotently on a fresh Debian 13 (verified in Docker; VM run `[user-gated]`)
- [ ] Packer template in repo builds a qcow2 (`[user-gated]`, needs Packer + QEMU on a Linux host)
- [ ] Owner sets password on first visit and must log in afterwards
- [ ] Settings UI stores base URL, encrypted API key and model; key never appears in logs or API responses
- [ ] Creating an agent creates a Linux user, home, workspace, Xvnc display and WM; two agents run concurrently
- [ ] Agent can take a screenshot and perform mouse/keyboard actions that visibly change its desktop (integration test)
- [ ] Agent can open Chromium, and cookies persist across a Chromium restart (integration test)
- [ ] Agent can run shell commands, create/edit files, and `apt-get install` a package (integration test)
- [ ] Agent view shows live desktop; Take control blocks agent input (agent enters waiting-for-user); Return control resumes it (test on ownership state + integration test)
- [ ] Conversations, messages, events and agent config survive daemon restart and reboot of the container
- [ ] Daemon restart mid tool-call marks it interrupted and the agent resumes from persisted history (test)
- [ ] Permanent agent spawns a task worker; worker activity and result appear in the UI and the parent receives the result (test)
- [ ] Group conversation with two agents: both receive and reply to a user message (test)
- [ ] Closing the browser does not stop agent work; reconnecting shows current state and history
- [ ] Agent-to-agent direct message visible in the UI
- [ ] Resource caps enforced: worker request above cap fails with a clear error (test)
- [ ] Only the web port is bound to non-loopback interfaces (checked by a script in the harness)
- [ ] Unit tests cover state machine, worker lifecycle, messaging, persistence, provider abstraction, ownership
- [ ] Docs listed under Scope exist and match the code
- [ ] One end-to-end run against a real OpenAI-compatible endpoint `[user-gated]`
- [ ] Deployed and verified on the Unraid VM `[user-gated]`

## Open questions
Both questions this task opened are closed. Slice 1 chose **Openbox** over XFCE minimal by
measurement, and **plain sudoers rules** over a privileged helper: two lines cover everything
the daemon needs.
