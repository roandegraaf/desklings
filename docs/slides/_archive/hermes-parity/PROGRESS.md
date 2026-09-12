# Progress — hermes-parity

## Current state
**All six slices are done and the task is complete.** Every permanent agent has a memory and a
skills index in its home, both in its system prompt at the start of every turn; a thread that
outgrows a budget is replayed as a summary plus a verbatim tail; the daemon has a clock, so an
agent runs without its owner; `web_search` and `web_fetch` are ordinary tools behind an SSRF
guard; MCP servers the owner configures are connected per turn and their tools offered alongside
the built-ins; and the owner drives the search key, the MCP servers and every agent's schedules
from the UI.

Two halves of the Definition of Done are outstanding and **both are `[user-gated]`, not
unbuilt**: a live Brave Search key, and a real networked or spawned MCP server. Everything either
one would exercise is built and covered — the web half against a stubbed endpoint, the MCP half
against the SDK's own `Server` over an in-memory transport, which is the real protocol. Run
`/complete` to archive the task; those two are the acceptance list.

**Key files**: `daemon/src/home.ts` (memory loader, prompt tail, `remember`),
`daemon/src/schedules.ts` (the `schedules` table's queries, `croner`, the tick, the four tools,
the prompt index), `daemon/src/loop.ts` (`systemPrompt`, `homeTail`, `compact`, the tool list and
`dispatch`), `daemon/src/app.ts` (owner routes; it now returns `{ app, runner }`),
`daemon/src/main.ts` (boot, and where `startScheduler` is started),
`infra/desktop/create-agent-user.sh` (the home layout), `infra/provider-stub.py` (the `memory`
script and the `memory`/`skills`/`schedules` report fields), `infra/smoke.sh`.

**Invariants future slices must respect**
- Everything injected per turn — memory, the skills index, the schedules — goes **after** the
  stable system text and is loaded **once per turn, not once per step**, so the system message is
  byte-identical across the steps of one turn and the prompt cache holds. `homeTail()` in
  `loop.ts` is the one place; add to the tail, never a second per-step load.
- Reading an agent's home is **one** `sudo -u agent-<name>` invocation, not one per file, with a
  per-call marker so nothing a file contains can forge a section.
- **Nothing the model writes is ever an argument, let alone a path.** A tool that writes a file
  derives the path and passes the content on stdin.
- A tool that refuses or cannot reach its resource costs the agent **that tool**, not the turn.
  Only the model itself failing ends a run. A home that cannot be read, a summary that cannot be
  written and a schedule that cannot be parsed all follow this.
- A task worker has no Linux user, no home, no memory and no schedules. It is offered neither
  `remember` nor any `*_schedule` tool and falls through to the unknown-tool answer.
- Compaction **never rewrites history**: `messages` rows are untouched and `listMessages` still
  returns all of them. A cut only ever lands between turns; `assertEveryCallAnswered` in
  `loop.test.ts` is the contract.
- A scheduled job is delivered as **an owner message** (`sender` null) through `appendMessage` +
  `runner.start`, and nothing else. An agent-authored one would be skipped by
  `pendingConversation` or counted by `agentChain`. A fired job therefore resets the agent chain,
  which is deliberate.
- `createApp` returns `{ app, runner }`. The runner is process state — the one-turn-per-agent set
  — so anything that starts turns takes that instance rather than building a second one.
- Memory content and schedule prompts never reach the event log. `summarise()` extracts only
  `action` and `command`; a schedule's `tool_result` carries ids and the cron, never the prompt.
- Every turn opens with a `getent` and one `sudo`. Tests asserting on what a turn ran filter it
  out through `tooling()` in `loop.test.ts`.

