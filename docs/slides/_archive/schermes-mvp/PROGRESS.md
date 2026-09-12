# Progress — schermes-mvp

## Current state
The desktop foundation, the daemon spine, the agent lifecycle, the tool layer, the agent loop,
restart recovery and agent-to-agent messaging are committed. Creating an agent through the API
creates its Linux user, home layout and Xvnc desktop; the daemon adopts live desktops on restart.
Through the API you can screenshot an agent's desktop, drive its mouse and keyboard, use its
clipboard and run shell commands as it. Posting a message to an agent reaches an
OpenAI-compatible model, which calls those same tools and sees the screenshots it asks for; the
transcript, the agent's state and the execution events survive a restart. A daemon killed mid
tool call comes back, answers the interrupted call, and leaves the agent answerable. Agents now
hold conversations: one can write to another with `send_message`, a group thread fans one owner
message out to every agent in it, every message names who wrote it, and a message to a busy agent
is taken rather than refused. An agent can hand a self-contained job to a task worker that runs
as it and reports back, and both loops and workers are capped. The owner can watch an agent's
desktop over a VNC WebSocket proxy on the one exposed port and take its input away, which the
agent reads as a refusal. `/var/lib/schermes` is a volume, so the database, the master key and
the encrypted settings survive `docker compose up --build`; threads read back a page at a time
and the transcript sent to the model carries a bounded number of screenshots. A React UI on the
same port logs the owner in, stores the provider settings, creates agents, reads threads with
their screenshots inline, streams the desktops over noVNC and takes control of them.
`infra/packer/` holds a QEMU template that turns a commit of this repository into a qcow2 for
Unraid, and the eleven documents the Scope names all exist and have been audited against source.

**The product is feature-complete.** What is left is exactly the two `[user-gated]` items: one
end-to-end run against a real OpenAI-compatible endpoint, and the deployment on the Unraid VM.
Everything above has only ever been exercised against `infra/provider-stub.py`.

**`HEAD` is at slice 5 and slices 6–11 are uncommitted** — `loop.ts`, `conversations.ts`,
`provider.ts`, `control.ts`, `vnc.ts`, `workers.ts`, three migrations and the whole `ui/` tree
are untracked. `git archive HEAD` therefore has no UI and no agent loop, so an image built from
`HEAD` today would not contain the product. The Packer template guards against this and fails in
seconds rather than fifteen minutes in, but the underlying gap is a commit nobody has made.

**Invariants future slices must respect**
- `infra/install.sh` is the single provisioning path. The Docker harness and a real VM run the
  same script. It must stay idempotent — re-running it is the upgrade path.
- The daemon runs as the unprivileged system user `schermes`. Its only root powers are
  `create-agent-user.sh` and `apt-get`; it becomes agent users via `sudo -u agent-<name>`,
  authorised by the `%agents` runas rule. Do not widen this without recording why.
- Agent users are `agent-<name>` where name matches `^[a-z0-9][a-z0-9-]{0,30}$`. Validate at
  every boundary that accepts a name.
- One `Xvnc` per agent, VNC on `5900 + display`, loopback only, spawned detached with `setsid`.
  Desktops outlive the daemon. `start-desktop.sh` prints `adopted` or `started` and the daemon
  reads that word rather than probing itself. No per-agent systemd units.
- **Display ranges are partitioned.** The daemon allocates from `:1` up; `check.sh` owns
  `:101`-`:103`. A new script that spawns desktops needs its own range.
- **`docker compose restart` cannot demonstrate adoption**: it destroys the container's pid
  namespace. Only a second daemon against the same database reaches the adopt path.
- Every command run as an agent carries `HOME`, `USER`, `LOGNAME`, `DISPLAY` and `XAUTHORITY`
  explicitly — `sudo` strips them — and `env --chdir` before them. `daemon/src/agents.ts`'s
  `asAgent()` is the one place that assembles this; do not hand-roll a second one.
- **Anything that detaches must drop the daemon's stdout pipe.** `close` fires on stdio EOF, not
  on exit, so a child holding the pipe hangs the request. Detach through the terminal tool's
  `background` option, or use an `exec` redirect inside the shell — a redirect on the *command*
  leaves the shell itself holding the pipe. This bit `xclip` and the background command.
- **A tool result and its image are two messages.** An assistant message carrying `tool_calls`
  must be followed immediately by one `tool` message per call id and nothing else, so a
  screenshot rides in a separate `user` message emitted *after* every tool result of that turn.
  `transcript()` in `loop.ts` is the one place this ordering lives.
- **Tool schemas live beside the validator they describe**, built from the same constants, in
  `computer.ts` and `terminal.ts`. A separate schema file would be a second copy of the
  vocabulary and would drift; two tests assert the advertised bounds are the bounds the parser
  enforces.
- **`failed` is reachable from every state** in `TRANSITIONS`, so the catch that ends a broken
  turn never bypasses the table, and both terminal states lead back to `thinking`. Losing
  `waiting_for_user -> thinking` or `failed -> thinking` makes `smoke.sh` pass once and fail on
  the re-run.
- **Events carry no payloads and no secrets**: a screenshot event records `imageBytes`, never
  pixels; a provider error body has the api key stripped in `openAiProvider` before it can reach
  a failure event or the log, because `redact` matches field names and never values.
- **The one-turn-per-agent set is process-local**, not a row. It lives in the runner
  (`createRunner` in `loop.ts`), which both the HTTP routes and `send_message` inside a turn go
  through — it cannot move back into a route closure. A restart forgets it entirely, which is
  safe because `reconcileAgents()` puts every agent the dead daemon was mid-turn on into
  `waiting_for_user` before the server listens.
- **A conversation is its participant set**, looked up find-or-create. One agent is that agent's
  own thread, two is the thread those two share, more is a group; the owner is in every one and
  is never listed as a participant. A group of exactly two *is* the direct thread between them.
- **Every message carries its sender**, an agent name, and an absent sender means the owner.
  Names, not agent ids: they are unique, immutable, and the transcript needs the name anyway.
- **The transcript is a per-agent projection of a shared conversation.** What the agent wrote is
  replayed verbatim; everything else becomes a `user` message reading `Message from <who>:`, and
  another agent's tool traffic is dropped *along with the tool calls that asked for it* — half an
  assistant/tool pair is a transcript a strict endpoint rejects.
- **Anything the agent did not write is buffered until the transcript is between turns**, exactly
  like a screenshot. Delivery to a busy agent stores a foreign row at any point of a turn and it
  stays there, so on a later read it would otherwise sit inside an assistant/tool pair.
- **A message is never refused.** There is no 409 left anywhere: nothing would retry it, because
  the sender may be another agent inside a turn. The message rows are the queue, and in the
  runner's drain the pending check and the release of the busy flag are **one synchronous
  block** — an `await` between them opens a window where a message lands, finds the agent busy,
  and is never picked up by anyone.
- **An answer wakes only an agent standing in `waiting_for_agent`.** An answer is addressed to
  nobody; without this rule two agents in a group would answer each other forever off one owner
  message. Only `user` rows wake an agent unconditionally.
- **Two agents cannot write to each other forever.** `agentChain()` counts the messages agents
  passed since the owner last spoke *in that conversation* and `send_message` refuses past
  `MAX_AGENT_CHAIN`. It is a query over the rows, not a counter threaded through the loop.
- **An unanswered tool call is a broken transcript, not a cosmetic gap.** A strict
  OpenAI-compatible endpoint rejects the whole request until every `tool_calls` id has a `tool`
  message. `repairInterruptedCalls()` in `conversations.ts` is the one place that closes them,
  and it runs in the persistence layer so the *stored* history becomes valid — `transcript()`
  must never paper over a gap instead.
- **Boot repair runs before the HTTP server listens.** `reconcileAgents(db)` in `main.ts` sits
  above `serve()`, unlike `reconcileDesktops()`, which runs after. Nothing may read `agents.state`
  or a conversation before it. Every per-agent failure is caught and logged: a throw there would
  stop the daemon booting at all, which is worse than one stuck row.
- **A repaired agent waits for its owner; it does not resume by itself.** A turn that killed the
  daemon would otherwise be re-run on every boot. Reversing this needs a reason recorded here.
- **Boot also rescues an agent stranded in `waiting_for_agent`.** The reply it waits for only
  ever wakes it from inside a live turn, so an answer written before the daemon died would never
  reach it; boot moves such an agent to `waiting_for_user`. An agent whose reply genuinely has
  not been written yet is left where it stands, because that state is what lets the answer wake
  it later.
