# Next slice — schermes-mvp

Read `docs/slides/schermes-mvp/OVERVIEW.md` (north star) and
`docs/slides/schermes-mvp/PROGRESS.md` (what's already shipped) first.

## This slice
Make an agent think. A message from the owner reaches a model, the model calls the tools that
slice 4 built, the observations go back, and the agent answers. The transcript and the execution
events are durable, so what an agent did is readable after the fact and after a restart.

Slice 4 gave the daemon hands. Nothing calls a model yet: `settings` stores a base URL, a model
name and an encrypted API key that no code has ever used.

No UI, no second agent, no task workers.

## Scope boundaries
- Do:
  - A model provider interface with one OpenAI-compatible implementation: chat completions,
    tool calling, and vision. A screenshot already leaves the tool layer as base64 PNG, which is
    the encoding a vision message wants — pass it through rather than re-encoding it.
  - Tool definitions for the computer and terminal tools, generated from the vocabulary that
    already exists in `daemon/src/computer.ts` and `terminal.ts`. One definition of each action,
    not a second copy in a schema file that can drift from the validator.
  - Tables and a committed migration for conversations, messages and execution events. Events
    are structured: tool call, tool result, state transition, failure. No chain-of-thought, no
    secrets — the OVERVIEW is explicit about both.
  - The loop itself, in-process and async, with the state machine states it can actually reach
    this slice: idle, thinking, using computer, using terminal, waiting for user, failed,
    completed. Durable state is the database, not the process. Persist a transition when it
    happens, not at the end.
  - REST behind the session guard: post a message to an agent, read its messages, read its
    events. A request for an unknown agent is a 404.
  - Unit tests with a fake provider: the state machine's legal transitions, a tool call being
    dispatched and its result being fed back, a provider error ending the run as failed rather
    than hanging, and the transcript the loop assembles for the second model call.
  - Extend `infra/smoke.sh`. Point the provider settings at a scripted OpenAI-compatible stub
    served on loopback inside the container — a small python script, the way `check.sh` already
    serves its test page — so the smoke run exercises the real client rather than a fake
    provider object. Script it to answer with a screenshot tool call, then a command tool call,
    then a final message, and assert the transcript and events that result. Remember `check.sh`
    asserts nothing binds off loopback: bind the stub to `127.0.0.1` explicitly.
- Don't:
  - Agent-to-agent messages, group conversations, delegation or task workers. Each is its own
    slice and this one must not guess at their shape.
  - Restart recovery. Marking an interrupted tool call and giving the agent a "system restarted"
    observation is the next slice, and it needs this slice's tables to exist first.
  - Human takeover, input ownership, the VNC proxy, noVNC, or any UI.
  - Resource caps. They belong with task workers, which is what makes them necessary.
  - Streaming responses, a second provider, or a provider registry. One implementation behind
    the interface, chosen by the settings that already exist.
  - A browser tool or Chromium CDP. Launching Chromium is a use of the terminal tool.
  - A second seam over the tool modules unless the tests need one. The `Exec` boundary is what
    makes them fakeable today; if the loop wants a capability-level fake, add it deliberately
    and say why in the handoff.

## Done when
With the provider settings pointed at the stub, posting a message to an agent makes it take a
screenshot of its own desktop, run a command, and answer — and the whole exchange, including
every tool call and its result, is readable through the API and still there after the daemon is
restarted. Unit tests pass, `pnpm check` is clean, `./infra/smoke.sh` exits 0 twice in a row, and
`docker compose exec schermes /opt/schermes/infra/desktop/check.sh` still exits 0.

Note: the Docker VM sits at 91%, 4.2 GB free. Only the final `COPY` layer rebuilds after a source
edit, so `docker compose up -d --build` is cheap. Leave images and volumes alone, they belong to
other projects.

When finished, run `/handoff`.