## Slice 1: memory and the skills index
- Shipped: `daemon/src/home.ts` — a one-invocation home loader (`loadHome`) that reads
  `MAX_MEMORY_CHARS` of `~/memory/MEMORY.md` and `MAX_FRONTMATTER_CHARS` of every
  `~/skills/*/SKILL.md` and `/srv/schermes/shared/skills/*/SKILL.md`, a `parseHome` that pulls
  `name`/`description` out of the frontmatter (folder name as fallback), a `homePrompt` that
  renders the tail, and the `remember` tool (`parseRemember`, `rememberToolDef`, `remember`) with
  `scope: 'lasting' | 'today'`. `loop.ts`: `systemPrompt` takes the tail, `homeTail` loads it once
  per turn for permanent agents only, `rememberToolDef()` joins the permanent-agent tool list and
  `remember` joins `dispatch`. `create-agent-user.sh` creates `memory/` and `skills/`;
  `install.sh` creates `/srv/schermes/shared/skills`. Five tests in `loop.test.ts`, three in
  `tools.test.ts`. `infra/provider-stub.py` gained a `memory` script and `memory`/`skills` report
  fields; `infra/smoke.sh` gained a section that clears the memory, writes a skill, has the agent
  remember a fact, restarts the container and asserts the fact and the skill come back in the
  next turn's system prompt. `docs/configuration.md` and `docs/architecture.md` updated.
- Key decisions: **memory is files, not a table** — the agent already owns a filesystem and
  `ripgrep`, and a row would be a second place to look. **The boot reconcile came free**:
  `reconcileDesktops` already calls `create-agent-user.sh` for every permanent agent and
  `install -d` is idempotent, so existing agents get the directories on the next boot with no new
  code. **A per-call marker, not a fixed delimiter**, so a memory or skill file cannot forge a
  section into the prompt. **The line goes in on stdin**, so a remembered
  `rm -rf / $(whoami)` is written literally — verified against a real bash. **`scope` is
  required**, so the model has to choose which file rather than defaulting into the one that is
  never loaded. **Only the skills index is in the prompt, never the body**; the filesystem is the
  registry and there is no skill table.
- Notes / leftovers: two existing assertions shifted because every turn now opens with a `getent`
  and one `sudo` — `loop.test.ts` lines 210 and 395 filter through a new `tooling()` helper, and
  the smoke run's expected tool list is now `tools=computer,remember,run_command`. Both are
  honest updates, not loosened assertions. `MEMORY.md` past its cap keeps its head, so lines added
  after that are written but not loaded; this is marked with a `ponytail:` comment in `home.ts`
  and its upgrade path is the OVERVIEW's open question about nightly summarisation — **decide
  that in the cron slice, now that the loader exists**. The daily note's `<date>` is UTC from the
  daemon's clock. No UI panel for memory or skills: the owner reads the files through the agent.
- Runtime-unverified: **`infra/smoke.sh`'s new memory-and-skills section has never been run** —
  it needs the docker harness, which is not available on this Mac. It is syntax-checked
  (`bash -n`) and `provider-stub.py` parses, but the section restarts the container once, so it
  costs a desktop respawn and has never been timed. Everything else is covered by unit tests plus
  a direct run of both shell scripts against a real bash and a real directory, with a hostile
  input string.

## Slice 2: context compaction
- Shipped: a `summaries` table (migration `0005_hesitant_invaders.sql`) holding one row per
  compacted stretch of a thread — the agent it was written for, the text, and the message id
  range it stands for. `appendSummary` and `latestSummary` in `conversations.ts`. In `loop.ts`:
  `MAX_TRANSCRIPT_CHARS`, `COMPACTION_TAIL_CHARS`, `SUMMARY_PROMPT`, a `Replay` type, and
  `compact()`, which runs once per turn in front of the first step and hands `transcript()` the
  summary to replay plus the id it stands in for. `transcript()` takes an optional fourth
  argument and drops everything through that id, putting the summary in as a `user` message after
  the system text. Six tests in `loop.test.ts`, one of them two agents compacting the same group thread
  independently; `docs/configuration.md` and
  `docs/architecture.md` updated (the persistence table now says nine).