- **`redact()` has no `Buffer` branch**, so an exec result passed to `log` explodes into per-byte
  JSON. Routes log the exit code and the action name, never the result. Nothing enforces this.
- **All shell access goes through `daemon/src/exec.ts`.** Modules above it take it as a
  parameter, which is what lets tests assert the exact argv. Tools are deliberately *not* behind
  a `ComputerOps`-style object: a capability-level fake would hide the argv.
- **Foreign keys are off across the migrations and on for everything after**, decided once in
  `openDb`. That is step 1 of SQLite's table-recreate procedure and it has to happen *outside*
  the transaction drizzle wraps each migration in, where `PRAGMA foreign_keys` is a no-op. Never
  put a `PRAGMA foreign_keys` line in a migration file: it does nothing. `foreign_key_check`
  runs after the migrations and **throws**, so a referentially broken database refuses to boot
  rather than accumulating more rows.
- **`/var/lib/schermes` is a named volume in `docker-compose.yml`.** The database, `master.key`
  and the desktop state directory live there and survive `docker compose up --build`. Named, not
  bound: a fresh named volume is seeded from the image with its ownership and modes, so
  `master.key` stays 0600 under `schermes`. Agent home directories are deliberately outside it —
  a recreated container rebuilds the Linux users and desktops from the surviving agent rows, via
  `reconcileDesktops` and the idempotent `create-agent-user.sh`.
- **Paging is a reader's view and lives in `pageMessages`, never in `listMessages`.** Every
  in-daemon caller — the turn's `since` high-water mark, `transcript()`, `repairInterruptedCalls`
  and `agentChain` — is wrong on a truncated history, and a page boundary between an assistant
  message and its tool results is the exact shape a strict endpoint rejects. Giving
  `listMessages` a default limit would ship that bug silently.
- **The transcript carries at most `MAX_REPLAYED_IMAGES` screenshots.** Older ones become text
  saying they are no longer visible; the tool result naming each one is never dropped, or the
  agent loses the record that the call happened.
- **No build step.** Node 24 strips types on load; the container runs `daemon/src/main.ts` from
  source. Never introduce `dist/`. Paths resolve from `import.meta.dirname`.
- The auth guard is registered before any route and denies by default.
- Only the web port may bind off loopback. `check.sh` compares the full `address:port`.
- The pinned pnpm version moves together in `package.json`, `install.sh` and `pnpm-lock.yaml`.
- `docker compose exec schermes /opt/schermes/infra/desktop/check.sh` and `./infra/smoke.sh`
  must both keep exiting 0, and both must stay re-runnable.

**Key files**
```
daemon/src/{main,app,auth,agents,secrets,settings,db,schema,config,log}.ts   the service
daemon/src/{exec,computer,terminal}.ts   the tool layer: spawn boundary, desktop, shell
daemon/src/{provider,loop,conversations}.ts   the model seam, the turn, the transcript store
daemon/src/{workers,control,vnc}.ts  task workers, the input hold, the desktop proxy
daemon/migrations/                   Drizzle migrations, committed, applied on boot
shared/src/index.ts                  API contract types
ui/src/                              React + Vite, built to static files the daemon serves
infra/install.sh                     provisioning: packages, node 24, uv, users, sudoers, unit, ui
infra/smoke.sh                       runnable check: API, lifecycle, tools, loop, messaging, repair
infra/provider-stub.py               scripted OpenAI-compatible endpoint, scripted per agent
infra/desktop/*.sh                   per-agent user creation, desktop spawn/adopt, check.sh
infra/packer/schermes.pkr.hcl        QEMU template: Debian cloud image -> qcow2 for Unraid
docs/README.md                       the docs index, and where each Scope subject lives
docs/architecture.md                 decisions, tagged requirement / recommendation / deferred
docs/{development,deployment,image-build,configuration,troubleshooting}.md
```

**Gotchas already paid for** — see `docs/architecture.md`: Chromium's `SIGTERM` path does not
flush pending cookie writes, and only the browser process should be signalled; Docker's DNS
resolver listens on `127.0.0.11`, which is loopback; scrypt above N=16384 exceeds Node's default
32 MiB `maxmem`; a `Secure` session cookie would be dropped over the plain HTTP schermes speaks;
a killed X server leaves `/tmp/.X<n>-lock` behind; `ss -p` shows no pids in this container
because Docker does not grant `CAP_SYS_PTRACE`; `scrot -` opens `/dev/stdout` **by path**, which
an agent user cannot do across a uid change, so captures land in the agent's home and are
`cat`'d back; a bare Openbox desktop screenshots to roughly 3 KB, so any size floor above ~4100
base64 characters is a false failure.

## Slice 1: desktop foundation
- Shipped: `infra/install.sh` provisions Debian 13 (X11/Xvnc, Openbox, Chromium, xdotool,
  scrot, xclip, Node 24, pnpm, uv, python3, dev tooling), creates the `schermes` service user,
  the `agents` group, `/srv/schermes/shared` and the sudoers rules. `create-agent-user.sh` and
  `start-desktop.sh` build and run per-agent desktops. `check.sh` proves three agents run
  concurrent desktops with their own Chromium profiles, driven by xdotool, captured by scrot,
  with a cookie surviving a browser restart and nothing listening off loopback. Dockerfile and
  docker-compose harness build from `debian:trixie` via the real install script. README and
  `docs/architecture.md` written.
- Key decisions: **Openbox** as the window manager (measured: ~18 MB resident, no session bus,
  gives Chromium the focus handling it needs). **Plain sudoers rules, no privileged helper** —
  two lines cover everything the daemon needs. Both open questions in `OVERVIEW.md` are now
  closed. The harness needs `init: true` (reap setsid'd processes) and
  `security_opt: seccomp=unconfined` (Chromium's own sandbox needs `unshare(CLONE_NEWNET)`;
  preferred over shipping `--no-sandbox`, which would also weaken real VM deployments).
- Notes / leftovers: the container entrypoint is still `sleep infinity` — slice 2 replaces it
  with the daemon. Chromium's cookie commit is timer-based and can take ~25s, so `check.sh`
  waits for the write to reach the profile before restarting the browser. Packer template
  still deferred (needs a Linux host with QEMU).
- Runtime-unverified: nothing on this Mac. Never run on a real Debian 13 VM or a VPS —
  `install.sh` idempotency was verified inside the container only.

## Slice 2: daemon spine
- Shipped: pnpm workspace (`daemon`, `shared`) on Node 24 and TypeScript strict. A Hono server
  on `SCHERMES_PORT` (default 7777) bound to `0.0.0.0`, the only socket off loopback.
  better-sqlite3 + Drizzle at `/var/lib/schermes/schermes.db`, migrations committed and applied
  on boot. Owner auth: health reports `setupRequired`, a one-shot setup endpoint claims the
  owner row, login issues an HttpOnly session cookie, sessions live in SQLite. Provider settings
  (base URL, model, API key) with the key AES-256-GCM encrypted under
  `/var/lib/schermes/master.key` (0600, generated on first boot with an exclusive open) and
  never returned by the API. Structured JSON logging with one recursive redaction step.
  `infra/schermes.service`, `infra/smoke.sh`, and the container now runs the daemon instead of
  `sleep infinity`. 16 unit tests (`node:test`, no framework) cover secrets, redaction, the auth
  guard, setup-cannot-reset, and the settings round-trip.
- Key decisions: **no build step** — Node 24's type stripping means the daemon runs from source,
  so there is no `dist/` and no cwd-relative migrations path. **Sessions in SQLite**, not memory,
  so a restart does not log the owner out. **No Docker volume for `/var/lib/schermes`** — it is
  the service user's home and a fresh volume would mask the directories `install.sh` creates
  with the right ownership, which the unprivileged daemon could not repair. **`setpriv`, not
  `su`**, as the container's privilege drop, so signals reach the daemon (`docker compose stop`
  measured at 0.34s, i.e. a real SIGTERM, not a 10s SIGKILL timeout). The Dockerfile installs
  dependencies in its own layer before copying sources; `install.sh` only installs them when the
  repository is already present, so the two paths never do it twice. `check.sh`'s loopback
  assertion now compares full `address:port` and allows exactly the web port — verified
  non-vacuous by binding a rogue `0.0.0.0:9999` and watching it fail.
