# Configuration reference

Everything schermes reads from its environment, and the limits it does not.

## Environment variables

The daemon reads exactly seven, all in `daemon/src/config.ts`. Each is validated at startup and
a bad value stops the daemon rather than being silently replaced by a default. The one exception
is an APNs key file that cannot be read or is not a `.p8`: that is a log line, and push stays off.

| Variable               | Default             | Meaning                                                       |
| ---------------------- | ------------------- | ------------------------------------------------------------- |
| `SCHERMES_PORT`        | `7777`              | The one port schermes exposes. Must be 1–65535.               |
| `SCHERMES_DATA_DIR`    | `/var/lib/schermes` | Holds `schermes.db`, `master.key` and `desktops/`.            |
| `SCHERMES_GEOMETRY`    | `1920x1200`         | Desktop size. The model sees it shrunk to fit 1280x800.        |
| `SCHERMES_MAX_LOOPS`   | `8`                 | Concurrent agent turns. A request above it gets a 429.         |
| `SCHERMES_MAX_WORKERS` | `4`                 | Concurrent task workers, counted across all parents.           |
| `SCHERMES_APNS_KEY_FILE` | unset             | An APNs `.p8`, stored encrypted at boot like a pasted one. Empty or missing is no key. |
| `SCHERMES_APNS_KEY_ID` | from the file name  | The key id. Needed when the file is not named `AuthKey_<KEYID>.p8`; the daemon refuses to start without one. |

`SCHERMES_GEOMETRY` is the size `Xvnc` is started with. The model never sees it directly: a
screenshot is shrunk to fit 1280x800 (1920x1200 becomes exactly 1280x800), the computer tool's
coordinate bounds are that shrunk view, and the coordinates the model sends back are scaled onto
the display. A geometry at or below 1280x800 is used as is. Changing it restarts every desktop
still running at the old size the next time the daemon starts, rather than adopting it.

Set them in a `.env` next to `docker-compose.yml`, or in `infra/schermes.service` on a bare
host. The compose file passes `SCHERMES_PORT` through and publishes the same number, so changing
it in one place moves both. Five variables are the compose file's alone: `SCHERMES_BIND`, the
address the port is published on (`127.0.0.1` by default, `0.0.0.0` for LAN access without a
proxy), `SCHERMES_APNS_KEY`, the host path of the `AuthKey_<KEYID>.p8` that compose mounts at
`/run/secrets/apns.p8` (with `SCHERMES_APNS_KEY_ID` next to it, since the mount loses the name),
and for the `domain` profile `SCHERMES_DOMAIN`, `SCHERMES_HTTP_PORT` (80) and
`SCHERMES_HTTPS_PORT` (443).

Everything the daemon derives — the database path, the master key path, the migrations
directory, the desktop scripts — is resolved from `SCHERMES_DATA_DIR` or from
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

## Models

The model endpoint is not an environment variable. Models are a **registry**: rows in the
`models` table, written through the app's Models page or `/api/models`, one per endpoint the
owner wants to use.

| Field       | What it is                                                                    |
| ----------- | ----------------------------------------------------------------------------- |
| `name`      | What the owner calls it. Required.                                             |
| `baseUrl`   | The OpenAI-compatible endpoint, `http` or `https`. Required.                   |
| `model`     | The model id the endpoint expects. Required.                                   |
| `apiKey`    | AES-GCM encrypted with the master key, never returned and never logged — the listing answers `apiKeySet` as a boolean. |
| `extraBody` | An optional JSON object merged under every request: OpenRouter's `provider` routing block, `reasoning`, `max_tokens`. Anything that is not an object is a 400. |

Which entry runs is two settings and one column, none of them typed by hand; a fourth key is the
daemon's own:

| Setting / column          | Meaning                                                             |
| ------------------------- | ------------------------------------------------------------------- |
| `models.default`          | The id every agent without its own model uses. The first entry created becomes it. |
| `models.backup`           | Optional. The id a retrying turn may switch to (`POST /api/agents/:name/retry` `{action: "backup"}`). Never the model already running. |
| `agents.model_id`         | Per agent, set with `PUT /api/agents/:name/model` `{id}`; `null` means the default. A task worker always runs on its parent's. |
| `models.authFailed.<id>`  | Written by the daemon, not the owner: the endpoint answered 401 or 403. One Needs you item per model, cleared by a new key, a delete, a passing test or any call that answers. |

`POST /api/models/:id/test` makes one call against what is stored. A model is refused a delete
(409) while an agent is assigned to it, and the default is refused while another model exists to
take its place; deleting the backup just leaves none. An entry missing a base URL, a model or a
key is stored but not usable: a message to an agent on it is a 400, and its test says what is missing.