- Key decisions: **a table, not a message role**. A `'summary'` row in `messages` would have to
  be filtered out of `listMessages`, `pageMessages`, `pendingConversation` and the UI, and in a
  group thread it would reach the *other* agent through the foreign-message branch of
  `transcript()`, which only skips `role === 'tool'` and empty content. A summary belongs to one
  agent, which is why the table carries `sender`: each agent in a group sees its own projection,
  its own tool traffic and nobody else's. **The budget measures what `transcript()` would send**
  after the existing trimming, because trimmed is what the request costs — but **screenshot bytes
  are not counted**, since `MAX_REPLAYED_IMAGES` already bounds them and counting them would put
  every desktop-driving agent permanently over a budget no cut could bring it back under.
  **`COMPACTION_TAIL_CHARS` (260 000) has to clear the incompressible floor**: the last
  `MAX_FULL_OBSERVATIONS` tool results, each of which `describe` may have clipped stdout *and*
  stderr to `MAX_OBSERVATION_CHARS`, is 256 000 characters no cut can remove. Raising either of
  those two means raising the tail with them, which is written down in `docs/configuration.md`.
  **The cut is chosen by walking the agent's own outstanding call ids**, so it only ever lands
  where every call it made has been answered. **The summary is clipped to
  `MAX_OBSERVATION_CHARS`** before it is stored, so a model that answers with the conversation
  back cannot grow the requests the feature exists to shrink.
- Notes / leftovers: no smoke step for compaction — the smoke's threads are a few thousand
  characters and nothing there approaches 400 000, so a step would have to fabricate a thread
  rather than exercise one. `infra/provider-stub.py` is untouched and would answer a summary
  request with its usual report blob; harmless, and only reachable if someone lowers the budget.
  No event type for a compaction either: `EventType` lives in `shared/` and the UI renders it, so
  a compaction is a `log.info` line rather than a row. A summary that cannot be written costs the
  agent the compaction and not the turn, which means the oversized request goes to the endpoint
  and the next turn tries again.
- Runtime-verified: **`infra/smoke.sh` now passes end to end, including slice 1's
  memory-and-skills section, which had never been run.** It was run against an isolated throwaway
  compose project on port 7801 with its own fresh volume, because the dev volume on the default
  project has an owner password set through the UI that the smoke cannot log in with. The
  throwaway stack and its volume were removed afterwards; the dev stack and its data were left
  alone. **Migration 0005 was also applied to the real dev database** — the container was rebuilt
  and restarted on the existing `schermes_schermes-data` volume, the daemon booted, and
  `foreign_key_check` passed with `summaries` created alongside the populated tables.
- Inherited and still worth knowing: the provider stub reports `skills=<name>` when an agent has
  no skills, because its regex matches the "a skill is a folder `~/skills/<name>/SKILL.md`"
  sentence in the empty-skills prompt. Cosmetic — the assertion that matters looks for
  `skills=deploy` and has teeth.

## Slice 3: scheduled tasks
- Shipped: a `schedules` table (migration `0006_shocking_kulan_gath.sql`) holding one standing job
  per row — the agent, the cron expression, the prompt, `paused`, `next_run_at` and `last_run_at`.
  `daemon/src/schedules.ts` is the whole feature: `nextRun` (a `croner` `Cron` with no callback,
  so it starts no timer of its own), `parseSchedule`, the queries, `runDue`, `startScheduler`,
  `schedulePrompt` and the four tool definitions. `daemon/src/loop.ts` offers `schedule_task`,
  `list_schedules`, `pause_schedule` and `cancel_schedule` to permanent agents and dispatches them
  through one `schedule()` helper; `homeTail` appends the agent's own schedules to the same
  once-per-turn tail memory and skills ride in. Four owner routes under
  `/api/agents/:name/schedules` (list, create, PATCH `paused`, DELETE). `main.ts` starts the tick.
  `shared/src/index.ts` gained the `Schedule` type. Eight tests in `loop.test.ts`, two in
  `tools.test.ts`, two in `api.test.ts`. `infra/provider-stub.py` gained a `schedules` report
  field; `infra/smoke.sh` gained a section that creates a job ten seconds out, watches the tick
  deliver it, asserts the agent was shown its own schedule, and then pauses and cancels it.
  `docs/configuration.md` and `docs/architecture.md` updated.