- Notes / leftovers: fixed a slice-1 bug — `pnpm` was installed into `/opt/node/bin` but never
  symlinked onto `PATH`; the symlinks also now sit outside the "is node 24 present" branch so a
  node upgrade cannot leave them stale. pnpm's key for allowing install scripts is `allowBuilds`
  in `pnpm-workspace.yaml` on pnpm 11, not `onlyBuiltDependencies`. Redaction is by key name, so
  routes deliberately never log request bodies. No UI yet, so the owner password and settings
  are only reachable over the API.
- Runtime-unverified: the `pnpm install --frozen-lockfile --prod` line in `install.sh` has only
  ever run against an already-complete `node_modules` (the Dockerfile installs first). On a real
  VM it does the actual install. The systemd unit has never been started by systemd — the
  harness runs the daemon as the container command.
- Housekeeping: the Docker VM was at 94% disk and the image build failed until `docker builder
  prune -f` freed 2.4GB. It now sits at ~93% with ~3GB free, so slice 3 will likely hit the same
  wall. Build cache has already been pruned once; images and volumes were left untouched because
  they belong to other projects.

## Slice 3: agent lifecycle
- Shipped: an `agents` table (name, unique display, created timestamp) with a committed
  migration. `daemon/src/agents.ts` allocates displays lowest-free-first from `:1`, shells out
  to `create-agent-user.sh` and `start-desktop.sh`, and reconciles every agent on boot. REST
  behind the session guard: create, list and fetch an agent; no delete. `start-desktop.sh` now
  clears a stale `/tmp/.X<n>-lock` in the branch where the probe has already proved the display
  is unused. `check.sh` moved its agents to `:101`-`:103`. `smoke.sh` grew an agent section:
  invalid names refused, two agents created with their own users, homes, window managers and
  loopback-only VNC ports, both surviving a container restart, both adopted by a second daemon
  with unchanged Xvnc pids, and one killed desktop respawned while the other stays adopted.
  25 unit tests, up from 16.
- Key decisions: **the adopt-vs-respawn decision stays in `start-desktop.sh`.** It already
  probed with `xdpyinfo` and printed `adopted` or `started`; the daemon reads that word. A
  TypeScript probe would have duplicated the `getent` home lookup and the `XAUTHORITY`
  assembly for no gain. **Boot reconcile is the same call as create**, so there is one path.
  **A failed create drops the row**: the Linux user and home survive for a retry and the
  display goes back in the pool instead of being stranded. **No delete endpoint** — removing a
  Linux user and its home is destructive and can wait for a UI that confirms it.
- Notes / leftovers: the slice brief asked for adoption to be proven across
  `docker compose restart` with identical pids. That is impossible: the restart destroys the
  container's pid namespace. Proven instead by running a second daemon against the same
  database while the first one's desktops are up, which is what `systemctl restart schermes`
  creates. Reconcile runs after the server starts listening, so health answers before the
  desktops are back and anything checking them must poll. The second daemon in `smoke.sh`
  records its own pid before `exec` because `ss -p` cannot see pids in this container.
- Runtime-unverified: adoption has never run under real systemd — only the second-daemon
  simulation in Docker. `create-agent-user.sh` has never been called by the daemon on a real
  VM, only in the container.

## Slice 4: the tool layer
- Shipped: `daemon/src/exec.ts`, the single spawn boundary — every module above it takes it as
  a parameter, it caps collected output, feeds stdin, and drops the pipes two seconds after a
  process exits so a detached grandchild cannot hang a request. `daemon/src/computer.ts`:
  `screenshot`, `move`, `click`, `drag`, `scroll`, `type`, `key` and clipboard read/write over
  xdotool, scrot and xclip, validated in the daemon before anything reaches a shell.
  `daemon/src/terminal.ts`: run a command as the agent, with stdout, stderr, exit code, a
  timeout that kills the whole process group, and a background option. `POST
  /api/agents/:name/computer` and `/command` behind the session guard. `agentTarget()` and
  `asAgent()` in `agents.ts` assemble the sudo prefix. `SCHERMES_GEOMETRY` in `config.ts` is now
  the single source of both the Xvnc size and the coordinate bound. 41 unit tests, up from 25.
  `smoke.sh` grew a tool section: 404s and 400s, a screenshot of the bare desktop, an xterm
  launched in the background, a second screenshot that differs, typed keystrokes that create a
  file inside that xterm, a clipboard round-trip, a non-zero exit reported as data, a command
  killed at its timeout with no leftover process, and `apt-get install hello`.
- Key decisions: **a screenshot crosses the API as base64 PNG in the JSON body.** The model
  provider wants that encoding for a vision message, so returning bytes would mean encoding them
  again one layer up, and every action shares one response shape. **The seam is `Exec`, not a
  capability object.** Against the `DesktopOps` precedent, deliberately: the brief asks the tests
  to assert the argument list each action produces, and a `ComputerOps` fake would hide it. The
  agent-loop slice may want a capability-level fake; add the seam then rather than reopen this.
  **The timeout is GNU `timeout` inside the sudo**, which signals the whole process group, so a
  command that spawned children leaves nothing behind; killing `sudo` from Node would not reach
  them. The Node-side timer is only a backstop against a wedged `sudo`. **Free text travels on
  stdin** (`xdotool type --file -`, `xclip -i`), so it never needs shell quoting and never shows
  up in the process list.
- Notes / leftovers: known ceilings, none worth changing yet — a command that exits 124 on its
  own reads as a timeout; stderr truncates silently at 64 KiB while stdout gets a visible
  `[output truncated]` marker; the screenshot is captured to one fixed path per agent, so two
  concurrent screenshots for the same agent would race; the backstop `SIGKILL` lands on `sudo`
  and would orphan the command underneath it if it ever fired. Persistent terminals and a
  browser tool stay deferred: launching Chromium is a use of the terminal tool.
- Runtime-unverified: the backstop timer has never fired. A non-default `SCHERMES_GEOMETRY` has
  never been exercised, so the coordinate bound is untested against anything but 1280x800, and a
  desktop adopted under an older geometry can still disagree with it. The 32 MiB screenshot cap
  has never been approached.
- Housekeeping: the Docker VM sits at 91% with 4.2 GB free. Only the final `COPY` layer rebuilds
  after a source edit, so `docker compose up -d --build` is cheap; `docker builder prune -f` has
  little left to reclaim. Images and volumes belong to other projects — leave them alone.

## Slice 5: the agent loop
- Shipped: `daemon/src/provider.ts` — `Provider` is a function from a transcript plus tool
  definitions to a reply, with `openAiProvider` (chat completions, tool calling, vision) as the
  only implementation behind it. `computerToolDef()` and `commandToolDef()` generate the tool
  schemas from the constants and the action list the validators already enforce.
  `daemon/src/conversations.ts` stores conversations, messages and structured events;
  `daemon/src/loop.ts` is the turn: a transition table, transcript assembly, tool dispatch and
  the think-act-observe loop, capped at 12 steps. `agents.state` plus `conversations`,
  `messages` and `events` tables, migration `0002` committed. REST behind the session guard:
  `POST/GET /api/agents/:name/messages` and `GET /api/agents/:name/events`, 404 for an unknown
  agent, 409 while a turn is running. 57 unit tests, up from 41. `infra/provider-stub.py` is a
  scripted OpenAI-compatible endpoint bound to `127.0.0.1`; `smoke.sh` points the provider
  settings at it and asserts the agent screenshots its own desktop, runs a command and answers —
  and that the model really received the tool definitions, a bearer token and a base64 PNG.
- Key decisions: **a turn ends in `waiting_for_user`, not `completed`.** They are the same
  moment and `agents.state` is one column, so one is redundant; `waiting_for_user` is the state
  the Definition of Done names for human takeover, and `completed` is a task worker's terminal
  state, so it stays in the table with no code path to it. **The image is its own `user`
  message** — see the invariant above; inline in the `tool` message it would split an
  assistant/tool pair the moment a turn returns two tool calls. **No new seam over the tool
  modules**: `Exec` is enough to fake a tool call and it keeps the argv assertions, so the
  capability-level fake slice 4 left open is still not needed. **A tool that refuses or fails is
  an observation**, not the end of the turn; only the model failing marks the agent `failed`.
  **`describe()` clips stdout and stderr separately**, because clipping the joined text lets a
  large stdout push stderr out of the observation, which is where the reason a command failed
  lives. **The Dockerfile's install layer now copies only `install.sh` and the systemd unit** —
  it read nothing else at build time, and copying all of `infra/` meant editing `smoke.sh` cost
  a full apt cycle.