**Upgrading from the single provider.** Before the registry, the endpoint was four settings rows,
`provider.baseUrl`, `provider.model`, `provider.apiKey` and `provider.extraBody`. On boot,
`migrateProviderSettings` turns them into the first entry, makes it the default and deletes the
rows. The key moves as ciphertext. It runs once, and never over a registry that already has
entries (the old rows are then just dropped).

**`PUT /api/settings` still takes `baseUrl`, `model`, `apiKey` and `extraBody`**, and `GET` still
answers them with `apiKeySet`: they now read and write the default entry, creating one on the first
write. The app no longer uses them.

A consequence worth knowing: an empty string is a value. The daemon stores whatever it is
handed, so a write that includes `apiKey: ""` — on `/api/settings` or `PUT /api/models/:id` —
erases the stored key. The app omits the field entirely when it is untouched.

## Web search settings

`web_search` and `web_fetch` need no configuration to exist; `web_search` needs a key to run.
Both live in the same `settings` table and are written through the same `PUT /api/settings`.

| Field       | What it is                                                                    |
| ----------- | ----------------------------------------------------------------------------- |
| `searchUrl` | The search endpoint. Empty means the built-in `https://api.search.brave.com/res/v1/web/search`. It exists for a proxy or a mirror: the response parser is **Brave's shape** and a differently shaped API will not work. |
| `searchKey` | The Brave Search subscription token. AES-GCM encrypted with the master key, never returned — `GET /api/settings` answers with `searchKeySet` as a boolean, exactly like a model's key. |

Two consequences worth knowing.

**No key is a normal state.** A fresh install has none, and `web_search` answers with an
observation saying so rather than failing the turn. `web_fetch` needs no key and works either
way. Both fields are on the settings screen, and the key follows the model key's rule there:
blank means keep the stored one.

**`web_fetch` will not reach this machine.** Loopback, link-local, private, CGNAT, multicast and
reserved ranges are refused, before the request and again after the hostname resolves, and
redirects are not followed — a 3xx is reported so the agent can call again with the new URL.
There is no setting that turns this off. An agent that genuinely needs a local URL has
`run_command` and `curl`.

## Push notifications

Optional, stored on the same settings row set, read back under `push` in `GET /api/settings`.
Nothing has to be typed: the key comes in through `SCHERMES_APNS_KEY_FILE` at boot, and the
ids come in with the first device that registers. `PUT /api/settings` still takes every field,
for a setup where the file cannot be mounted or a build reports the wrong thing.

| Field          | Meaning                                                                       |
| -------------- | ----------------------------------------------------------------------------- |
| `pushKeyId`    | The APNs key id from the Apple developer account.                              |
| `pushTeamId`   | The team id.                                                                   |
| `pushBundleId` | The app's bundle identifier, `dev.schermes.Schermes` unless you changed it.    |
| `pushKey`      | The contents of the `.p8` file. AES-GCM encrypted with the master key, never returned — `GET` answers `keySet`. An empty string removes it. |
| `pushSandbox`  | `true` for a development-signed device build, which APNs serves from its sandbox host. |

Devices register themselves: `POST /api/devices` with `{token, platform}` on every launch,
plus the build's own `bundleId`, `teamId` and `environment` (`development` or `production`) as
read off its embedded provisioning profile, which become `pushBundleId`, `pushTeamId` and
`pushSandbox`. The last build to register decides the gateway. `GET /api/devices` lists them,
`DELETE /api/devices/:token` forgets one, and a token APNs reports dead is dropped by the push
that learnt it. `POST /api/settings/push/test` sends "Push works."
to every device. What is pushed, for permanent agents only: the end of a turn in an agent's own
thread with the owner (its reply, its questions, a hand-over, a form to fill, a browser that
stopped answering), why a turn failed there, and every approval request, wherever it was made.
The app needs a real Apple team and the `aps-environment` entitlement on a device build to be
handed a token at all.

**Actionable pushes need nothing extra.** When a push is about a Needs you item, it carries the
item's id (`needsYou`) and an `aps.category` the app registers buttons for:

| Category        | For                                        | Buttons                  |
| --------------- | ------------------------------------------ | ------------------------ |
| `needs.approval`| An action to approve                       | Approve / Don't          |
| `needs.delete`  | A deletion request                         | Keep it / Delete it      |
| `needs.yours`   | Something in Passwords and security        | I'll do it / Don't       |
| `needs.watch`   | A hand-over (`ask_for_hands`)              | Watch (opens the app)    |
| `needs.open`    | Anything else                              | Open (opens the app)     |