- Key decisions: **`next_run_at` is the whole clock** — no per-job timer, nothing to rebuild at
  boot, and the once-at-boot catch-up is a property of advancing the column *from now* rather than
  a catch-up pass bolted on. **The tick body is synchronous and advances the column before it
  starts the turn**: `runner.start` returns at once, and an await in the due loop would let the
  next tick see the same rows and fire them twice. **The delivered message is the owner's, with
  no sender** — an agent-authored one is excluded by `notSentBy` inside `pendingConversation`, so
  the agent would never wake on it, and it would be counted by `agentChain`, so six fired jobs
  would refuse the agent's next `send_message`; the text names the schedule instead, so the agent
  does not read it as the owner typing at four in the morning. **Pause is its own tool taking a
  boolean**, not an argument on `cancel_schedule`: one tool covers both directions, and a `cancel`
  that does not cancel is a bad thing for a model to be holding. **Resuming recomputes the next
  run from now**, so a month-old paused row does not fire the instant it comes back. **An
  expression with no next run is refused at validation and dropped if it stops having one**
  (`0 0 30 2 *` parses fine and is never due), because such a row would otherwise be permanently
  due and fire every single tick. **Every lookup is scoped to the agent the caller named**, in
  the tool and the route alike: a schedule id is a small integer a model can guess. **No minimum
  interval guard**: `SCHEDULE_TICK_MS` is the real floor, since an expression finer than the tick
  advances to a time already past and so fires once per tick.
- Both deferred questions answered, in `OVERVIEW.md` and `docs/architecture.md`: **a job is
  addressed to the owner thread only**, and **the daemon seeds no nightly memory-summarising job**.
- Notes / leftovers: **no UI panel** — the Definition of Done's "pause and cancel work from the
  tool and from the UI" is half met, and the OVERVIEW now says so. The panel moved out of slice 4
  into one later slice covering schedules, the search key and the MCP servers together, so the
  same screens are not opened twice. Cron is resolved in the **daemon's local time** while the
  daily note's `<date>` is UTC; the two can disagree on a host that sets `TZ`, and neither is
  configurable. No new `EventType` for a fired job: `EventType` lives in `shared/` and the UI
  renders it, so a fire is a `log.info` line and the `tool_call`/`tool_result` pair the tools
  already write. A schedule whose agent row is gone is dropped by the tick rather than by a
  cascade, because the foreign key is `ON DELETE no action` like every other one here — and a
  row the tick drops is **invisible to the owner**, who sees it silently missing from the list;
  giving it a trace means a new `EventType` in `shared/` and a UI renderer, so it belongs with
  the panel slice.
- The smoke's leftover purge sits **near the top of the file**, right after the agents are
  ensured, not in the section that creates a job. A `*/10 * * * * *` row left behind by an
  interrupted run fires every tick, and a turn starting under its own steam in the middle of the
  loop-cap or human-takeover sections is a confusing failure a long way from its cause. The
  section's own trap runs on `EXIT INT TERM` so a cancelled run takes its job with it.
- Runtime-verified: **`infra/smoke.sh` passes end to end, exit 0, including the new section** —
  run against an isolated throwaway compose project on port 7801 with its own fresh volume, then
  torn down with `docker compose down -v`; the dev stack and its data were left alone. The tick
  really fired: the log shows `Scheduled task 1 (*/10 * * * * *) is due` arriving in the owner
  thread with no message sent, the agent answering it, and `schedules=1` coming back out of the
  system prompt of the turn it started. **Migration 0006 was applied to a copy of the real dev
  database** (3 agents, 121 messages, 250 events) pulled out of the `schermes_schermes-data`
  volume: `schedules` was created and `foreign_key_check` came back empty. The copy was used
  rather than rebuilding the dev container, because recreating it destroys the agent home
  directories that hold their memory and skills — a trap slice 2's recipe does not mention.
  The smoke was then run **twice against one volume**, with a `*/10 * * * * *` schedule injected
  between the runs to stand in for one an interrupted run left behind: the second run purged it
  by name and passed, so the file's repeatability promise still holds with schedules in it.

