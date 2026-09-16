# Configuration reference

Everything schermes reads from its environment, and the limits it does not.

## Environment variables

The daemon reads exactly five, all in `daemon/src/config.ts`. Each is validated at startup and
a bad value stops the daemon rather than being silently replaced by a default.

| Variable               | Default             | Meaning                                                       |
| ---------------------- | ------------------- | ------------------------------------------------------------- |
| `SCHERMES_PORT`        | `7777`              | The one port schermes exposes. Must be 1–65535.               |
| `SCHERMES_DATA_DIR`    | `/var/lib/schermes` | Holds `schermes.db`, `master.key` and `desktops/`.            |
| `SCHERMES_GEOMETRY`    | `1920x1200`         | Desktop size. The model sees it shrunk to fit 1280x800.        |
| `SCHERMES_MAX_LOOPS`   | `8`                 | Concurrent agent turns. A request above it gets a 429.         |
| `SCHERMES_MAX_WORKERS` | `4`                 | Concurrent task workers, counted across all parents.           |

`SCHERMES_GEOMETRY` is the size `Xvnc` is started with. The model never sees it directly: a
screenshot is shrunk to fit 1280x800 (1920x1200 becomes exactly 1280x800), the computer tool's
coordinate bounds are that shrunk view, and the coordinates the model sends back are scaled onto
the display. A geometry at or below 1280x800 is used as is. Changing it restarts every desktop
still running at the old size the next time the daemon starts, rather than adopting it.

Set them in a `.env` next to `docker-compose.yml`, or in `infra/schermes.service` on a bare
host. The compose file passes `SCHERMES_PORT` through and publishes the same number, so changing
it in one place moves both. Four variables are the compose file's alone: `SCHERMES_BIND`, the
address the port is published on (`127.0.0.1` by default, `0.0.0.0` for LAN access without a
proxy), and for the `domain` profile `SCHERMES_DOMAIN`, `SCHERMES_HTTP_PORT` (80) and
`SCHERMES_HTTPS_PORT` (443).

Everything the daemon derives — the database path, the master key path, the migrations
directory, the built UI, the desktop scripts — is resolved from `SCHERMES_DATA_DIR` or from
`import.meta.dirname`, and none of it is separately configurable. `import.meta.dirname` rather
than a relative path because the container's command has no working directory.

## What the scripts read

Only the runnable checks, and only to point themselves at a daemon that is already running.

| Variable                     | Default                  | Used by                        |
| ---------------------------- | ------------------------ | ------------------------------ |
| `SCHERMES_URL`               | `http://127.0.0.1:$PORT` | `infra/smoke.sh`               |
| `SCHERMES_SMOKE_PASSWORD`    | `smoke-test-password`    | `infra/smoke.sh`               |
| `SCHERMES_SMOKE_SECOND_PORT` | `7778`                   | `infra/smoke.sh`, second daemon |
| `SCHERMES_SMOKE_STUB_PORT`   | `7790`                   | `infra/smoke.sh`, provider stub |
| `SCHERMES_CHECK_PORT`        | `8899`                   | `infra/desktop/check.sh`       |

## Provider settings

The model endpoint is not an environment variable. Base URL, model name, API key and an optional
JSON object of extra request fields (`extraBody`, merged under every request: OpenRouter's
`provider` routing block, `reasoning`, `max_tokens`) are rows in the `settings` table, written through the settings screen or `PUT /api/settings`, and the key is
AES-GCM encrypted with the master key before it is stored. It is never returned by the API and
never reaches a log: `GET /api/settings` answers with `apiKeySet` as a boolean instead.

A consequence worth knowing: an empty string is a value. The daemon stores whatever it is
handed, so a settings write that includes `apiKey: ""` erases the stored key. The UI omits the
field entirely when it is untouched.

## Web search settings

`web_search` and `web_fetch` need no configuration to exist; `web_search` needs a key to run.
Both live in the same `settings` table and are written through the same `PUT /api/settings`.

| Field       | What it is                                                                    |
| ----------- | ----------------------------------------------------------------------------- |
| `searchUrl` | The search endpoint. Empty means the built-in `https://api.search.brave.com/res/v1/web/search`. It exists for a proxy or a mirror: the response parser is **Brave's shape** and a differently shaped API will not work. |
| `searchKey` | The Brave Search subscription token. AES-GCM encrypted with the master key, never returned — `GET /api/settings` answers with `searchKeySet` as a boolean, exactly like the provider key. |