- Notes / leftovers: known ceilings — every stored screenshot is replayed on every model call,
  so a long conversation grows the request without bound (marked `ponytail:` in `loop.ts`), and
  `GET /api/agents/:name/messages` returns every image in full and unpaginated, which the UI
  slice will feel first. A second message while a turn runs is a 409 rather than a queue. There
  is one owner conversation per agent, created on demand; the `conversations` table exists so
  group chats and agent-to-agent get their own rows without a migration.
- **The shape restart recovery has to repair**: a turn interrupted mid tool call leaves an
  assistant message carrying `tool_calls` with no matching `tool` message. That is not just a
  stuck-looking agent — the stored transcript is structurally invalid, and the next model call
  will be rejected by a strict endpoint until the interrupted call gets a synthetic tool result.
  The agent is also left in `thinking` or `using_*` with no process behind it.
- Runtime-unverified: `openAiProvider` has only ever talked to the stub, so no real endpoint has
  been called; the 180s provider timeout has never fired; the 12-step cap has only been reached
  by a fake provider. Migration `0002`'s `ALTER TABLE agents ADD COLUMN state` has only run
  against a fresh database — the container has no volume for `/var/lib/schermes`, so
  `docker compose up --build` recreates it empty and the populated-database upgrade path is
  untested.
- Housekeeping: **the Docker VM is at 99% with ~620 MB free**, down from 4.2 GB. Two image
  builds this session cost ~2 GB. The superseded images from those builds were removed and
  reclaimed nothing (all layers shared); build cache reports only 115 kB reclaimable, and the
  10 GB of reclaimable volumes belong to other projects. **The next slice should assume a
  rebuild may fail on disk** and free space before starting.

## Slice 6: restart recovery
- Shipped: `repairInterruptedCalls()` in `daemon/src/conversations.ts` — finds the tool calls the
  last assistant message asked for that no `tool` message answers, and appends a synthetic result
  saying the daemon restarted and nothing of what the call did was kept. `reconcileAgents(db)` in
  `daemon/src/loop.ts` is the boot counterpart to `reconcileDesktops`: it repairs every agent's
  conversation, then moves any agent left in `thinking`, `using_computer` or `using_terminal` to
  `waiting_for_user` and records a `restart` execution event naming the state it was in and the
  call ids it answered. `restart` added to `EventType` in `shared/src/index.ts`; `using_computer`
  and `using_terminal` now reach `waiting_for_user` in `TRANSITIONS`. `main.ts` calls it above
  `serve()`. 60 unit tests, up from 57. `provider-stub.py` gained `STUB_CMD_TIMEOUT_MS` and a
  `valid=yes|no` field in its report that applies the ordering rule a strict endpoint applies.
  `smoke.sh` grew a restart-recovery section and two extracted helpers, `start_stub` and
  `spawn_second_daemon`.
- Key decisions: **a repaired agent waits for its owner rather than resuming its turn.** The
  brief allowed either. Resuming is what the OVERVIEW's "system restarted observation" implies,
  but a turn that killed the daemon would then be re-run on every boot, and auto-resume needs a
  provider configured at boot for every interrupted agent at once. The synthetic observation is
  already in the transcript, so the next message the owner sends carries the restart into the
  model call. **The repair lives in the persistence layer, not in `transcript()`**: assembly is a
  pure function of what is stored, and patching there would leave the stored history invalid and
  oblige every future reader to patch it too. **`waiting_for_user`, not `failed`**, because a
  restart is not the agent failing and `failed` would make the smoke run's turn poller treat it
  as fatal; that is why the two acting states gained a `waiting_for_user` edge. **Repair runs for
  every agent, the state move only for interrupted ones**, so a mismatch arriving from any future
  path is still fixed. **The boot reconcile runs before `serve()`** so no reader sees the broken
  shape, and each agent is wrapped in try/catch so an illegal transition cannot stop the boot.
- DoD reconciliation: the OVERVIEW line "Daemon restart mid tool-call marks it interrupted and
  the agent resumes from persisted history" is met — the agent resumes *from* the repaired
  persisted history on its next turn, not by auto-resuming at boot. `/complete` should read it
  that way rather than as unmet.
- Notes / leftovers: the smoke run kills a real daemon mid tool call. It parks `smoke-two` inside
  `sleep 600` by scripting the stub, posts the message to a second daemon on `127.0.0.1:7778`
  through the container (the session cookie works there because sessions are rows in the shared
  database), `kill -9`s it once the agent is `using_terminal`, then starts a third daemon and
  asserts the repair through the API. Both smoke runs passed with the tool-call and result counts
  scaling 2 -> 4, so the assertions are run-count independent rather than accidentally passing.
  Migration `0002`'s `ALTER TABLE agents ADD COLUMN state` is **still untested against a populated
  database** — this slice added no migration, and the container still has no volume for
  `/var/lib/schermes`, so `docker compose up --build` recreates it empty.
- Runtime-unverified: only a `using_terminal` interruption has been exercised end to end;
  `thinking` and `using_computer` are unit-tested only. The repair has never run under real
  systemd, only against a second daemon in Docker. The tool process the killed daemon was running
  is never reaped — nothing reads its result and the synthetic observation tells the agent the
  outcome is lost, which is true either way; the `ponytail:` marker for that sits in
  `infra/smoke.sh` rather than in the daemon, so a debt harvest will find it in an odd place.
- Housekeeping: the Docker VM is at 95% with **2.3 GB free**, up from ~620 MB. `docker builder
  prune -f` reclaimed 1.9 GB this session, which was enough for the rebuild plus two smoke runs.
  The 24 GB of reclaimable images and 10 GB of reclaimable volumes still belong to other projects
  — leave them alone and prune the build cache again if the next slice needs room.

## Slice 7: agents talking to each other
- Shipped: conversations became **participant sets**. `conversation_participants` holds the list,
  `conversations.agent_id` is gone, and migration `0003` backfills the new table from the dropped
  column before recreating the table. `conversationWith(db, ids)` is find-or-create by exact set
  and `conversationFor(db, agentId)` is that with one id, so every owner thread already stored
  keeps its meaning. `messages.sender` names the agent that wrote a row and stays null for the
  owner. `send_message` joins `computer` and `run_command`, built from `parseSendMessage`'s
  constants and reusing `AGENT_NAME`. `createRunner()` in `loop.ts` owns the one-turn-per-agent
  set; `runAgent(deps, agent, conversationId)` takes the thread it runs in. `waiting_for_agent`
  added to `AGENT_STATES` and `TRANSITIONS`. REST behind the session guard:
  `GET /api/agents/:name/conversations`, `POST /api/conversations`,
  `GET|POST /api/conversations/:id/messages`. 74 unit tests, up from 60. `provider-stub.py` is
  now scripted **per agent**, keyed off the `You are <name>,` line in the system prompt, with
  three scripts (`tools`, `busy`, `talk`) and two new report fields, `agent` and `heard`.
  `smoke.sh` grew an "agents talking" section and a `settle()` helper the two older pollers now
  share.
- Key decisions: **a conversation is its participant set**, so a group of exactly two and the
  direct thread between those two are the same row — they are the same set of people, and
  find-or-create is what keeps `send_message` from growing a thread per message. **The sender is
  a name, not an agent id**: names are unique and immutable, there is no delete endpoint, and the
  transcript needs the name anyway, so an id would only buy a join. **An agent that wrote to
  another ends its turn in `waiting_for_agent` rather than blocking in it.** The brief allowed
  either. Blocking holds a process across an unbounded wait and a restart during that wait leaves
  nothing to resume, while the reply is a durable row, so being woken by it costs nothing and
  survives a restart. **An answer wakes only an agent already in `waiting_for_agent`** — that is
  what makes the state load-bearing rather than decorative, and it is what stops two agents in a
  group answering each other forever off one owner message. **The runaway guard is a query, not a
  column.** `agentChain()` counts agent-authored `user` rows since the owner last spoke in that
  conversation; a `hops` column on the message would have had to be threaded through `runAgent`
  and every delivery path for the same answer. **Foreign messages are buffered like screenshots**
  rather than filtered by id alone: delivery to a busy agent stores a row inside an assistant/tool
  pair *permanently*, so a rule that only skipped fresh arrivals would break on the next read.
  **The `since` filter stays anyway**, so a message that lands mid-turn is answered by its own
  turn instead of being absorbed halfway through the previous question. **`repairInterruptedCalls`
  is now scoped to one sender**, because a shared conversation holds several agents' turns and the
  last assistant message may be someone else's.