## Slice 4: web search and page fetch
- Shipped: `daemon/src/web.ts` is the whole feature — the SSRF guard (`net.BlockList`,
  `refuseAddress`, a parse-time half and a post-DNS half), `parseWebSearch` / `parseWebFetch`,
  `webSearch` against Brave, `parseBraveResults`, `searchPrompt`, `toText` over `html-to-text`,
  `readCapped`, `fetchPage`, and the two tool definitions. `settings.ts` gained `web.searchUrl`
  and `web.searchKey` rows, `readWebSettings`, `writeSearchUrl`, `writeSearchKey` and
  `searchConfig`, all following the provider key's shape. `shared/src/index.ts` gained
  `WebSettings` / `WebSettingsUpdate`; `GET`/`PUT /api/settings` carry `searchUrl` and
  `searchKeySet`. `loop.ts` offers `web_search` and `web_fetch`, dispatches them, and the system
  prompt now points at them before Chromium. Fifteen tests in `web.test.ts`, six in
  `loop.test.ts`, two in `api.test.ts` — 151 daemon tests, up from 128. `infra/provider-stub.py`
  gained a `web` script; `infra/smoke.sh` gained a section that asserts the refusal.
  `docs/configuration.md` and `docs/architecture.md` updated, including a cross-reference from
  § Security model.
- Key decisions: **Brave, and the parser is Brave's shape and nothing else.** The key travels as
  the `X-Subscription-Token` header rather than in a JSON body, which keeps it out of anything
  that logs a request, and `web.results[]` is already `{title, url, description}`. The endpoint is
  a setting for a proxy or a mirror, **not** so Tavily can be dropped in — Tavily is a POST with
  the key in the body and would need a second parser and a second request shape.
  **`html-to-text` earns its place**: no stdlib HTML parser, no installed dependency that does it,
  and the slide is right that a tag-stripping regex hands the model a page of CSS. It ships no
  types, so `@types/html-to-text@9` covers the v10 runtime. The major-version gap is not a lie:
  v10's own changelog says it is a maintenance release that adds no features and removes no
  deprecated ones, so the API the v9 types describe is the API v10 has.
  **`net.BlockList` is the guard**, stdlib, checked twice — once at parse time against an address
  written into the URL, once against *every* address the name resolves to. The trap that cost
  real time: `BlockList` already maps an IPv4-mapped IPv6 address onto the IPv4 rules, so
  `[::ffff:169.254.169.254]` is caught by the `169.254.0.0/16` entry, and adding `::ffff:0:0/96`
  as a rule of its own **blocks every IPv4 address on the internet**. That was measured, not
  assumed. **Redirects are not followed**: a 3xx comes back as the target URL in an observation,
  so the agent's next call is an ordinary `web_fetch` that re-enters the guard with the new host,
  which is cheaper than following a hop and strictly safer than re-checking one.
  **Two caps for two reasons** — `MAX_PAGE_BYTES` stops a stream being buffered at all, and the
  extracted text is then clipped to `MAX_OBSERVATION_CHARS` by `fetchPage`, which takes the limit
  as a parameter so `web.ts` never imports `loop.ts` and the constant lives in one place.
  **The key is stripped on three paths, not one**: the echoed error body, the transport failure's
  own message, and the event — which carries `'search failed'` rather than the endpoint's words at
  all, because an echoed request body has no business in the log. `withoutKey` from `provider.ts`
  does the first two; it exists there for exactly this reason and is reused rather than repeated.
  **A task worker gets both tools**, the only ones it shares with a permanent agent: `remember`
  and the schedule tools are withheld because a worker has no home and is never started again,
  and neither applies to an HTTP request the daemon makes on its behalf. It costs nothing besides
  — a worker already has `run_command` and therefore `curl`.
- The honest framing, written into `docs/architecture.md` as a **Deferred**: the guard is
  **defence in depth, not a new boundary**. The daemon and the agent Linux users share one network
  namespace, so `run_command` plus `curl` already reaches `127.0.0.1:7777`. What the guard buys is
  that the *daemon* does not become the proxy for a URL that arrived from somewhere other than the
  agent's own judgement — a search result, a page it was told to read. Making it a real boundary
  means giving the agent users a namespace of their own. The DNS-rebinding window between the
  lookup and `fetch`'s own resolution is the other ceiling, marked with a `ponytail:` comment
  naming the upgrade path: connect to the checked address and carry the name in a `Host` header,
  which needs a dispatcher `fetch` does not expose.
