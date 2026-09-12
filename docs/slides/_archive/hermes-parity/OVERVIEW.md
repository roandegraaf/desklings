> Completed 2026-09-11 (pending acceptance: 4 items, see ACCEPTANCE.md)

# Hermes parity: memory, cron, skills, web, MCP

## Goal
Give every permanent schermes agent the assistant-side feature set of Hermes Agent and
OpenClaw on top of what it already has (a real desktop, a Linux user, a terminal, peers and
task workers): it remembers across conversations, keeps long threads from growing without
bound, runs on a schedule without the owner, carries reusable skills, and reaches the web and
MCP tools directly. The daemon stays one process, one port, SQLite for durable state.

## Scope
- Persistent per-agent memory: curated notes the agent reads every turn and updates itself,
  plus a searchable record of what it learned, surviving daemon restarts and container rebuilds.
- Context compaction: a thread whose transcript passes a budget is summarised into the
  conversation and only the summary plus the recent tail is replayed to the model.
- Scheduled tasks: an agent (or the owner) creates, lists, pauses and cancels cron jobs; a due
  job starts a turn in the agent's owner thread with the job's prompt, so results land where
  the owner reads. Heartbeat is a cron job with a fixed prompt, not a second mechanism.
- Skills: `SKILL.md` folders (agentskills.io layout) per agent and shared across agents, listed
  by name and description in the prompt, read in full on demand, written and improved by the
  agent itself.
- Web search and page fetch as first-class tools, so an agent does not have to drive Chromium
  to read a page or find a URL.
- MCP client: the owner configures MCP servers (stdio and streamable HTTP); their tools are
  offered to the model alongside the built-in ones.
- UI for all of the above where the owner needs it: schedules, memory, skills, MCP and search
  settings. Small panels in the existing UI, not a new app.

## Non-goals
- Messaging gateways (Telegram, Discord, Slack, WhatsApp, Signal): a later task.
- TTS, image generation, voice input.
- Multi-owner, RBAC, billing, plugin marketplace (architecture.md's deferred list stands).
- A second model provider. OpenRouter through the OpenAI-compatible client stays the one
  seam; routing and reasoning are steered through the `extraBody` setting shipped before this
  task.
- RL, trajectory export, self-training: Hermes features that are not what schermes is for.

## Key decisions & constraints
- Memory lives in the agent's home as files (`~/memory/MEMORY.md` curated and always loaded,
  `~/memory/YYYY-MM-DD.md` daily notes appended) rather than in a new table. The agent already
  owns a filesystem and `ripgrep` is installed; a `remember` tool exists only because models do
  not save unless a tool makes it a one-step act. The loaded part is capped (chars) and the cap
  is a named constant in `docs/configuration.md`.
- Compaction writes a summary row, never rewrites history: message rows stay the durable
  record and the UI keeps showing them. The summary is produced by the same provider and the
  replay must keep every assistant/tool-call pair intact (`assertEveryCallAnswered` in
  `loop.test.ts` is the contract).
- Cron: a `schedules` table, a daemon tick (`setInterval`, ~30 s) that finds due rows, and
  delivery through the existing messaging path (`appendMessage` + `runner.start`) so a busy
  agent picks a job up through the drain like any other message. Missed runs while the daemon
  was down run once at boot, not once per missed slot. Cron expressions only; the model
  translates natural language before calling the tool. One small dependency for parsing
  (`croner`) is acceptable; a hand-written parser is not worth its edge cases.
- Skills are files: `~/skills/<name>/SKILL.md` per agent, `/srv/schermes/shared/skills` for
  all. The prompt carries the index (name + description from frontmatter) only; the body is
  read with `run_command`. No skill registry table.
- Web: `web_search` and `web_fetch` tools in the daemon. **Decided in slice 4: Brave**, not
  Tavily — the key travels as a request header rather than in a JSON body a proxy would log, and
  `web.results[]` is already `{title, url, description}`. The endpoint is a setting for a proxy
  or a mirror; the parser is Brave's shape. Key in settings, encrypted like the provider key.
  Fetch returns readable text, not raw HTML, clipped to `MAX_OBSERVATION_CHARS`, and a URL the
  model chose never reaches loopback, link-local or private ranges.
- MCP: `@modelcontextprotocol/sdk` client in the daemon, servers configured as a JSON setting
  (owner-wide), connected lazily per agent turn, tools exposed as `mcp__<server>__<tool>` and
  results treated as observations like any other tool. Stdio servers run as the agent's Linux
  user through the existing `asAgent` prefix, never as `schermes`.