- Notes / leftovers: **the chain guard resets on an owner message in that conversation**, and the
  owner's usual path (`POST /api/agents/:name/messages`) writes to an agent's own thread. Clearing
  a wedged agent-to-agent thread therefore needs `POST /api/conversations/:id/messages`, which is
  not discoverable from the symptom — the UI slice should surface it. The drain is capped at
  `MAX_ROUNDS` and releases the agent with messages still waiting when it caps out; the log line
  is the only trace and nothing retries, which the chain guard makes near-unreachable but does not
  make impossible. `send_message` always targets the `{sender, target}` thread, never the
  conversation the turn is running in, so an agent addressing a groupmate opens a side channel.
  The known ceilings from slice 5 are unchanged: every stored screenshot is still replayed on
  every model call, and `GET .../messages` is still unpaginated and returns every image in full.
- Runtime-unverified: only two agents have ever been in a conversation — a group of three has
  never run, and with it the concurrent-writer case is only exercised at width two. The stranded
  `waiting_for_agent` rescue is unit-tested only; no real daemon has been killed while an agent
  waited on a reply. The `MAX_ROUNDS` cap has never been reached. `MAX_AGENT_CHAIN` is exercised
  by a unit test with a fake provider, never by the stub. Migration `0003`'s table recreate has
  only run against a fresh database: like `0002`'s `ALTER TABLE` before it, the container still
  has no volume for `/var/lib/schermes`, so `docker compose up --build` recreates it empty and the
  populated-database upgrade path — including the participant backfill, the one statement in
  `0003` that only does anything on a populated database — is untested.
- Housekeeping: the Docker VM is at 95% with **2.5 GB free**, roughly where slice 6 left it. Three
  source-only rebuilds this session cost nothing measurable — the install layer reads only
  `install.sh` and the systemd unit, so editing `smoke.sh` or `provider-stub.py` no longer forces
  an apt cycle. The 24 GB of reclaimable images and 10 GB of reclaimable volumes still belong to
  other projects; `docker builder prune -f` reports almost nothing left to reclaim, so a slice
  that needs real room will have to ask the user.

## Slice 8: task workers, delegation and resource caps
- Shipped: a task worker is **a row in `agents` with a `parent_id`**, so the loop, the
  transition table, the event log and the conversations work on it unchanged. Migration `0004`
  is two plain `ALTER TABLE ... ADD COLUMN`s (`parent_id`, `parent_conversation_id`), which is
  the one migration shape that is safe against a populated database. `daemon/src/workers.ts` —
  `parseSpawnWorker` / `spawnWorkerToolDef`, `workerDir`, `workerPrompt`, `liveWorkers`;
  `agents.ts` gained `isWorker`, `findAgentById`, `nextWorkerName`, `insertWorker`, a
  `cwd` on `AgentTarget` and a worker filter on `reconcileDesktops`. `loop.ts`: the
  `spawn_task_worker` branch, `toolTarget()` (a worker's tool calls run as its parent, in its
  own directory), a worker-shaped `runAgent` (its own prompt, `run_command` only, ends in
  `completed`), `report()` for the result and the failure, `waiting_for_task_worker` in
  `TRANSITIONS`, both caps, and a worker pass in `reconcileAgents`. `createRunner` gained
  `maxLoops` and `atCapacity()`; `config.ts` gained `SCHERMES_MAX_LOOPS` (8) and
  `SCHERMES_MAX_WORKERS` (4); the two message routes answer **429** above the loop cap.
  `transcript()` now takes a name and a system prompt instead of an agent and a screen. 83 unit
  tests, up from 74. `provider-stub.py` gained a `worker` script that tells a worker from a
  permanent agent by its system prompt; `smoke.sh` grew a task-worker section and a loop-cap
  assertion against the second daemon, which now runs with `SCHERMES_MAX_LOOPS=1`.
  `docs/architecture.md` gained a Task workers section.
- Key decisions: **a worker is an agent row, not a table of its own.** Every alternative needed
  the loop's state reads and writes, the event log's `agent_id` and the participant table
  parameterised for a second kind of runnable thing; a `parent_id` column buys all of it for
  one nullable column. **It has no display of its own.** It shares its parent's, but
  `agents.display` is unique and not null, so a worker row takes the next number above
  `MAX_DISPLAY`; dropping the unique constraint instead would have meant recreating `agents`,
  which is exactly the migration shape that breaks on a populated database. The reconcile
  filter is load bearing, not hygiene: `start-desktop.sh` takes three digits. **No computer
  tool for a worker** — one display, one mouse — and no `spawn_task_worker` either, so nothing
  multiplies recursively. **The parent ends its turn in `waiting_for_task_worker`** rather than
  blocking, for the reason slice 7 gave for `send_message`: a durable row survives a restart,
  a held process does not. **The result is a message, not a new path**, written into the thread
  the parent was in when it spawned, which is why a result landing mid-turn is picked up by the
  drain that already existed. **The daemon derives the working directory from the worker's
  name** and creates it before the row exists, so no path the model wrote ever reaches a shell
  and no worker is left pointing at a directory that is not there. **The loop cap lives in the
  runner and the worker cap is a query over the rows**, and `atCapacity(name)` deliberately does
  not refuse an agent that is already running: that is not a second loop, it is a row the
  running turn will pick up.
- **Migration `0003` fails against a populated database** — measured, not suspected. Drizzle
  runs every migration inside `BEGIN`/`COMMIT`, and `PRAGMA foreign_keys=OFF` is a no-op inside
  a transaction, so the `DROP TABLE conversations` in its table recreate hits an immediate
  foreign key violation from `messages`. Rebuilding an empty database hides it. A slice that
  adds the `/var/lib/schermes` volume has to fix `0003` in the same breath, and no future
  migration may recreate a referenced table.
  **[superseded by slice 10]** — the diagnosis above is right and the conclusion was wrong.
  `0003` is fine; the bug was that nothing turned foreign keys off *around* the transaction.
  `openDb` does now, so a table recreate is a legal migration shape again.
- Notes / leftovers: `waiting_for_task_worker` does **not** gate the wake the way
  `waiting_for_agent` does — a worker's result is a `user` row and wakes its parent in any
  state — so it is load bearing only for the boot rescue and for what the UI will show. **The
  owner can still post to a worker over HTTP**: `send_message` refuses a worker as a target, but
  `POST /api/agents/<worker>/messages` does not, so writing to a finished one starts a fresh
  turn and makes it report to its parent again. The UI slice has to decide what a worker row in
  a sidebar opens before it wires a chat box to one. A turn
  that both writes to an agent and spawns a worker ends in `waiting_for_task_worker`, so a peer
  reply cannot wake it, only the worker's result can. The loop cap is **per process**: two
  daemons against one database allow twice as many loops, which is what the smoke run relies on
  to hit the cap with a cap of one. `start()` above the cap drops the turn with a log line —
  every caller that can answer somebody asks `atCapacity` first, so this is only reachable from
  a wake or a worker report on a saturated daemon, and the row is picked up by the next turn or
  by the boot rescue. Worker rows are never deleted, so a long-lived install accumulates them,
  and with them display numbers above 999 and rows in `GET /api/agents`. The slice-5 ceilings
  are unchanged: every stored screenshot is still replayed on every model call, and
  `GET .../messages` is still unpaginated.
- Runtime-unverified: only one worker has ever been live at a time — the worker cap is
  exercised by a unit test with a pre-seeded row, never by the stub, and no run has had two
  workers going at once. A worker has never been killed mid tool call by a real daemon death;
  the boot repair for one is unit-tested only. `nextWorkerName` running out (a parent named
  close to 31 characters) has never happened. A worker's `mkdir` has never failed. No worker has
  ever been spawned from a group thread, so the `parent_conversation_id` that is not the
  parent's own thread is untested.
- Housekeeping: the Docker VM is at 95% with **2.2 GB free**, roughly where slice 7 left it; one
  source-only rebuild and two smoke runs this session cost nothing measurable.
  `docker builder prune -f` reclaimed 234 kB, so there is nothing left there. The 24 GB of
  reclaimable images and 10 GB of volumes still belong to other projects — leave them alone; a
  slice that needs real room has to ask the user.