A button press answers through `POST /api/needs-you/:id/action` with the app's own stored login,
so it works without the app open — as long as the phone can reach the daemon's address at that
moment. When the answer does not land (unreachable, or the item went stale and answers 404) the
app posts a local notification saying so.

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
values — the model key's rule. So on `PUT /api/mcp/servers/<name>` an `env` or `headers` entry
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
| `IDLE_TIMEOUT_MS`         | 120 s              | `daemon/src/provider.ts`  | Silence between bytes of one model call; retried like 429, 5xx and network errors |
| `MAX_ATTEMPTS`            | 5                  | `daemon/src/provider.ts`  | Calls for one model request, waiting 2 s·2ⁿ or the endpoint's `Retry-After` between them; 401/403 is never retried |
| Terminal timeout          | 120 s, max 600 s   | `daemon/src/terminal.ts`  | One command, unless the caller asks for less      |
| `MAX_TYPE_CHARS`          | 2 000              | `daemon/src/computer.ts`  | One `type` action                                 |
| `MAX_CLIPBOARD_CHARS`     | 64 KiB             | `daemon/src/computer.ts`  | A clipboard write                                 |
| `MAX_DISPLAY`             | 999                | `daemon/src/agents.ts`    | Highest X display, so 999 permanent agents        |
| `MAX_LABEL_CHARS`         | 64                 | `daemon/src/agents.ts`    | An agent's label, on one line; a client's `look` token follows the same rule |
| `MAX_PROFILE_CHARS`       | 4 000              | `daemon/src/interview.ts` | An agent's profile, written by `set_profile` or `PATCH /api/agents/:name` |
| `MAX_QUESTIONS`           | 4                  | `daemon/src/interview.ts` | Questions one `ask_owner` call may put to the owner |
| `MAX_FILE_BYTES`          | 25 000 000         | `daemon/src/home.ts`      | One file handed to an agent through `POST /api/agents/:name/uploads`, or taken out through `GET .../files` |
| `MAX_EVENTS`              | 1 000              | `daemon/src/app.ts`       | The most `?limit=` may ask `GET .../events` for   |
| `MAX_SEARCH_HITS`         | 50                 | `conversations.ts`        | Rows one search answers with, newest first, each cut to a 240-character snippet |
| `MAX_MEMORY_FILE_CHARS`   | 64 000             | `daemon/src/home.ts`      | A memory file as the owner reads or writes it through `/api/agents/:name/memory` |
| `APNS_TOKEN_TTL_MS`       | 50 min             | `daemon/src/push.ts`      | How long one provider JWT is reused; APNs refuses one older than an hour |
| `MAX_PUSH_BODY_CHARS`     | 200                | `daemon/src/push.ts`      | The body of a push; the thread has the rest       |
| `MAX_IMAGE_BYTES`         | 5 000 000          | `daemon/src/app.ts`       | A picture the owner sends with a message, decoded |
| `MAX_TRIGGERS`            | 20                 | `daemon/src/triggers.ts`  | Triggers one agent may hold                       |
| `MAX_HOOK_BYTES`          | 64 KiB             | `daemon/src/triggers.ts`  | One webhook body; more is a 413                   |
| `MAX_HELPERS`             | 6                  | `daemon/src/goals.ts`     | Helpers one goal may add                          |
| `MAX_QUESTION_CHARS`      | 300                | `daemon/src/search.ts`    | One `POST /api/search` question                   |
| `INDEX_EVERY_MS`          | 10 min             | `daemon/src/search.ts`    | How often files and pictures are indexed           |

Agent names match `^[a-z0-9][a-z0-9-]{0,30}$`. The name becomes the Linux user `agent-<name>`,
so it is validated at every boundary that accepts one.

A name is the system identity. What the owner is shown is the agent's `label`: free text, any
script, up to `MAX_LABEL_CHARS` on one line, and purely cosmetic — nothing addresses, routes,
runs as or names a file after a label, and the app derives the name from it when an agent is
created (`Bob the Builder` runs as `agent-bob-the-builder`). `PATCH /api/agents/:name` changes a
label, a look or a profile in the row alone. A `name` in the same request moves the agent: its
desktop is stopped, `rename-agent-user.sh` moves the Linux user and its home (`usermod
--move-home`), every `sender` and approval target spelling the old name is rewritten, and the
desktop starts again under the new one. It is refused while the agent is in a turn (409), for a
name another agent holds (409), and when a deleted agent's user still occupies the new name
(500, from the script). An agent renames itself with `set_name`; the move waits for its turn to
end, because the turn is running as the old user. Its task workers keep the names they were born
with.

