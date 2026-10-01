# Development guide

schermes provisions a whole Linux machine, so most of it cannot be exercised on a Mac directly.
The Docker harness exists to close that gap: the container is a real Debian 13 host built by
`infra/install.sh`, running real Xvnc displays, real Chromium profiles and real `sudo`
boundaries. It is also the deployment: the same compose file runs on the server.

## Layout

A pnpm workspace with two packages, plus the native app in `apple/`, which is Swift and
outside the workspace.

| Package             | What it is                                                     |
| ------------------- | -------------------------------------------------------------- |
| `daemon` (`daemon/`) | The service: HTTP, auth, secrets, agents, tools, loop, storage |
| `shared` (`shared/`) | The types both ends of the API agree on                        |

The daemon has **no build step**. Node 24 strips TypeScript types on load, so it runs from
source and `tsc` only type-checks. Never introduce a `dist/` for it. It serves no static files:
the exposed port is the API, and the client is the app in `apple/`.

## On the Mac

```sh
pnpm install
pnpm check   # TypeScript, strict, every package
pnpm test    # unit tests, no framework — node --test
```

Only the daemon has tests: `node --test src/*.test.ts`. `shared` is types, so it is only
type-checked. There is no framework, no fixtures directory and no runner config. Unit tests use a
scripted provider and an in-memory SQLite database migrated from `daemon/migrations`; anything
needing a display, a Linux user or a real `sudo` belongs in the harness instead.

### The daemon's tests

| File                 | What it covers                                                                  |
| -------------------- | ------------------------------------------------------------------------------- |
| `api.test.ts`        | The HTTP routes through `createApp`, and every flow built on them (by far the largest) |
| `loop.test.ts`       | The turn state machine, tool dispatch, transcripts, workers, the runner         |
| `tools.test.ts`      | The `computer` and terminal tools: validation and the exact argv they run       |
| `browser.test.ts`    | The CDP browser tool, its validation and its hung-browser watchdog              |
| `forms.test.ts`      | Reading, shaping and filling a web form against the fake page in `testpage.ts`  |
| `recording.test.ts`  | "Show the agent how": the RFB input tap and the steps it becomes                |
| `provider.test.ts`   | The OpenAI-compatible client: streaming, errors, retries                        |
| `push.test.ts`       | APNs tokens, push and Live Activity payloads                                    |
| `agents.test.ts`     | Agent names, display allocation, desktop adoption on restart                    |
| `db.test.ts`         | Migrations over a populated database, and foreign keys staying enforced         |
| `vnc.test.ts`        | The VNC WebSocket proxy's auth and byte relay                                   |
| `mcp.test.ts`, `web.test.ts`, `secrets.test.ts`, `log.test.ts` | MCP server config, web search/fetch, encryption, log redaction |

The seams are dependency parameters, not mocks:

- **`fixture()` in `api.test.ts`** builds an app around a fake `exec` and a scripted provider and
  hands back what a test asserts on: `ran` (every argv, in order) with `stdin` at the same index,
  `requests` (every model request, serialized) with `offered` (the tool names each one offered),
  `replies` (the script the provider answers from), `spawned`/`stopped`/`moved` (desktop calls),
  `memory` (per-user `MEMORY.md`), `hold()` to park a turn and `settled(name)` to wait for one.
  `intercept(handler)` answers exec calls before the default does, which is how a test fakes
  one script's output (`fakeSnapshots` is built on it).
- **`AppDeps`** takes `makeProvider`, `connect` (how the browser and form fills reach Chromium;
  tests pass `formPage` from `testpage.ts`), `pushSend` (captures pushes instead of calling APNs),
  and the smaller caps `maxLoops`, `retryBaseMs` and `activityThrottleMs`.
- **`LoopDeps`/`RunnerDeps`** take the same `connect` plus `browserTimings` (short watchdog
  timeouts), `desktop` (without it `add_helper` is refused) and `provider`.

### The Swift tests