Two consequences worth knowing.

**No key is a normal state.** A fresh install has none, and `web_search` answers with an
observation saying so rather than failing the turn. `web_fetch` needs no key and works either
way. Both fields are on the settings screen, and the key follows the provider key's rule there:
blank means keep the stored one.

**`web_fetch` will not reach this machine.** Loopback, link-local, private, CGNAT, multicast and
reserved ranges are refused, before the request and again after the hostname resolves, and
redirects are not followed — a 3xx is reported so the agent can call again with the new URL.
There is no setting that turns this off. An agent that genuinely needs a local URL has
`run_command` and `curl`.

## Push notifications

Optional, stored on the same settings row set, set from the app's settings screen through
`PUT /api/settings` with the fields below and read back under `push` in `GET /api/settings`.

| Field          | Meaning                                                                       |
| -------------- | ----------------------------------------------------------------------------- |
| `pushKeyId`    | The APNs key id from the Apple developer account.                              |
| `pushTeamId`   | The team id.                                                                   |
| `pushBundleId` | The app's bundle identifier, `dev.schermes.Schermes` unless you changed it.    |
| `pushKey`      | The contents of the `.p8` file. AES-GCM encrypted with the master key, never returned — `GET` answers `keySet`. An empty string removes it. |
| `pushSandbox`  | `true` for a development-signed device build, which APNs serves from its sandbox host. |

Devices register themselves: `POST /api/devices` with `{token, platform}` on every launch,
`GET /api/devices` lists them, `DELETE /api/devices/:token` forgets one, and a token APNs reports
dead is dropped by the push that learnt it. `POST /api/settings/push/test` sends "Push works."
to every device. What is pushed: what an agent says at the end of a turn in its own thread with
the owner, why a turn failed, and a deletion request. The app needs a real Apple team and the
`aps-environment` entitlement on a device build to be handed a token at all.

## MCP servers

The owner's MCP servers are **one settings row**, `mcp.servers`, holding the whole list as JSON
and **AES-GCM encrypted with the master key** — a stdio server's `env` block is where an API key
goes and an http server's headers are where a bearer token goes. They have their own routes
rather than fields on `PUT /api/settings`: `GET /api/mcp/servers` lists them, `PUT /api/mcp/servers`
replaces the list, `PUT /api/mcp/servers/<name>` adds or changes one, `DELETE /api/mcp/servers/<name>`
removes one, and `POST /api/agents/<name>/mcp/<server>/test` connects to one as that agent and says
what came back. The per-server routes read the row, replace or append by name, and write it back
through the same parse the loader uses, so what may be stored is still what may be run — and the
name in the path wins over any name in the body.

A stdio server:

```json
{ "servers": [
  { "name": "files", "command": "npx", "args": ["-y", "pkg"], "env": { "TOKEN": "..." } }
] }
```

An http one:

```json
{ "servers": [
  { "name": "docs", "url": "https://example.com/mcp", "headers": { "authorization": "Bearer ..." } }
] }
```

| Field     | What it is                                                                       |
| --------- | -------------------------------------------------------------------------------- |
| `name`    | 1–32 lowercase letters, digits or hyphens, and **no underscore**, so `mcp__<server>__<tool>` reads one way however either half is written. |
| `command` | The executable, for a stdio server. It runs as the **agent's own Linux user**, never as `schermes`. Either this or `url`, never both. |
| `args`    | Its arguments. Optional, empty by default.                                        |
| `env`     | Variables it is started with. Optional. Keys must be variable names.               |
| `url`     | The endpoint, for a streamable-HTTP server. `http` or `https` only.               |
| `headers` | Headers every request carries. Optional.                                           |

Four consequences worth knowing.

**Secrets are never read back, and a blank one keeps what is stored.** `GET /api/mcp/servers`
returns each server's identity and the *names* of the variables or headers it carries, never their
values — the provider key's rule. So on `PUT /api/mcp/servers/<name>` an `env` or `headers` entry
whose value is `""` takes the stored value for that key, and a key the body leaves out is removed
with it: an owner changes a server's command without ever having seen its token. The merge happens
before the parse. The replace-all `PUT /api/mcp/servers` has no such merge — it is the whole list
or nothing, secrets included, which is why the app writes one server at a time instead. Its
Plugins page edits a server in a form, shows each stored value as "Stored" rather than as itself,
and leaves it blank to keep it.