## Slice 9: human takeover
- Shipped: `daemon/src/vnc.ts` — `attachVncProxy(server, db, dial?)` hangs a
  `WebSocketServer({ noServer: true })` off the HTTP server's `upgrade` event, matches
  `/api/agents/:name/vnc`, checks the session cookie with `parse` from `hono/utils/cookie` plus
  `sessionValid`, resolves the agent through a new `desktopAgent()` in `agents.ts`, and pipes
  bytes both ways to `127.0.0.1:(5900 + display)`. `daemon/src/control.ts` — `createControl()`
  returns `hold` / `release` / `held` over a `Set<number>` of displays, plus `CONTROL_REFUSAL`
  (the text the agent reads) and `CONTROL_HELD` (what the loop and the event log match on).
  `app.ts` gained `GET|POST|DELETE /api/agents/:name/control` (each answering `{held}`, each
  recording a `control` event), the 409 on `/computer` while a desktop is held, and it now
  builds the `Control` the runner carries. `loop.ts`: the gate in `dispatch`'s computer branch,
  a `refused` flag that ends the turn after the reply's calls have all been answered, and
  `endState()` extracted so the gated ending is the same ending a normal turn has. `control`
  added to `EventType` in `shared/src/index.ts`; no migration, because `events.type` is free
  text and ownership is not a row. `main.ts` attaches the proxy. `ws@8.21.3` is a new
  dependency of `@schermes/daemon` and `@types/ws` a dev one. 89 unit tests, up from 83, with
  `daemon/src/vnc.test.ts` new. `infra/smoke.sh` grew a human-takeover section, a raw-upgrade
  probe run with `node -e` inside the container, and an idempotent control reset before the tool
  layer. `docs/architecture.md` gained a Human takeover section.
- **The brief's premise was wrong: Hono's WebSocket support was not already a dependency.**
  `@hono/node-server@2.1.1` exports `serve`, `serve-static`, `conninfo` and `early-hints` and
  nothing else; `ws` is only a devDependency of that package. Hand-rolling the frame codec
  would have been ~100 lines of masking and length parsing at a trust boundary, so `ws` was
  added instead. `@hono/node-ws` was not: a byte proxy wants the raw duplex, and `noServer:
  true` on the server's own `upgrade` event is less code than a Hono route wrapper.
- Key decisions: **input ownership lives in the daemon process, not in a column and not in a
  row of its own** — the same answer the loop cap gave. A hold is a human at a live socket, and
  a daemon that dies takes every viewer with it, so a persisted flag would outlive the person
  behind it and boot would only have to clear it again. What is durable is the agent's side:
  the refusal in its transcript, the `control` event in its history, and the state it landed in.
  **Restart behaviour therefore needs no new repair**: a fresh process starts holding nothing,
  and an agent that was mid-turn is already moved by the pass slice 6 added. A gated agent is
  not an interrupted one — its transcript has every call answered — so `reconcileAgents` writes
  no `restart` event for it, which the unit test asserts. **The gate is two lines at the two
  seams slice 4 named**, the `/computer` route and the loop's tool dispatch, rather than inside
  `performComputerAction`: both callers have to present the refusal differently (409 versus an
  observation), so an exception would have bought a class and a message comparison and no
  safety. **Taking control does not interrupt a call in flight** — there is no result to hand
  back, a half-finished drag would leave a button down, and a computer action is bounded at 60s
  — it refuses what comes next. **A refusal ends the turn**, but only after every call in that
  reply has its tool result: ending mid-reply would write the exact shape `repairInterruptedCalls`
  exists to repair. **Returning control does not restart the turn**; the owner's next message
  does, which is the answer slice 6 gave for a repaired agent. **`run_command` is not gated**:
  it is not input to the display, and a human looking at a screen should not stop the agent
  writing files. **A task worker is a 404 to the proxy and to the control routes**, via
  `desktopAgent()`, because its `display` is a placeholder above 999 and there is nothing behind
  `5900 + that`.
- Notes / leftovers: the proxy is a byte pipe. **A viewer that sends pointer and key events
  while it does not hold control is stopped only by its own client** — enforcing view-only means
  filtering RFB message types 4 and 5 out of a stream that is not message-framed, which needs a
  real parser. There is **no backpressure**: a slow viewer buffers in the daemon. **`DISPLAY` is
  exported into every command**, so an agent that runs `xdotool` through `run_command` walks
  around the gate; closing that means gating on what a command does rather than on which tool
  asked. **A hold with a closed browser behind it stays held** until the owner returns it or the
  daemon restarts, which is why the smoke run releases control before it drives a display and
  again at the end of its own section. The owner's own `/computer` route is gated too, which is
  deliberate: while a human has the mouse over VNC, nothing else drives that display. The
  slice-5 ceilings are unchanged — every stored screenshot is still replayed on every model call
  and `GET .../messages` is still unpaginated.
- Runtime-unverified: **no browser has ever connected.** noVNC has never spoken to this proxy;
  what has been proven is that a real Xvnc's `RFB 003.008` reaches a raw WebSocket client through
  the daemon and that a masked client frame reaches the far side unmasked. Only one viewer has
  ever been connected to a desktop at a time, and no viewer has been connected while the agent
  was also driving it. The proxy has never been killed mid-stream, and `vnc.destroy()` on a
  socket the daemon is still writing to has never happened. Control has only ever been taken
  while the agent was idle or between calls — never while a computer action was actually in
  flight, which is the case the "does not interrupt" decision is about. Two desktops have never
  been held at once.
- Housekeeping: the Docker VM is at 95% with **2.3 GB free**, where slice 8 left it. Adding `ws`
  invalidated the dependency layer, so the rebuild cost one `pnpm install --prod` and no apt
  cycle; two smoke runs and one `check.sh` cost nothing measurable. The 24 GB of reclaimable
  images and 10 GB of volumes still belong to other projects and need the user's call.

## Slice 10: a schermes that has been running for a while
- Shipped: `docker-compose.yml` gained a named volume `schermes-data:/var/lib/schermes`, which
  is the whole reason any of the rest of this slice is testable. `daemon/src/db.ts` — `openDb`
  now opens with `foreign_keys = OFF`, migrates, runs `PRAGMA foreign_key_check` and **throws**
  if it returns anything, then turns foreign keys back on. `conversations.ts` gained
  `pageMessages(db, id, {limit, before})` and the `MessagePage` type; `app.ts` gained
  `messagePage(c)`, `DEFAULT_PAGE` (50), `MAX_PAGE` (200) and a 400 on a page nobody can serve,
  and both `GET /api/agents/:name/messages` and `GET /api/conversations/:id/messages` now read
  through it. `loop.ts` gained `MAX_REPLAYED_IMAGES` (3) and the pre-pass in `transcript()` that
  decides which screenshots ride along; the `ponytail:` marker on that function is gone. 95 unit
  tests, up from 89, with `daemon/src/db.test.ts` new. `infra/smoke.sh` grew a paging section,
  swapped the transcript-survives-a-restart section for one that survives
  `docker compose up --build --force-recreate`, and restarts the provider stub and asserts the
  desktops afterwards. `docs/architecture.md` and `README.md` updated.
- **The `0003` decision was "neither".** The brief offered rewriting it in place or repairing it
  with a `0005`; both are wrong, because `0003` is not broken. It is exactly the SQL SQLite
  documents for a table recreate, and **step 1 of that procedure is turning foreign keys off
  before the transaction starts** — which drizzle cannot emit from inside a file it wraps in
  `BEGIN`/`COMMIT`. Fixing the file would have left the next generated recreate a landmine and
  would have kept the slice-8 rule "no future migration may recreate a referenced table", which
  is a real constraint on the schema. Three lines in `openDb` retire that rule instead. Measured
  on the way: `PRAGMA defer_foreign_keys=ON` looks like the in-transaction answer and is not —
  the implicit `DELETE` inside `DROP TABLE` increments the deferred-violation counter and the
  rename never decrements it, so the migration reaches `COMMIT` and fails there.