One target, `SchermesTests`, for both platforms. Swift Testing, as free `@Test` functions in no
suite, so `-only-testing:SchermesTests/<File>` matches nothing and "passes" with zero tests: run
the whole target and grep the log for the names you care about.

| File                          | What it covers                                                 |
| ----------------------------- | -------------------------------------------------------------- |
| `TypesTests`                  | Decoding and encoding every wire type against literal JSON     |
| `ThreadTests`                 | Transcript folding: pending questions, merges, chat rows        |
| `BloubTests` + `BloubGoldens` | The avatar engine against pinned goldens                       |
| `ThemeTests`                  | `AgentPalette` against the canvas's colour check               |
| `SettingsTests`               | Settings pages send only their own fields                      |
| `RfbTests`, `ControlTests`    | The VNC client (handshake, rects, ZRLE) and keyboard ownership |
| `MarkdownTests`, `ReadableTests`, `CommandsTests`, `ImagesTests` | Rendering helpers, readable crons and events, the slash palette, image scaling |
| `AgentActivityTests`, `ShareTests`, `QuickMessageTests` | Live Activity payloads, share messages, the menu bar's quick field |

```sh
cd apple
xcodegen generate   # after adding or removing any Swift file
xcodebuild test -scheme Schermes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$TMPDIR/schermes-dd"
xcodebuild test -scheme Schermes -destination 'platform=macOS' -derivedDataPath "$TMPDIR/schermes-dd"
```

Run on the simulator first: it takes no focus. The macOS run launches the app as the test host,
so do it once, at the end. A custom `-derivedDataPath` keeps the build out of
`~/Library/Developer/Xcode/DerivedData`, where it is easy to install a stale app from. Other
agents may be editing the checkout at the same time: a failure in a file you did not touch is
worth a `git status` before it is worth a fix.

## A daemon without Docker

The daemon runs on macOS directly, which is enough for the app and for every route that does not
reach a Linux user. `SCHERMES_DATA_DIR` holds `schermes.db` and `master.key` and is created on
boot; `SCHERMES_PORT` defaults to 7777. Pick a free port first
(`lsof -iTCP:<port> -sTCP:LISTEN`): other sessions' daemons may hold one.

```sh
cd daemon
SCHERMES_PORT=7796 SCHERMES_DATA_DIR="$TMPDIR/bed" node src/main.ts
```

Boot logs `desktop unavailable` for every agent, since there is no Xvnc, and carries on. Agent
creation fails (no `useradd`), so seed rows with the daemon's own helpers instead. A script
anywhere can import them by absolute path:

```ts
import { openDb } from '<repo>/daemon/src/db.ts';
import { insertAgent } from '<repo>/daemon/src/agents.ts';
import { appendMessage, conversationFor } from '<repo>/daemon/src/conversations.ts';

const db = openDb(`${process.argv[2]}/schermes.db`, '<repo>/daemon/migrations');
const mo = insertAgent(db, 'mo', { label: 'Mo' })!;
appendMessage(db, conversationFor(db, mo.id), { role: 'user', content: 'Hello' });
```

Set states and other columns with `sqlite3` on the same file.

**Real agent turns** need what the daemon expects of a Debian host, first on the daemon's `PATH`
(it spawns with the inherited environment). Every agent-side command is
`sudo -n -u agent-<name> env --chdir=<dir> HOME=… <argv>` and every home is looked up with
`getent passwd agent-<name>`, so:

- a `sudo` shim that drops `-n -u <user>`, turns `env --chdir=<dir>` into a `cd`, and execs the rest;
- a `getent` shim printing a passwd line whose home is a scratch directory per agent (zsh's
  `getent` is a shell function, which a spawned process never sees);
- GNU `timeout` for `run_command`, and GNU `stat -c` and `base64 -w0` for the routes that read
  agent files (`brew install coreutils` puts them in with a `g` prefix, so shim the plain names).

Snapshots, the search indexer and triggers also shell out to GNU `find`/`sed`/`tar`; they log
their failures and the turn goes on.