- Every new tool follows the existing shape: a `parseX` that validates, a `xToolDef` built from
  the same constants, an observation on refusal rather than a failed run, a `tool_call` and
  `tool_result` event.
- Prompt caching matters: everything injected per turn (memory, skills index, schedules) goes
  after the stable system text, and the stable text does not change between steps of a turn.
- Follow the tagging in `docs/architecture.md` (Requirement / Recommendation / Deferred) when
  a slice adds a decision there.

## Preconditions & external dependencies
- A Brave Search subscription token before the web slice can be verified live. Everything else
  about it is built and covered against a stub.
- At least one MCP server to test against (a stdio one from the npm registry is enough).
- The OpenRouter key already stored in the running container.

## Building blocks
- Home-directory context loader: reads memory and the skills index as the agent user and
  appends them to the system prompt (`loop.ts` `systemPrompt`).
- `remember` tool and daily-notes append.
- Summary rows and the compaction pass in `transcript()`.
- `schedules` table, migration, tick, tools (`schedule_task`, `list_schedules`,
  `cancel_schedule`), owner API and UI panel.
- Skills folders, seeding of a shared skills directory, prompt index.
- `web_search` / `web_fetch` tools and their settings.
- MCP client, settings, tool namespace, per-agent connection lifecycle.
- Smoke coverage in `infra/smoke.sh` for the scheduler (a job that fires) and memory (a fact
  that survives a restart).

## Definition of Done
- [x] A fact told to an agent in one conversation is in its `~/memory/MEMORY.md` and is used
      in a new conversation after a daemon restart (test in `loop.test.ts` with a scripted
      provider; smoke check in `infra/smoke.sh`).
- [x] A thread longer than the compaction budget replays a summary plus the tail, every
      tool call in the replay is answered, and the UI still shows the full history.
- [x] `schedule_task` with a cron expression creates a row; the tick starts a turn at the due
      time; the result is a message in the owner thread; pause and cancel work from the tool
      and from the UI; a run missed during downtime runs once at boot. Slice 3 built everything
      but the UI; **slice 6 finished it** — the agent pane's schedules tab creates, pauses,
      resumes and cancels, driven in a browser against a running container.
- [x] A `SKILL.md` placed in `~/skills/<name>/` appears in the agent's prompt index on its
      next turn, and an agent can write a new one and see it listed.
- [ ] `web_search` returns titled results with URLs and `web_fetch` returns readable text for
      a live page. `[user-gated]` (needs the search key). **Built and covered by slice 4**
      against a stubbed endpoint, including the SSRF guard, the clip and the key never leaving
      the daemon, and **the owner's field for the key shipped in slice 6**, write-only like the
      provider key. **Outstanding: a Brave subscription token, then one live search and one live
      fetch.** Nothing is left to build.
- [ ] A configured MCP server's tools are offered to the model and a call round-trips.
      `[user-gated]` (needs a server). **Built and covered by slice 5** — the round trip is
      against the SDK's own `Server` over an in-memory transport, so it is the real protocol and
      not a stub — and **the owner's panel shipped in slice 6**, whose per-agent test was driven
      in a browser against a stdio server that failed to start, so the spawn and the error path
      are exercised. **Outstanding: one server that actually starts or answers, and one tool call
      through it.** Nothing is left to build.
- [x] `docs/configuration.md` lists every new constant and setting; `docs/architecture.md`
      records the decisions above with their tags.
- [x] `pnpm check` and `pnpm test` pass in `daemon/` and `ui/`; `infra/smoke.sh` passes.

## Open questions
Both of the questions this task opened were answered in the cron slice. Neither is open now.

- ~~Whether a scheduled job can be addressed to a group conversation.~~ **Decided: owner thread
  only.** A job that fired into a group would start a turn for every agent in it, and the owner
  thread is where the owner already reads. Revisit only if somebody needs otherwise.
- ~~Whether the daemon seeds a nightly job that summarises the daily notes into `MEMORY.md`.~~
  **Decided: no seeded job.** The mechanism now exists — `schedule_task` plus slice 2's
  `SUMMARY_PROMPT` — which is what the question was waiting on. Seeding one would need a
  creation-time path, a boot-reconcile path and a summariser that rewrites a file rather than a
  transcript: a second feature, and one nobody has asked for. An owner or an agent that wants it
  writes the schedule.