**The tool list is no longer static.** A configured server's tools are offered as
`mcp__<server>__<tool>`, sorted by name, after every built-in tool. They are connected once at
the start of a turn and dropped when it ends, so the list is identical across the steps of one
turn and the prompt cache holds.

**A server that is down costs that server's tools and nothing else.** The turn runs, the rest of
the list is offered, and the reason is a log line — or, from the test route, the error itself.

**A task worker gets no MCP tools.** It has no Linux user of its own, so a stdio server would run
as its parent, and it is one job that is never started again.

## Limits that are not configurable

These are constants in the source. They are listed because they are the answers to "why did it
stop", not because anything reads them from the environment. Changing one is a code edit.

| Limit                     | Value              | Where                     | What it bounds                                    |
| ------------------------- | ------------------ | ------------------------- | ------------------------------------------------- |
| `MAX_STEPS`               | 200                | `daemon/src/loop.ts`      | Tool calls in a single turn                       |
| `MAX_ROUNDS`              | 16                 | `daemon/src/loop.ts`      | Turns one agent drains back to back               |
| `MAX_REPLAYED_IMAGES`     | 3                  | `daemon/src/loop.ts`      | Screenshots carried in one model request          |
| `MAX_OBSERVATION_CHARS`   | 16 000             | `daemon/src/loop.ts`      | Text of one tool result reaching the model        |
| `MAX_FULL_OBSERVATIONS`   | 8                  | `daemon/src/loop.ts`      | Tool results carried in full; older ones are cut to 400 chars |
| `MAX_TRANSCRIPT_CHARS`    | 400 000            | `daemon/src/loop.ts`      | When a thread is compacted: the characters `transcript` would send, screenshots excluded |
| `COMPACTION_TAIL_CHARS`   | 260 000            | `daemon/src/loop.ts`      | How much of the end of a compacted thread is replayed verbatim behind the summary |
| `MAX_AGENT_CHAIN`         | 6                  | `conversations.ts`        | Agent-to-agent messages between owner messages    |
| `MAX_MESSAGE_CHARS`       | 8 192              | `conversations.ts`        | One message                                       |
| `MAX_BRIEF_CHARS`         | 4 096              | `daemon/src/workers.ts`   | A task worker's brief                             |
| `SCHEDULE_TICK_MS`        | 30 s               | `daemon/src/schedules.ts` | How often due schedules are looked for, and so how often one can fire |
| `MAX_SCHEDULES`           | 20                 | `daemon/src/schedules.ts` | Scheduled tasks one agent may hold               |
| `MAX_CRON_CHARS`          | 100                | `daemon/src/schedules.ts` | One cron expression                               |
| `MAX_PROMPT_CHARS`        | 2 000              | `daemon/src/schedules.ts` | The prompt a due schedule starts a turn with      |
| `MAX_SEARCH_RESULTS`      | 8                  | `daemon/src/web.ts`       | Results one `web_search` asks the endpoint for     |
| `MAX_QUERY_CHARS`         | 400                | `daemon/src/web.ts`       | One search query                                  |
| `MAX_URL_CHARS`           | 2 000              | `daemon/src/web.ts`       | One URL handed to `web_fetch`                     |
| `MAX_PAGE_BYTES`          | 2 000 000          | `daemon/src/web.ts`       | Bytes read off the socket before extraction; the text is then cut to `MAX_OBSERVATION_CHARS` |
| `REQUEST_TIMEOUT_MS`      | 20 s               | `daemon/src/web.ts`       | One search or page fetch                          |
| `MAX_MCP_SERVERS`         | 8                  | `daemon/src/mcp.ts`       | Servers the owner may configure, and so processes one turn may start |
| `MCP_CONNECT_TIMEOUT_MS`  | 20 s               | `daemon/src/mcp.ts`       | Connecting to one server and listing its tools    |
| `MCP_CALL_TIMEOUT_MS`     | 120 s              | `daemon/src/mcp.ts`       | One MCP tool call                                 |
| `MAX_MEMORY_CHARS`        | 8 000              | `daemon/src/home.ts`      | `~/memory/MEMORY.md` reaching the prompt; the head is kept |
| `MAX_FRONTMATTER_CHARS`   | 1 000              | `daemon/src/home.ts`      | How much of a `SKILL.md` is read to find its name and description |
| `MAX_REMEMBER_CHARS`      | 1 000              | `daemon/src/home.ts`      | One `remember` entry                              |
| `DEFAULT_PAGE` / `MAX_PAGE` | 50 / 200         | `daemon/src/app.ts`       | Messages per page                                 |
| `SESSION_TTL_MS`          | 30 days            | `daemon/src/auth.ts`      | How long a session cookie lasts                   |
| `MIN_PASSWORD_LENGTH`     | 8                  | `shared/src/index.ts`     | The owner password                                |
| `IDLE_TIMEOUT_MS`         | 120 s              | `daemon/src/provider.ts`  | Silence between bytes of one model call; retried once, like 429 and 5xx |
| Terminal timeout          | 120 s, max 600 s   | `daemon/src/terminal.ts`  | One command, unless the caller asks for less      |
| `MAX_TYPE_CHARS`          | 2 000              | `daemon/src/computer.ts`  | One `type` action                                 |
| `MAX_CLIPBOARD_CHARS`     | 64 KiB             | `daemon/src/computer.ts`  | A clipboard write                                 |
| `MAX_DISPLAY`             | 999                | `daemon/src/agents.ts`    | Highest X display, so 999 permanent agents        |
| `MAX_LABEL_CHARS`         | 64                 | `daemon/src/agents.ts`    | An agent's label, on one line; a client's `look` token follows the same rule |
| `MAX_PROFILE_CHARS`       | 4 000              | `daemon/src/interview.ts` | An agent's profile, written by `set_profile` or `PATCH /api/agents/:name` |
| `MAX_QUESTIONS`           | 4                  | `daemon/src/interview.ts` | Questions one `ask_owner` call may put to the owner |
| `MAX_FILE_BYTES`          | 25 000 000         | `daemon/src/home.ts`      | One file handed to an agent through `POST /api/agents/:name/uploads`, or taken out through `GET .../files` |
| `MAX_EVENTS`              | 1 000              | `daemon/src/app.ts`       | The most `?limit=` may ask `GET .../events` for   |
| `MAX_SEARCH_CHARS`        | 200                | `daemon/src/app.ts`       | One `GET /api/search?q=` needle                   |
| `MAX_SEARCH_HITS`         | 50                 | `conversations.ts`        | Rows one search answers with, newest first, each cut to a 240-character snippet |
| `MAX_MEMORY_FILE_CHARS`   | 64 000             | `daemon/src/home.ts`      | A memory file as the owner reads or writes it through `/api/agents/:name/memory` |
| `APNS_TOKEN_TTL_MS`       | 50 min             | `daemon/src/push.ts`      | How long one provider JWT is reused; APNs refuses one older than an hour |
| `MAX_PUSH_BODY_CHARS`     | 200                | `daemon/src/push.ts`      | The body of a push; the thread has the rest       |
| `MAX_IMAGE_BYTES`         | 5 000 000          | `daemon/src/app.ts`       | A picture the owner sends with a message, decoded |