An agent's `profile` is what it is for, in Markdown, in its system prompt every turn. A new
agent has none and interviews the owner with `ask_owner` to write one with `set_profile`;
`POST /api/agents` starts that interview when the new agent has a usable model, and a body
carrying a `profile` skips it. A body carrying a `description` instead (what the app's "New agent"
sends, after `POST /api/agents/suggest` has proposed a name, rules and routine from it) starts a
first turn that writes the profile from the description. A blank profile on `PATCH` clears it, which puts the agent back to asking.

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

## Search and OCR

`POST /api/search` needs no setup of its own: it asks the **default model** to turn the question
into filters, and without one (or when the call fails) it falls back to plain word search. The
index is rebuilt by the daemon every 10 minutes: agents' home files by name and path, and the
text in stored screenshots and pictures.

That text comes from **`tesseract`**, which `infra/install.sh` installs as `tesseract-ocr` (with
English data only, Debian's default). The indexer checks `command -v tesseract` on every pass; when
it is missing, OCR is skipped entirely and nothing is marked as read, so installing it later picks
up every old picture. A few pictures are read per pass, newest first.

## Triggers and the webhook URL

A trigger is a row an agent proposes with `propose_trigger` and the owner turns on in the app;
nothing about it is a setting. Four kinds: `folder` and `command` are polled as the agent,
`imap` logs in to a mailbox with a login the owner types into a Needs you form (stored encrypted,
never shown to the agent), and `webhook` waits for another service to call the daemon.

A webhook is minted when the owner first turns it on: a random token and secret (24 random bytes
each; the secret stored encrypted), kept for the life of the trigger and shown in the app. The sender calls

```
POST /hooks/<token>
X-Schermes-Secret: <secret>
```

with any body up to 64 KB, which reaches the agent as data, never as instructions. It is outside
`/api`, so it needs no session. Answers: 202 fired, 401 wrong or missing secret, 404 unknown or not
on, 413 too big, 429 over the trigger's hourly cap (counted as dropped).

Three consequences worth knowing.

**The sender has to reach the daemon.** The app shows the hook URL on the daemon address the app
itself is connected to. A LAN address or `127.0.0.1` behind a tunnel works for a sender on the
same network and for nothing else; a service on the internet needs a public address, which in
practice is the `domain` profile's Caddy or another reverse proxy in front of the port. Caddy
forwards every path, `/hooks/*` included.

**The secret travels in a header, so use HTTPS for a real sender.** Over plain HTTP anyone on the
path can read it and fire the trigger.

**The rate cap is the agent's to propose**: `maxPerHour` defaults to 6 and may not exceed 60. A
folder or command check runs every `everyMinutes` (default 5, at most 1 440), on the schedules'
30-second tick.

## Per-agent settings in the app

A few things are configured per agent, from the agent's pages in the app, and live on the agent's
row rather than in `settings`. What they do at runtime is in [architecture](architecture.md).

| What                | Route                                | Default                                    |
| ------------------- | ------------------------------------ | ------------------------------------------ |
| Model               | `PUT /api/agents/:name/model`        | The registry's default                     |
| Rules               | `GET`/`PUT /api/agents/:name/rules`  | Browse, run commands, write files: on its own. Send messages: if pre-approved. Delete, spend, install, share outside: ask first. Passwords and security: always "Hand to you", not changeable |
| When idle           | `GET`/`PUT /api/agents/:name/idle`   | Off; 01:00–06:00 daemon local time, 200 000 tokens a day, 20 model calls a turn, the agent's own model |
| Routines and triggers | `/api/agents/:name/schedules`, `/api/agents/:name/triggers`, `POST /api/triggers/:id` | None |

Task workers have none of these: they run on their parent's model and under its rules. Idle work
pauses itself after the owner dismisses its notes three times in a row; turning it back on clears
the pause.

## TLS

There is none in the daemon, on purpose. schermes speaks plain HTTP on one port; the compose
file's `domain` profile puts Caddy in front of it — see
[deployment](deployment.md#a-linked-domain). The session cookie is deliberately not `Secure`,
because a `Secure` cookie is dropped over the plain HTTP the daemon actually speaks.

Nothing in the daemon refuses plain HTTP, but some features carry secrets from the app to it, and
past a trusted LAN they need TLS in front — Caddy from the `domain` profile, or the proxy of a
platform such as Coolify:

- **Form fields.** Filling an agent's `request_form` sends what the owner typed, passwords included,
  in the request body; a mailbox login for an `imap` trigger goes the same way. (The daemon's own
  HTTPS rule is about the *page* being filled: a secret field on a page that is neither HTTPS nor
  loopback is never filled, whatever the daemon runs behind.)
- **Webhook secrets**, in the `X-Schermes-Secret` header, from whatever service sends them.
- **The owner password** at every login, and the session cookie on every request after it.