- Notes / leftovers: **no UI** — no settings field for the search key. That is the one later panel
  slice with the schedules and the MCP servers, and the Definition of Done's web line is
  `[user-gated]` anyway because nobody has a Brave key in this tree. The route exists, so the key
  can be set with a `PUT /api/settings` today.
  **No smoke step exercises a successful fetch, and none can.** A stub page would have to be served
  from loopback and loopback is exactly what the guard refuses, so the only offline assertion is
  the refusal — which is what the new section makes, against the daemon's own API, and it is the
  more valuable half. A live search or fetch needs the internet and a key, which the slide forbids.
  `searchKeySet` reports a stored row rather than a non-empty key, which is the provider key's
  existing behaviour and its documented wart: a `PUT` with `searchKey: ""` leaves the boolean true
  while `searchConfig` returns undefined.
- Runtime-verified: **`infra/smoke.sh` passes end to end, exit 0, including the new section** —
  run against an isolated throwaway compose project on port 7801 with its own fresh volume, built
  with `--build` because this slice adds a dependency, then removed with `docker compose down -v`;
  the dev stack and its data were left alone. The refusal really fired inside the container:
  `error: 127.0.0.1 is a loopback, link-local or private address and will not be fetched`, with
  the turn carrying on afterwards and the agent reporting both web tools on its list. No migration
  in this slice, so nothing to apply to the dev database.

## Slice 5: the MCP client
- Shipped: `daemon/src/mcp.ts` is the whole feature — the two server shapes (`McpStdioServer`,
  `McpHttpServer`), `parseMcpServers`, `stdioArgv`, `systemTransport` over the SDK's
  `StdioClientTransport` and `StreamableHTTPClientTransport`, and `openMcp`, which returns an
  `McpSession` holding the namespaced `ToolDef`s, the per-server failures, a `call` and a `close`.
  `settings.ts` gained the `mcp.servers` row with `mcpServers` and `writeMcpServers`, encrypted
  like the provider key. `shared/src/index.ts` gained `McpServerSummary` and `McpTestResult`.
  `loop.ts` carries `mcp: (agent) => Promise<McpSession | undefined>` on both `LoopDeps` and
  `RunnerDeps`, opens the session once per turn beside the system text and the compaction, appends
  its tools after the built-in list, dispatches anything starting with `mcp__` through the
  session's own route map, and closes it in a `finally` around the whole turn. Three owner routes:
  `GET`/`PUT /api/mcp/servers` and `POST /api/agents/:name/mcp/:server/test`. Eleven tests in
  `mcp.test.ts`, five in `loop.test.ts`, three in `api.test.ts` — 171 daemon tests, up from 152.
  `docs/configuration.md` and `docs/architecture.md` updated, including a cross-reference from
  § Security model. `@modelcontextprotocol/sdk@1.30.0` is the one new dependency.
- Key decisions: **the SDK and nothing hand-rolled** — the protocol moves, and a hand-written
  client would be three slices rather than one. **A stdio server runs as the agent's Linux user**,
  through `asAgent`; its `env` block rides in as operands to the `env` that prefix already builds,
  because **neither sudoers rule grants `SETENV`** and `sudo` strips what it was handed. That was
  checked against a real `env`: assignments before the command work, and a value containing `=`
  survives. **One encrypted settings row, not a table** — a stdio `env` block and an http header
  set are both places an API key goes, so the list is encrypted whole; `GET` answers with each
  server's identity and the *names* of its secrets, never the values. **Their own routes rather
  than fields on `PUT /api/settings`**: a server is an object, not a string, and testing one is a
  request of its own. **The test route is agent-scoped** (`/api/agents/:name/mcp/:server/test`)
  and goes through the same `openMcp` a turn does — an owner-scoped test would have to spawn a
  stdio server as `schermes`, which is the one thing this slice forbids. **Routing is the
  session's own `Map`, never a split on the name**: a server called `a__b` or a tool called
  `get__all` makes `mcp__<server>__<tool>` ambiguous to parse and never ambiguous to look up, and
  the map is less code than the split. Server names are additionally refused an underscore.
  **Connected once per turn and dropped when it ends**, in a `finally` around the whole
  `try`/`catch` — `runAgent` has five exits and every one of them would otherwise leak a child
  process. Pooling was considered and rejected: it buys one reconnect per turn and costs an idle
  `npx` per configured server with a lifetime nothing owns. **Tools are sorted by name within each
  server and appended after the built-ins**, so the request head the prompt cache keys on is the
  same across the steps of a turn and across turns. **A task worker is offered none of them** — it
  has no Linux user of its own, so a stdio server would run as its parent.