Agent names match `^[a-z0-9][a-z0-9-]{0,30}$`. The name becomes the Linux user `agent-<name>`,
so it is validated at every boundary that accepts one.

A name is the system identity and never changes. What the owner is shown is the agent's `label`:
free text, any script, up to `MAX_LABEL_CHARS` on one line, and purely cosmetic — nothing
addresses, routes, runs as or names a file after a label, and the app derives the name from it
when an agent is created (`Bob the Builder` runs as `agent-bob-the-builder`). `PATCH
/api/agents/:name` changes a label, a look or a profile; nothing changes a name.

An agent's `profile` is what it is for, in Markdown, in its system prompt every turn. A new
agent has none and interviews the owner with `ask_owner` to write one with `set_profile`;
`POST /api/agents` starts that interview when a provider is configured, and a body carrying a
`profile` skips it. A blank profile on `PATCH` clears it, which puts the agent back to asking.

## Memory and skills

Neither is configurable, because neither is a setting: both are directories in the agent's home,
created by `infra/desktop/create-agent-user.sh` and therefore by every boot reconcile.

| Path                              | What it is                                                       |
| --------------------------------- | ---------------------------------------------------------------- |
| `~agent-<name>/memory/MEMORY.md`  | Curated memory, loaded into the system prompt at the start of every turn. |
| `~agent-<name>/memory/<date>.md`  | The day's notes, appended and never loaded. `<date>` is UTC.      |
| `~agent-<name>/skills/<name>/SKILL.md` | One skill, per agent.                                        |
| `/srv/schermes/shared/skills/<name>/SKILL.md` | One skill, shared by every agent.                   |