- Key decisions: **`foreign_key_check` is fatal.** A daemon that booted on a referentially broken
  database would only write more rows into it, and this is the one place in the slice where a
  crash beats a shortest diff. **The volume is named, not bound.** A fresh named volume is seeded
  from the image with ownership and modes intact, so `master.key` stays 0600 under an
  unprivileged daemon that could not repair a directory it does not own; a bind mount is what the
  older architecture note was right to be afraid of. **Agent homes stay outside the volume.** A
  recreated container has a fresh `/etc/passwd` anyway, so persisting `/home` would pair old
  directories with new uids; `reconcileDesktops` plus the idempotent `create-agent-user.sh`
  already rebuild both from the surviving rows, which the smoke run now asserts. **Paging is a
  second function, not a default argument.** `listMessages` keeps returning everything because
  four in-daemon readers are wrong on a truncated history; a default limit would have cut an
  assistant message off from its tool results and produced the exact shape
  `repairInterruptedCalls` exists to prevent. **Images stay inline.** A route of their own means
  a second round trip per screenshot for the UI that is about to render them, plus a new access
  check, and paging already bounds the response. **A short page is the end marker**, so nothing
  counts the rest and no envelope was needed — the routes still answer a bare JSON array, which
  is also what kept every existing `jq` in the smoke run working. **Old screenshots become text
  rather than disappearing**, so an agent knows the screen it remembers is stale; the tool result
  naming each one is kept because it is small and is the only record the call happened.
- Notes / leftovers: **a page is a window on the rows, not on the turns.** A boundary can land
  inside a turn and hand a reader a tool result whose assistant message is on the page before it;
  a test pins that behaviour rather than leaving it to be discovered. Nothing a reader gets
  becomes a model request, so it is a rendering problem for the UI slice, and the other half is
  on the page it is walking back to anyway — a variable page size or a response envelope would
  both cost more than the concatenation the UI does regardless. **The image budget bounds
  images, not text.** A very long conversation still
  grows the request, just slowly — trimming or summarising old text is the next ceiling and
  nobody has hit it. **Nothing is ever deleted**: the event log, finished workers and old
  conversations all accumulate, so a long-lived install grows monotonically. That is disk, not
  correctness, and a retention policy was explicitly out of scope. A reader walking backwards
  with `before` fetches one empty page when the thread length is an exact multiple of the limit.
  The smoke run now rebuilds the image inside itself, which costs a `COPY` layer and a container
  recreate per run; it also takes the scripted provider stub down with the container, so
  `start_stub` is called again straight after — moving that section without moving the restart
  will break every turn below it.
- Runtime-unverified: **no database has ever been migrated in the container**, only in unit
  tests. The volume was created fresh by this slice, so the real container has only ever run
  `0000`-`0004` against an empty file; the populated-database path is covered by
  `db.test.ts`, which drives the real `openDb` and the real drizzle migrator against a
  file-backed database, first with the journal trimmed to `0000`-`0002` and then with the whole
  folder. The `foreign_key_check` throw is unit-tested against a hand-broken database, but no
  migration has ever tripped it. `MAX_PAGE` has never been reached: the longest thread in a smoke run is under 100
  messages, so a 50-message default page has never truncated anything in the harness, and no
  reader has ever paged back through screenshots in bulk. The transcript budget is exercised by a
  unit test with seven synthetic screenshots; no real agent has taken more than three in one
  conversation, so no model has ever been told a screenshot is no longer shown.
- Housekeeping: the Docker VM is at 95% with **2.0 GB free**, roughly where slice 9 left it. Four
  rebuilds and four smoke runs this session cost nothing measurable — no manifest changed, so
  every rebuild was the final `COPY` layer alone. The new volume is a rounding error next to the
  10 GB of reclaimable volumes that still belong to other projects; those and the 24 GB of
  reclaimable images still need the user's call.

## Slice 11: the UI
- Shipped: a `ui` workspace package — React 19, Vite 8, TypeScript strict, `@novnc/novnc` 1.7,
  every one of them a `devDependency`. `ui/src/App.tsx` (login and first-run setup, sidebar,
  create-agent form, view routing, agent pane with chat/desktop tabs, worker pane),
  `Chat.tsx` (paged thread, inline screenshots, composer), `Desktop.tsx` (noVNC canvas, take /
  return control, activity), `Settings.tsx`, `api.ts` (one fetch helper, `ApiError`, the
  typed routes), `thread.ts` + `thread.test.ts` (the pure logic), `poll.ts`, `novnc.d.ts`,
  `styles.css`. `pnpm-workspace.yaml` lists `ui`; pnpm wrote a `minimumReleaseAgeExclude`
  block of its own while resolving it. The `Dockerfile` is three stages now — `base` (the
  `install.sh` layer), `web` (a filtered install plus `vite build`), and the runtime image,
  which copies `ui/dist` forward and nothing else. `.dockerignore` gained `ui/dist`.
  `daemon/src/config.ts` gained `uiDir`; `app.ts` serves it through `serveStatic` registered
  after every route. `infra/install.sh` builds the UI too, inside the guard that already
  installed the daemon's dependencies, because nothing ships `ui/dist` and the Dockerfile stage
  is not on the path a real host or the Packer image takes. `conversations.ts` and `app.ts` gained the `after` window on both message
  routes. `infra/smoke.sh` grew a served-UI section, a nothing-else-falls-through section and a
  polling section. 105 unit tests, up from 95: 96 in the daemon and 9 new in `ui`.
- **One API addition, and it is what makes polling possible.** `GET .../messages?after=<id>`
  returns the rows after that id. Without it the only way to watch a live thread is to re-read
  the newest page, which is up to 200 rows of inline base64 screenshots every couple of seconds;
  with it an idle poll is `[]`. It is **ascending from the mark**, not the newest rows above it:
  a poll that missed a burst longer than its limit has to resume where it stopped rather than
  skip the middle of the thread. `before` and `after` are alternatives and asking for both is a
  400. Nothing else was added — measured first: `GET .../events` answers with 23 kB after
  a dozen smoke runs, so it did not earn a `?limit=` and the desktop view just refetches it.
- Key decisions: **polling, not a websocket event stream.** The daemon has no push side at all,
  so a stream is a new module, a subscription registry and a reconnect story on both ends; a
  timer is none of those, heals itself after a laptop sleep or a rebuild, and — because nothing
  on the server depends on it — keeps "closing the browser does not stop agent work" true by
  construction rather than by care. **The static route is registered last and there is no
  index.html fallback**: an unknown `/api` path is the guard's 401 before it is a missing file,
  and everything else that is not a built asset is a 404, because there is no client-side router
  to hand it to. **The app shell is public** — it is a login form until the API answers, and
  putting it behind the session would only mean serving a login page in front of the login page.
  **`uiDir` is absolute**, resolved from `import.meta.dirname` the way `migrationsDir` already
  is: the container's command has no working directory, so a relative root resolves against `/`
  and 404s every asset. **The UI is built in a stage of its own** sharing the `install.sh` base
  layer, so vite and react never reach the shipped image and the runtime `pnpm install --prod`
  skips them because every UI dependency is a dev one. **And therefore `install.sh` builds it as
  well**: that guard is false during the image build, where no sources exist yet, so the
  container path is untouched and nothing is built twice — but it is true on a real host and in
  the Packer image the next slice writes, which would otherwise have shipped a daemon that logs
  `no built ui to serve` and answers 404 on `/`. Caught by review, not by any check here: the
  harness only ever exercises the Dockerfile. **View-only is the default and unknown
  ownership is view-only**: the proxy is a byte pipe with no RFB parser, so `viewOnly` is set
  before the socket opens and cleared only when the daemon says this browser holds the desktop.
  **A task worker is a nested sidebar row** behind a count, opening a read-only transcript with
  no composer — the owner *can* post to one over HTTP, which starts a fresh turn on a finished
  worker, and the UI declines to offer that and says to write to the parent instead. **A shared
  thread's composer posts to `/api/conversations/:id/messages`** and carries a line saying that
  posting there, rather than in either agent's own thread, is what clears a wedged agent-to-agent
  thread — the one thing in the API that is not discoverable from the symptom. **An empty API
  key field is omitted from the settings write**, because the daemon stores whatever string it
  is handed and would otherwise erase the stored key on every save. **A 401 anywhere is one
  window event**, not a callback threaded up to the root.