### The provider stub

`infra/provider-stub.py PORT NONCE COMMAND` is a scripted OpenAI-compatible endpoint on
`127.0.0.1`, answering `POST …/chat/completions`. Add it as a model with `baseUrl`
`http://127.0.0.1:<PORT>` and any model name. It counts calls per agent (read from the system
prompt's "You are <name>,") and follows `STUB_SCRIPT`:

| `STUB_SCRIPT` | What the agent does                                                          |
| ------------- | ---------------------------------------------------------------------------- |
| `tools`       | Default. Screenshot, then `run_command COMMAND`, then report                 |
| `busy`        | `run_command COMMAND` once, then report. `sleep 40` parks a turn, for stop   |
| `talk`        | `STUB_SENDER` sends one message to `STUB_TO`                                 |
| `worker`      | `STUB_SENDER` spawns a task worker, which runs `COMMAND`                     |
| `memory`      | `STUB_SENDER` remembers the nonce                                            |
| `web`         | `STUB_SENDER` calls `web_fetch` on `STUB_URL`                                |
| `interview`   | `STUB_SENDER` asks two questions, then writes a profile with the nonce       |
| `guarded`     | `STUB_SENDER` runs `COMMAND`, asks with `request_approval`, proposes a webhook |

Anyone else reports at once. The report is one line of `key=value` pairs (nonce, heard senders,
tools offered, calls made, images, whether the transcript was well formed, and what reached the
system prompt: memory, skills, schedules). `STUB_CMD_TIMEOUT_MS` sets the command's timeout.

An API key of the form `status-NNN` makes every call answer HTTP NNN (a 429 with
`Retry-After: 20`), which drives the retry, backup and bad-key paths. The call counter lives in
the process: restart the stub to reset it.

## Driving the app

Debug builds read these launch arguments (`-key value`, the `NSUserDefaults` argument domain):

| Argument                         | Effect                                                              |
| -------------------------------- | ------------------------------------------------------------------- |
| `-schermes.serverAddress <addr>` | The daemon to use. Passed at launch, it is never written back, so a copy sharing the bundle id keeps its own |
| `-schermes.debugPassword <pw>`   | Logs in with it: no typing, no Keychain read                        |
| `-schermes.debugOpen <target>`   | Opens one screen once, after the first agent list loads             |
| `-schermes.settingsTab <tab>`    | The settings page `debugOpen settings` shows: `model`, `web`, `notifications`, `plugins`, `daemon`, `about` |
| `-schermes.debugActivity YES`    | iOS only: starts a local Live Activity, since no push reaches a simulator |

`debugOpen` targets: `needs-you`, `agent:<name>`, `goal:<id>`, `search:<question>`,
`settings`, and `pages:<name>:<page>` where the page is the raw title: `Profile`, `Rules`,
`When idle`, `Routines and triggers`, `Activity` or `Memory`. An unknown target shows as the
console's error line. On a Mac, `settings` opens the page as a sheet, because the Settings
window can bring the app to the front. `serverAddress` and `settingsTab` are ordinary defaults
keys, read in release builds too; the other three exist only in Debug.

The iPhone 17 Pro simulator reaches a bed daemon at `127.0.0.1:<port>`.

## Migrations

`pnpm migrations` runs `drizzle-kit generate` against `daemon/src/schema.ts`. Never write one by
hand, and commit the SQL together with `migrations/meta`. SQL drizzle cannot express, such as
FTS5 tables and their triggers, goes in a custom migration:
`pnpm --filter @schermes/daemon exec drizzle-kit generate --custom --name <name>` writes an empty
file into the journal for you to fill (`0024_search_index.sql` is one). Separate statements with
`--> statement-breakpoint`.

Boot-check every new migration on a fresh data dir and on a copy of an existing one, each on a
spare port, never the port a running bed or app uses:

```sh
cd daemon
SCHERMES_PORT=7797 SCHERMES_DATA_DIR="$TMPDIR/fresh" node src/main.ts
mkdir -p "$TMPDIR/upgrade"
sqlite3 <old>/schermes.db ".backup $TMPDIR/upgrade/schermes.db" && cp <old>/master.key "$TMPDIR/upgrade/"
SCHERMES_PORT=7798 SCHERMES_DATA_DIR="$TMPDIR/upgrade" node src/main.ts
curl -s 127.0.0.1:7798/api/health
```

`openDb` refuses to start if the migrations leave a dangling foreign key, so a boot that logs
`daemon listening` has passed that check. `db.test.ts` covers the same ground for the rows it seeds.

## The Docker harness

```sh
docker compose build
docker compose up -d
```

Then the two runnable checks. Both are safe to run repeatedly, including after
`docker compose restart` and `docker compose up --build`, because `/var/lib/schermes` and `/home` are
named volumes and they reuse the owner and the agents they find.

```sh
./infra/smoke.sh                                                  # the daemon
docker compose exec schermes /opt/schermes/infra/desktop/check.sh # the desktops
```

`smoke.sh` walks the API end to end: first-run password, the second setup attempt being refused,
an unauthenticated request rejected, login, the settings round-trip with the key going in but
never coming back. Then two agents with their own loopback-only VNC displays, surviving a
container restart, adopted rather than respawned by a second daemon, and respawned when a
desktop is killed underneath. Then the tools: screenshots that differ after an xterm opens,
keystrokes that create a file, a clipboard round-trip, a non-zero exit code, a command killed at
its timeout, `apt-get install`. Then the loop against a scripted provider on loopback, the
event log, and the whole exchange surviving `docker compose up --build --force-recreate`. Then
messaging, task workers, caps, takeover, and a daemon killed mid tool call. Then search, a delete
refused by the rules, an approval answered from Needs you, and a webhook trigger firing a turn.
The model registry and the rules routes run without the harness too.

`check.sh` creates three agents on displays `:101`–`:103`, gives each a Chromium profile, types
a URL into each browser, screenshots every desktop, proves a cookie survives a Chromium restart,
and asserts the web port is the only socket bound outside loopback.

Point the app at `http://127.0.0.1:7777` and set the owner password on first launch. See
[../apple/README.md](../apple/README.md) for building it.

## Working on a client

Clients poll. There is no WebSocket event stream; the only WebSocket is the VNC proxy. The
intervals the app uses are fixed: 2s for the agent list and the open thread, 4s for control
state and events, 5s for the conversation list.

## Things that bite

- **Editing `infra/install.sh` invalidates the Docker base layer** and costs a full apt cycle
  and Node download. Budget the disk and the time before you touch it.
- **`docker compose restart` cannot demonstrate restart recovery.** It destroys the container's
  pid namespace, so detached desktops die with it. Only a second daemon against the same
  database reaches the adopt path, which is what `smoke.sh` does.
- **Never put a `PRAGMA foreign_keys` line in a migration file** — drizzle wraps each one in a
  transaction, where that pragma is a no-op. `openDb` turns them off around the whole run
  instead. See [Migrations](#migrations).
- **Anything that detaches must drop the daemon's stdout pipe**, or the request hangs: `close`
  fires on stdio EOF, not on exit. Use the terminal tool's `background` option, or an `exec`
  redirect *inside* the shell.
- **All shell access goes through `daemon/src/exec.ts`**, which modules above take as a
  parameter. That is what lets tests assert the exact argv, and it is why the tools are not
  hidden behind a capability-level fake.

More of these, with the symptoms attached, in [troubleshooting](troubleshooting.md). The
reasoning behind the design is in [architecture](architecture.md).

## Before you hand off

`pnpm check` and `pnpm test` clean, the Swift target green on the simulator and the Mac if
`apple/` changed, `./infra/smoke.sh` exiting 0 twice in a row, and `check.sh`
exiting 0. Twice in a row matters: several bugs in this codebase only appear on the second run,
because the first leaves state the second has to cope with.