A `SKILL.md` is indexed by the `name` and `description` in its frontmatter; without frontmatter
the folder name stands in for the name. Only the index reaches the prompt, never the body.

Once `MEMORY.md` is longer than `MAX_MEMORY_CHARS` the head is what the prompt carries, so lines
added after that point are written but not loaded. Nothing summarises the file on a schedule by
default; an owner or an agent that wants that writes a schedule for it, which is what the cron
slice decided rather than seeding one.

Two display ranges are partitioned and must stay that way. The daemon allocates from `:1`
upward; `infra/desktop/check.sh` owns `:101`–`:103`. A VNC port is `5900 + display` and a
Chromium debugging port is `9222 + display`, both bound to loopback only. The latter is set in
`/etc/chromium.d/schermes` by `install.sh` and expected by the daemon's `browser` tool.

## Context compaction

Neither constant is a setting either, but they depend on each other and on the trimming above.
`COMPACTION_TAIL_CHARS` has to clear what no cut can remove — the last `MAX_FULL_OBSERVATIONS`
tool results, each of which `describe` may have clipped stdout *and* stderr to
`MAX_OBSERVATION_CHARS` — or compaction fires every turn and shrinks nothing. Raising
`MAX_FULL_OBSERVATIONS` or `MAX_OBSERVATION_CHARS` means raising the tail with them.

Screenshot bytes are deliberately not counted towards `MAX_TRANSCRIPT_CHARS`:
`MAX_REPLAYED_IMAGES` already bounds them, and counting them would put every desktop-driving
agent permanently over a budget compaction cannot bring it back under.

A summary is stored clipped to `MAX_OBSERVATION_CHARS`, like any other text the transcript
carries, so a model that answers with the whole conversation back cannot grow the requests the
feature exists to shrink.

## Scheduled tasks

A schedule is a row, not a setting: a cron expression, a prompt, and when it is next due. The
owner writes one through `POST /api/agents/<name>/schedules` — or the **schedules** tab on the
agent's pane, which is the same route — or the agent writes its own with `schedule_task`; all of
them go through the same parse, so what one may write the others may too.

| Field       | What it is                                                                   |
| ----------- | ---------------------------------------------------------------------------- |
| `cron`      | Five fields, or six with seconds in front. **Cron only** — the model translates natural language before it calls the tool. |
| `prompt`    | What the agent is asked when the job fires, written for a future turn with none of the conversation in front of it. |
| `paused`    | Kept but never fired. Resuming recomputes the next run from now, so nothing is made up. |
| `nextRunAt` | When it is due. Advanced from *now* after a run, never from the slot that was missed. |

Two consequences worth knowing.

`SCHEDULE_TICK_MS` is the real floor on how often a job fires. An expression finer than the tick
— `* * * * * *`, say — advances to a time that has already passed by the next pass, so it fires
once per tick rather than once per second.

A schedule the tick drops because its cron ran out of runs records a `schedule_dropped` event,
which is the owner's only trace of it: the row itself is gone from the list.

Cron expressions are resolved in the **daemon's local time**, which in the container is whatever
`TZ` says and UTC by default. The daily note's `<date>` is UTC, so the two can disagree by a few
hours on a host that sets `TZ`; neither is configurable and the schedule is the one that matters.

## TLS

There is none in the daemon, on purpose. schermes speaks plain HTTP on one port; the compose
file's `domain` profile puts Caddy in front of it — see
[deployment](deployment.md#a-linked-domain). The session cookie is deliberately not `Secure`,
because a `Secure` cookie is dropped over the plain HTTP the daemon actually speaks.