- Notes / leftovers: **no UI**, and **three Definition-of-Done lines now wait on the one panel
  slice**: the schedules panel (slice 3), the search-key field (slice 4) and the MCP servers panel
  (this one). None of the three is ticked. **`MAX_MCP_SERVERS` is enforced on write and on read
  through the same parse**, so lowering the cap later would not truncate a stored list — it would
  refuse it whole and read as zero servers until the owner `PUT`s a shorter one. The failure
  direction is right; the panel slice should know a `PUT` is the only way back.
  **No smoke step, by the slide's own permission** — a networked server is forbidden there and a
  spawned one would have to be installed in the image for a single assertion. The smoke's default
  configuration has no MCP server, which is why all three of its tool-list assertions
  (`infra/smoke.sh:601`, `:907`, `:1224`) are untouched and were not moved. **No migration**: the
  servers are a settings row, so there is nothing to apply to the dev database.
  **No OAuth and no resources or prompts** — an http server is reached with the headers the owner
  configured, and only `tools/list` and `tools/call` are used. Both are written down as Deferred.
  A `ponytail:` comment in `openMcp` names the real ceiling: every configured server is connected
  whether or not the agent calls one, because `tools/list` is how the list is built, so a turn
  costs one spawn per stdio server. The upgrade path is caching a server's tool list.
- Runtime-verified: **`infra/smoke.sh` passes end to end, exit 0** — run against an isolated
  throwaway compose project on port 7801 with its own fresh volume, built with `--build` because
  this slice adds a dependency, then removed with `docker compose down -v`; the dev stack and its
  data were left alone. The permanent agent's reported tool list came back byte-identical to what
  slice 4 left (`cancel_schedule,computer,...,web_fetch,web_search`) and `mcp__` appears nowhere
  in the run, which is the assertion that the three sites did not have to move.
  **The round trip is against a real MCP server over the real protocol**, not a stub: `mcp.test.ts`
  stands up the SDK's own `Server` on an `InMemoryTransport` linked pair, and the client connects,
  lists, calls and closes over it. What is still outstanding on the Definition of Done's MCP line
  is only a **networked or spawned** server, which is what `[user-gated]` meant.

## Slice 6: the owner's panels
- Shipped: the three panels three Definition-of-Done lines were waiting on, and nothing in the
  daemon's routing. `ui/src/api.ts` gained `settingsUpdate` plus seven calls —
  `mcpServers`, `saveMcpServers`, `testMcpServer`, `schedules`, `createSchedule`,
  `pauseSchedule`, `deleteSchedule` — and its settings types widened to
  `ProviderSettings & WebSettings`. `ui/src/Settings.tsx` became two panels: the provider one now
  carries **Search endpoint** and **Search key**, and a new **MCP servers** panel lists what is
  stored, tests one as a chosen agent and replaces the list from a JSON textarea.
  `ui/src/Schedules.tsx` is new and is a **third tab on the agent pane** beside chat and desktop.
  `shared/src/index.ts` gained the `schedule_dropped` event type; `daemon/src/schedules.ts`
  records one. Two tests in a new `ui/src/api.test.ts` and one assertion added to `loop.test.ts` —
  11 UI tests, up from 9; 171 daemon tests, unchanged in count. **No new dependency, no new route,
  no migration, no change to `infra/smoke.sh`.**