- Notes / leftovers: **`tsconfig.base.json` has to be copied into the web stage** — Vite 8 is
  rolldown-based and reads it to transform the TSX; without it the build fails with "Tsconfig
  not found" and nothing else. **noVNC's `exports` is a bare string**, so the import is
  `@novnc/novnc`, not `@novnc/novnc/core/rfb.js`, and it ships no types — `ui/src/novnc.d.ts`
  declares the five members this UI touches. **A concise arrow body in `useEffect` takes React
  19 down**: `useEffect(() => el?.scrollIntoView(), [x])` returns a value React tries to call as
  a cleanup, and the whole tree unmounts with "destroy is not a function". **`install.sh` runs
  pnpm under `CI=true`**: a re-run changes which projects have a modules directory and pnpm
  aborts the removal with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` — which the first version
  of this hit only because the whole block was tested by hand inside the container, since the
  image build never reaches it. `GET .../events` is
  still unpaged and grows for the life of the install; the desktop view polls it every 4s and
  shows the newest 40. Switching tabs unmounts the chat, so it re-reads its newest page.
  The poll intervals are fixed — 2s for agents and the open thread, 4s for control and events,
  5s for the conversation list. There is no scaling control, clipboard bridge or fullscreen on
  the desktop view, and no keyboard shortcut but ⌘/Ctrl+Enter to send. An agent named `ui-one`
  was created through the UI during this slice and is in the volume for good.
- Verified by hand in a browser, because the smoke run cannot: first-run setup on a throwaway
  data directory — the gate names the minimum length, a short password surfaces the daemon's own
  refusal, a good one lands in an empty console, a reload keeps the session and logging out
  returns to a gate that now says "Log in". Against the container: the settings round-trip
  including that an untouched key field does not erase the stored key, agent creation and the
  400 an invalid name gets, a message that reached the model and came back with its screenshots,
  load-older, the live desktop, taking control and typing into the agent's xterm through noVNC,
  and view-only proven by the same input doing nothing after control was returned. `install.sh`
  was run twice inside the container with sources present: both exit 0 and `ui/dist` is there
  after each.
- Runtime-unverified: **only one browser has ever been open at a time.** Two viewers on one
  desktop, or two tabs polling the same thread, have never happened. **No session has ever
  expired in a browser**, so the 401 event has only been exercised by the first load before
  login. The **orphan tool row has never actually rendered** — the boundary is unit-tested on
  both sides but no real page has landed inside a turn while a person was looking. **A 429 has
  never been shown**: the loop cap has only ever been hit by the smoke run's second daemon.
  Only Chrome, only a desktop-width window — nothing has been opened on a phone, and the
  sidebar is a fixed 280px column with no narrow layout. The `after` poll has never had to
  catch up more than a handful of rows. Everything here still runs against the scripted stub;
  no real OpenAI-compatible endpoint has ever answered.
- Housekeeping: the Docker VM is at 87% with **6.1 GB free**, up from the 2.0 GB slice 10 left,
  and the space came from this project's own garbage rather than anyone else's. Editing
  `install.sh` invalidates the base layer, so the last rebuild was a full apt cycle and it ran
  the VM out of disk: the daemon came up and died on `SQLITE_IOERR_SHMSIZE`, which is what a
  full disk looks like from SQLite. Removing seventeen dangling `schermes-schermes` images left
  by this task's own rebuilds freed about 6 GB, and `docker builder prune -f` another 6.5 GB of
  cache the same rebuilds had orphaned; the container came straight back on the volume with the
  database intact. **Anything that touches `install.sh` costs a full base rebuild** — plan for
  roughly 2 GB of headroom before starting one. The 18.6 GB of reclaimable images and 10 GB of
  volumes still belong to other projects and still need the user's call; nothing here touched
  them, and the one dangling image that was not ours was left alone.

## Slice 12: the Packer template and the documentation pass
- Shipped: **`infra/packer/schermes.pkr.hcl`**, a QEMU builder producing a qcow2 for Unraid, plus
  the whole documentation pass — `docs/README.md` (index), `development.md`, `deployment.md`,
  `image-build.md`, `configuration.md`, `troubleshooting.md`, two new `architecture.md` sections
  (**Persistence model**, **Security model**), and a root README brought back in line with the
  code. `.dockerignore` gained `infra/packer/build` so a qcow2 can never enter the build context.
  `infra/install.sh` was **not** touched, so no base-layer rebuild was spent and the disk is
  where slice 11 left it.
- **The image source is Debian's own generic-cloud qcow2, not an installer ISO.** It is already
  a qcow2, already minimal, and boots into cloud-init, which is what buys an SSH login from a
  one-shot `cidata` seed instead of a 150-line `boot_command` typing at a preseed. The build
  uploads a `git archive` tarball to `/opt/schermes` — that path is not a preference, the
  sudoers rule names `create-agent-user.sh` under it literally — runs `install.sh`, and then
  revokes everything it knew: the build SSH credentials, cloud-init's password-auth drop-in, the
  seed state, the host keys, the machine id, the apt lists and the logs.
- Key decisions: **`git archive`, not a directory upload** — the `file` provisioner has no ignore
  list and would send `node_modules` and `ui/dist` over SSH; the cost is that uncommitted work is
  invisible, which matters here (see below). **cloud-init stays installed**, because Unraid gives
  a VM no datasource and what it still does is grow the root filesystem and regenerate the host
  keys; documented as an expectation, not an observation. **First boot is claim-once**: the
  daemon binds `0.0.0.0` because a VM is reached from elsewhere, so whoever reaches the port
  first becomes the owner, and the window is closed rather than guarded — setup succeeds exactly
  once, which `smoke.sh` asserts. **Eleven documents, seven files and four `architecture.md`
  sections.** The Scope names eleven; NEXT_SLIDE said ten and listed eleven. Agent lifecycle,
  desktop/session architecture, persistence model and security model stayed sections because each
  only reads correctly next to the others — the security model *is* the privilege model plus the
  secrets handling plus the single-port rule. Written down in `docs/README.md` so `/complete`
  need not re-litigate it.
- Notes / leftovers: `configuration.md` is enumerated from `daemon/src/config.ts`, which found
  the README listing **three** environment variables where there are **five** — `SCHERMES_MAX_LOOPS`
  and `SCHERMES_MAX_WORKERS` were undocumented. Two bugs were caught in the template by review
  rather than by any check: a custom `execute_command` that dropped Packer's `{{ .Vars }}`, so
  `CONSOLE_PASSWORD` would never have reached the script, and `sudo -E` on a cloud image whose
  sudoers grants no `SETENV`; the password now travels base64-encoded and inline, tested against
  a password containing a quote, a dollar and a double-quote. Packer was **not** installed on
  this machine — Homebrew's tap-trust gate refused `hashicorp/tap`, so the binary went to the
  session scratchpad and the half-created tap was removed.
- Runtime-unverified: **`packer build` has never executed** and the qcow2 does not exist. It
  needs QEMU and `/dev/kvm`, so a Linux host; this is a Mac. `packer init`, `fmt -check` and
  `validate` all pass on Packer 1.16.0, and the `git archive` step and its guard were both run
  here. Two claims inside the template are reasoned rather than observed and `image-build.md`
  says so in those words: that cloud-init under a `None` datasource grows the root filesystem
  and regenerates the SSH host keys. Neither is settleable in the harness, because `install.sh`
  installs `openssh-client` and not the server. One ordering is flagged in a comment as the most
  likely first-build failure: the cleanup provisioner revokes the credentials Packer is connected
  with, and `shutdown_command` runs after it.
- **`HEAD` is at slice 5.** Slices 6–11 are uncommitted, `ui/` included, so `git archive HEAD`
  yields a tarball with no UI and no agent loop and an image built from it would not contain the
  product. Not fixed here — committing six other slices' work in one sweep is not this slice's
  call — but made loud: the first provisioner checks the tarball for `ui/package.json` and stops
  with a message naming the fix. Confirmed firing against the current `HEAD`.
- Verified: `packer fmt -check` and `packer validate infra/packer/` pass. `pnpm check` clean,
  `pnpm test` 105 passing (96 daemon, 9 ui). `./infra/smoke.sh` exit 0 **twice in a row**.
  `check.sh` exit 0, still only `:7777` off loopback. Every claim in the eight touched documents
  audited against source in a second pass — every constant, the env-var set, the eight table
  names, the public-path set, the arch support in `install.sh`, each named identifier and error
  string — **no discrepancies**. All 8 docs link-checked: 0 broken files, 0 broken anchors.

## Completion pass
A fresh-context review at `/complete` found one correctness gap and it was fixed: the runner's
drain measured every round against the global max message id, so a second thread written to
during the first round was never picked up until the owner spoke again. The drain now records
the high-water mark per thread at the moment a round starts serving it, and
`pendingConversation` takes that per-thread mark. One test pins it (two threads mid-turn, three
turns, none repeated). Daemon suite 97 passing.

Left as recorded decisions, listed in ACCEPTANCE.md: `run_command` is outside the take-control
gate, and a worker report arriving at the loop cap waits for the parent's next turn.