- Key decisions: **the empty-key rule moved out of the component into `settingsUpdate`**, which is
  a pure function in `api.ts` and therefore testable — the UI test runner is `node --test` with no
  DOM, so a rule left in JSX could not be covered at all. It is the money path: a blank field must
  be **absent** from the body, because the daemon writes whatever string it is handed and `''`
  erases the key. Now that there are two write-only keys, one function covers both and they cannot
  drift.
  **The MCP list is a JSON textarea, not a form.** A server is an object of two shapes with a
  free-form env block or header set; a form would be a second copy of `parseMcpServers` in the
  browser that could disagree with the one that decides what may run. The textarea posts what the
  owner wrote and the daemon's parse is the only validator, reporting its own error as the panel's.
  **The box does not start filled in**, for two reasons that both have to hold: the secrets are
  never read back, *and* `summarise` joins a stdio server's `command` and `args` into one string
  that cannot be split back apart. A panel that round-tripped `GET` into `PUT` would write every
  server with empty secrets, which is exactly the way an owner discovers the rule by wiping a
  token. The stored list is shown read-only above the box with each server's secrets **by name**,
  so the owner can see what they have to re-enter.
  **The test-as select offers permanent agents only** (`parentId === undefined`). A stdio server
  runs as the agent's own Linux user and a task worker has none, so a test as a worker would spawn
  as its parent and be right about a connection a turn never makes.
  **Schedules are a tab on the agent, not a section of settings**, because a schedule belongs to
  one agent. The list polls on the same five-second timer the conversation list uses: the agent
  writes its own through `schedule_task`, so it is somebody else's list as well as the owner's.
- The one thing that was decided rather than inherited: **a dropped schedule now leaves a trace,
  but only the half that can.** The slide asked about a row whose agent is gone. That one can have
  no event and never will: `events.agent_id` is `NOT NULL` and references `agents`, so there is no
  row to hang it on — and the case is unreachable anyway, because no route deletes an agent. The
  tick's *other* drop, a cron that ran out of runs, happens to a live agent and now records a
  `schedule_dropped` event. That is a narrower answer than the question asked, on purpose, and the
  slide's claim that it needs "a renderer in the UI" turned out to be wrong: `Activity` in
  `Desktop.tsx` already renders any type with its JSON payload, so the UI cost was zero.
- Notes / leftovers: **the three Deferred entries naming this slice are gone** from
  `docs/architecture.md` § Scheduled tasks, § Web search and fetch and § MCP, replaced by
  Requirements describing what was built. § Web UI gained the three panels.
  `docs/configuration.md` gained pointers to where the owner sets each thing and the drop event.
  **The dev stack on 7777 is still serving slice 5's bundle** and was deliberately not rebuilt —
  a recreate rebuilds the agent Linux users from the surviving rows and their homes, memory and
  skills go with it. The owner picks the moment.
- Runtime-verified: `pnpm -r check` → 0 across shared, ui and daemon; `pnpm -r test` → 0 (daemon
  171 pass, ui 11 pass). **`infra/smoke.sh` passes end to end, exit 0**, run against an isolated
  throwaway compose project on port 7801 with its own fresh volume, built with `--build` so the
  run was against *this* slice's bundle, then removed with `docker compose down -v`; the dev stack
  and its data were left alone. **Then every panel was driven in a real browser against that same
  container before it was torn down**: both MCP servers saved and came back showing `PROBE_TOKEN`
  and `Authorization` **by name only**; a test as `smoke-one` spawned the stdio server as the
  agent's Linux user and reported `probe: MCP error -32000: Connection closed` as an error line
  rather than a failed request; the search key saved and its field flipped to
  `stored — type to replace it`; a schedule was created, paused, resumed and cancelled, and a bad
  cron came back as the daemon's own `not a cron is not a cron expression with a next run`.
  The empty-key rule was proved on the wire, not only in the unit test: with both key fields blank
  the `PUT /api/settings` body was
  `{"baseUrl":…,"model":…,"extraBody":"","searchUrl":…}` and carried **neither** `apiKey` nor
  `searchKey`. No React errors in the console.

## Completion review
- The `/complete` reviewer found one bug outside the Definition of Done and it was fixed before
  archiving: a turn that had written to a peer (or spawned a worker) and was then refused the
  display by a held control ended with `transition(endState())` from `using_computer` or
  `using_terminal`, which the table did not allow to reach `waiting_for_agent` or
  `waiting_for_task_worker`; the turn failed instead of waiting. `TRANSITIONS` now lets both
  acting states reach every waiting state, the same reasoning the table already applied to
  `waiting_for_user` for a restart. `loop.test.ts` gained one test that fails on the old table
  (172 daemon tests). No other finding.
