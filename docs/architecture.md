# Architecture

Decisions are tagged **Requirement** (the product does not work without it), **Recommendation**
(a considered default that a deployment may override), or **Deferred** (deliberately out of
scope for now, with the trigger that would bring it back).

## Shape of the system

One Linux machine — a Docker container by default — runs everything: a Node daemon, one Linux user per permanent
agent, one X display per agent, and a single web port. There is no per-agent container, no VM
per agent, and no orchestrator.

- **Requirement** — one machine, one exposed port. Everything else binds to loopback and is
  reached through the daemon.
- **Requirement** — durable state lives in SQLite, not in daemon memory. Agent loops are
  in-process async tasks that can be killed and rebuilt from the database.
- **Recommendation** — Debian 13 (trixie) as the base. Chromium and Firefox are real `.deb`
  packages rather than snaps, so profile paths and automation are predictable.
- **Deferred** — multi-user, RBAC, billing, Kubernetes, autoscaling, plugin marketplace. Revisit
  only if schermes stops being a single-owner personal machine.

## Display stack

- **Requirement** — X11, not Wayland. `xdotool`, `scrot` and VNC are mature and scriptable on
  X11. Wayland would need a different input-injection path per compositor.
- **Requirement** — one `Xvnc` process per agent. TigerVNC's `Xvnc` is an X server and a VNC
  server in one process, so a desktop is a single thing to spawn, adopt and kill.
- **Requirement** — VNC binds loopback only (`-localhost -rfbport $((5900 + display))`), plus
  `-nolisten tcp` so the X protocol itself is reachable only over the Unix socket. The daemon
  proxies VNC to the browser over its own WebSocket, which is where ownership is enforced.
- **Requirement** — desktops are spawned detached with `setsid` as the agent user and adopted
  on daemon restart by probing the display with `xdpyinfo`. No per-agent systemd units, so the
  same code path works in Docker and on a bare host.

### Window manager: Openbox

**Recommendation** — Openbox. Decided in slice 1 by measurement, not preference: it starts in
well under a second, needs no session bus, and gives Chromium the window management it expects
(focus, `_NET_ACTIVE_WINDOW`, resizing). Measured in the harness, a desktop costs about 18 MB
resident for Openbox and 28 MB for Xvnc, before the browser. XFCE was the fallback and was not
needed. Swapping it means changing one line in `infra/desktop/start-desktop.sh`.

A window manager is not optional. Without one, Chromium windows never receive focus and
`xdotool` keystrokes go nowhere.

### The desktop session

`start-desktop.sh` gives every display a session the owner can use too: a gradient wallpaper
(`hsetroot`) and a `tint2` dock on the bottom edge with launchers for Chromium, PCManFM and
LXTerminal, the open windows and a clock. The dock reserves its strip with a strut, so a
maximized window stops above it. The launchers are `.desktop` files beside the script, named in
`tint2rc` by their `/opt/schermes` path, which the sudoers rule already depends on.

- **Requirement** — the dock's Chromium runs on the agent's `~/.chromium-profile`, so a login
  the owner does by hand is one the agent's own Chromium sees.
- **Requirement** — Chromium starts maximized, through `--start-maximized` in
  `/etc/chromium.d/schermes`. Without it a new window opens at most 1050px wide whatever the
  screen size, and sites hand the agent their tablet layout.
- The session starts unconditionally once a fresh Xvnc answers. An "already running" guard would
  see the openbox of a display that just died, still on its way out, and leave the new display
  without a window manager.

## Privilege model

**Requirement** — plain sudoers rules, no setuid helper. This was the other open question from
the overview, and a helper binary turned out to buy nothing: everything the daemon needs is
expressible as two sudoers lines, and a helper would be one more thing to audit.

`/etc/sudoers.d/schermes`:

```
schermes ALL=(root) NOPASSWD: /opt/schermes/infra/desktop/create-agent-user.sh, /usr/bin/apt-get
schermes ALL=(%agents) NOPASSWD: ALL
```

- The daemon runs as the unprivileged system user `schermes`.
- It may become any member of the `agents` group. A `%group` entry in a runas list matches every
  member of that group, which is how one rule covers every present and future agent user.
- Its only root powers are creating an agent user and installing packages. `create-agent-user.sh`
  lives under `/opt/schermes`, is owned by root, and validates its argument against
  `^[a-z0-9][a-z0-9-]{0,30}$`, so the rule is not a path to arbitrary root.

`/etc/sudoers.d/agents` gives agent users passwordless sudo. That is intentional: an agent is
the operator of its own machine and needs to install packages and edit system files to be
useful. The isolation boundary of schermes is the machine, not the agent user. Deploy it
somewhere you would be comfortable giving a person root.

## File model

- `~agent-<name>/workspace` — the agent's own files.
- `~agent-<name>/uploads` — files the user hands to the agent.
- `~agent-<name>/.chromium-profile` — persistent browser profile: cookies, logins, extensions.
- `~agent-<name>/memory` — what the agent carries between conversations. See below.
- `~agent-<name>/skills` — the agent's own `SKILL.md` folders. See below.
- `/srv/schermes/shared` — group-writable by `agents`, setgid, for cross-agent files.
- `/srv/schermes/shared/skills` — `SKILL.md` folders every agent is shown.
- Task workers get a subdirectory under their parent's workspace and run as the parent's user.

## Runtime and toolchain

**Requirement** — Node 24 and TypeScript in strict mode for the daemon, Hono for HTTP and
WebSockets, better-sqlite3 with Drizzle for persistence, pnpm workspaces. The daemon serves no
front end at all; the client is SwiftUI, and lives in `apple/`.

Node is installed from the official tarball into `/opt/node` rather than from Debian, which
ships an older major. `install.sh` resolves the current 24.x release at install time and
symlinks `node`, `npm`, `npx` and `pnpm` into `/usr/local/bin`. pnpm is pinned to the version
in the root `package.json`'s `packageManager` field, so the installer and the committed
lockfile cannot disagree; change both together.

The host also carries the tools an agent is expected to reach for: Python with `uv`, git, ssh,
build-essential, jq, ripgrep, poppler-utils, ImageMagick, and an xterm.

## Daemon

The daemon is the only process that listens off loopback. It owns the database and the
settings today, and the agents, desktops and messaging from later slices.

- **Requirement** — one HTTP port, `SCHERMES_PORT` (default 7777), bound to `0.0.0.0`. Nothing
  else in the product may bind off loopback. `infra/desktop/check.sh` asserts that by comparing
  the whole `address:port` of every listening socket and allowing exactly that one entry.
  Comparing the address alone would let a later slice expose a VNC port and still pass.
- **Recommendation** — no build step. Node 24 strips TypeScript types on load, so systemd and
  the container both run `daemon/src/main.ts` from source. `tsc` is used only for `--noEmit`
  checking. That removes a `dist/` tree and, with it, the class of bug where a path resolved
  against the working directory works in development and breaks under systemd, which starts
  services from `/`.
- **Requirement** — Drizzle migrations are committed under `daemon/migrations/` and applied on
  boot. The folder is resolved from `import.meta.dirname`, never from the working directory.
- **Requirement** — foreign keys are **off across the migrations and on for everything after**,
  and `openDb` is the only place that decides so. That is step 1 of SQLite's own table-recreate
  procedure, and it has to happen outside the transaction: drizzle wraps each migration file in
  one, where `PRAGMA foreign_keys` is a documented no-op, so a generated recreate drops a table
  its children still reference and the upgrade fails on any database that has rows. The
  procedure's last step, `PRAGMA foreign_key_check`, runs after the migrations and is fatal — a
  daemon that booted on a referentially broken database would only write more rows into it.
- **Requirement** — durable state is `/var/lib/schermes/schermes.db`, inside the service user's
  home, alongside `master.key` and the desktop state directory. The Docker harness mounts that
  one path as a **named** volume, so a rebuild keeps the owner password, the agents, their
  threads and the encrypted settings. Named rather than bound: a fresh named volume is seeded
  from the image, ownership and modes included, so `master.key` stays 0600 under `schermes` and
  the unprivileged daemon never has to repair a directory it does not own. Agent home
  directories are outside it on purpose — a recreated container rebuilds the Linux users and
  their desktops from the surviving agent rows.

### Owner authentication

**Requirement** — one owner, one password, no user table. First contact with the API reports
`setupRequired`; a one-time setup endpoint claims the owner row; everything except health,
setup and login needs a session.

- Setup necessarily sits outside the session guard, which makes it the sharpest edge in the
  daemon. It claims the owner row with a conditional insert rather than a read-then-write, so
  it cannot be raced, and it fails with 409 once an owner exists. Otherwise it would be an
  unauthenticated password reset.
- The guard is registered before any route and denies by default. A path that is not on the
  short public allowlist needs a session, including paths that do not exist.
- Passwords are scrypt from `node:crypto`. `N=16384` is chosen to stay inside Node's default
  32 MiB `maxmem`; a larger cost parameter throws instead of hashing. Comparison is
  `timingSafeEqual` after a length check, which that function requires.
- **Requirement** — the session cookie is `HttpOnly` and `SameSite=Lax` but deliberately not
  `Secure`. schermes speaks plain HTTP by design and TLS terminates in a proxy in front of it.
  A `Secure` cookie would be dropped over plain HTTP and login would fail with no visible error.
- Sessions live in SQLite rather than daemon memory, so restarting the daemon does not log the
  owner out, and later slices get session rows they can reason about.

### Agents and their desktops

**Requirement** — an agent is a row in `agents`, a Linux user `agent-<name>`, and one X display
that belongs to it for as long as the row exists. Creating one through the API does all three.

- **Requirement** — the daemon allocates display numbers, lowest free first from `:1`. `:0` is
  reserved for a physical console. Reusing the gap a removed agent leaves keeps the numbers
  dense, which matters because the VNC port is `5900 + display` and later slices proxy it.
- **Requirement** — the name is validated against `^[a-z0-9][a-z0-9-]{0,30}$` in the daemon and
  again in the shell scripts. The daemon's check is what stops an unchecked name reaching a
  shell at all; the scripts' check is what makes them safe to run by hand.
- **Requirement** — what the owner calls an agent is its `label`, free text and cosmetic. The
  name stays the identity: the Linux user, the agents' address for each other, the tool schemas
  and every route are keyed on it, and a label reaches none of them. The app derives a name from
  the label when it creates one, and shows the derived name before the owner commits to it.
- **Recommendation** — the avatar the owner picked is a `look` column beside the label, an
  opaque token the daemon stores under the label's rule and reads none of. It exists so a phone
  and a Mac draw the same agent: a look kept in one device's defaults was a different agent on
  the other. The client owns the format (`shape:colour` today) and ignores a token it cannot read
  rather than overwriting it.
- **Requirement** — the daemon shells out to `create-agent-user.sh` and `start-desktop.sh`
  rather than reimplementing them. `start-desktop.sh` probes the display with `xdpyinfo` and
  prints `adopted` or `started`; the daemon reads that word and does not run a probe of its own.
  One implementation of the decision, in the place that already had it.
- **Requirement** — the daemon reconciles every agent on boot, which is the same call it makes
  when creating one. Desktops outlive the daemon, so a restart adopts the ones still answering
  and respawns the rest. A desktop that will not come up is logged and skipped; it does not stop
  the daemon or the other agents.
- Creating an agent whose desktop fails to start drops the row again. The Linux user and its
  home survive, so a retry reuses them, and the display goes back in the pool rather than being
  stranded by a half-created agent.
- A killed X server leaves `/tmp/.X<n>-lock` behind. The X server clears a stale lock only when
  the pid inside it is dead, and pids recycle — after a container restart a leftover lock can
  name a pid that now belongs to something else, which aborts Xvnc with "server is already
  active". `start-desktop.sh` removes the lock in the branch where the probe has already proved
  nothing is serving that display.
- `check.sh` runs its own agents on `:101`-`:103`, deliberately out of the daemon's range. Its
  agents are not in the database, and two X servers on one display is a collision, not a race.

**Restarting in the harness is not restarting on a host.** `docker compose restart` destroys the
container's pid namespace, so every desktop dies with it and the daemon respawns all of them on
boot. Only `systemctl restart schermes` on a bare host leaves desktops running for the daemon to
adopt. `infra/smoke.sh` therefore exercises adoption by starting a second daemon against the
same database while the first one's desktops are up, which is the situation systemd creates.

### Computer use and the terminal

**Requirement** — the daemon can act on an agent's desktop and shell. Both are provider-agnostic
interfaces the rest of the system calls through: the agent loop, the browser and human takeover
all end up here rather than shelling out for themselves.

- **Requirement** — one spawn boundary, `daemon/src/exec.ts`. Every module above it takes it as
  a parameter, so unit tests assert on the argument list a request produces without spawning
  anything. It caps collected output, because a command the agent chose could otherwise pour
  `/dev/urandom` into the daemon's heap, and truncation is reported in the output the caller
  sees rather than silently.
- **Requirement** — every invocation carries `HOME`, `USER`, `LOGNAME`, `DISPLAY` and
  `XAUTHORITY` explicitly, because `sudo` strips the environment. `env --chdir` sets the working
  directory to the agent's home and must come before the assignments, or `env` reads it as the
  command to run.
- **Requirement** — a screenshot crosses the API as base64 PNG in the JSON body, not as an image
  response. The model provider wants exactly that encoding for a vision message, so returning
  bytes would mean encoding them again one layer up, and every action then shares one response
  shape. The bytes never reach the logger: routes log the action name and the exit code, never
  the result, and `redact()` has no `Buffer` branch, so a result object passed to it would
  explode into per-byte JSON.
- `scrot -` writes to `/dev/stdout` **by path**, which the agent user cannot open across the uid
  change, so the capture lands in the agent's own home and `cat` returns it over the inherited
  descriptor. Typed text and clipboard writes travel on stdin — `xdotool type --file -` and
  `xclip -i` — so free text never needs shell quoting and never appears in the process list.
- `xclip` forks into the background to own the selection, which is what makes the clipboard
  persist. Its stdio is redirected inside the shell; otherwise that fork holds the daemon's
  pipe open and the call never returns. An empty clipboard makes `xclip -o` exit non-zero, which
  the daemon reports as empty text rather than as a failure.
- **Requirement** — a command's timeout is enforced by GNU `timeout` inside the sudo, not by
  killing the process from Node. `timeout` runs the command in its own process group and signals
  the group, so a command that spawned children does not leave them behind; killing `sudo` from
  outside would not reach them. Exit 124 is reported as `timedOut`. The daemon keeps a longer
  timer as a backstop against a wedged `sudo`, nothing more.
- A background command is `setsid --fork bash -c 'exec >/dev/null 2>&1 </dev/null; ...'`. The
  redirect has to be an `exec`, not a redirect on the command: bash keeps its own descriptors
  for its whole lifetime, so redirecting only the command leaves the shell holding the daemon's
  stdout pipe until the detached job finishes, and the request never completes. `close` fires on
  stdio EOF, not on exit, so the daemon also drops the pipes two seconds after a process exits
  rather than waiting on a grandchild forever. A background command's output is the caller's to
  redirect; the daemon does not collect it.
- **Requirement** — actions are validated in the daemon before anything reaches a shell:
  an unknown action, a coordinate outside the screen, a button that is not 1-3, or a keystroke
  that does not look like `Return` or `ctrl+shift+t` is a 400.
- **Requirement** — the model, and the `/computer` route, work in a view of the display rather
  than the display itself. A screenshot is shrunk to fit 1280x800 with `magick -resize WxH!`,
  coordinates are bounded by that view, and `computerCommand` maps each one back onto the
  display per axis, the exact inverse of the resize. Providers downscale a larger image on their
  side without telling the model, so sending the display as is would put its clicks in the wrong
  place. `config.ts` derives the view from `SCHERMES_GEOMETRY`; at 1280x800 or below the two
  are the same and nothing is resized.
- `start-desktop.sh` adopts a running desktop only at the configured geometry and restarts one at
  any other size, because the mapping assumes it. xdotool clamps, so a coordinate that rounds
  past the edge lands on it.
- **Deferred** — persistent terminals. One command at a time is the contract; a tmux-backed
  session is a later slice if it is ever needed.

### The browser

**Requirement** — the agent reads pages from its own Chromium, the one on its desktop, not from
a second browser. `web_fetch` sees only what the server sends and the `computer` tool sees only
pixels; the gap between them is a page that builds its content with scripts or behind a login.
The `browser` tool fills it through the DevTools Protocol of the Chromium already running.

- **Requirement** — every Chromium on a display listens on `127.0.0.1:(9222 + display)`. The
  flag is set once, in `/etc/chromium.d/schermes`, from `DISPLAY`, so the dock launcher, a
  `run_command chromium …` and the daemon's own start all land on the same port. Chromium honours
  it only with an explicit `--user-data-dir`, which every launcher here passes. `debugPort()` in
  `daemon/src/browser.ts` is the same arithmetic; the two must keep agreeing.
- **Requirement** — same browser, same profile: a navigation the tool makes is what the owner
  sees over VNC, a login the owner does by hand is one the tool's next `read` uses, and human
  takeover is unchanged. A headless browser service (Steel, Browserless) was considered and
  rejected for exactly this: it would be a second Chromium with a second cookie jar that the
  owner cannot watch.
- **Requirement** — three actions, validated in the daemon: `navigate` (http(s) only, waits for
  load, returns the rendered text), `read` (the current tab's `innerText`, with title and URL)
  and `evaluate` (an expression, awaited, returned by value). `evaluate` is the general
  primitive — links, forms, clicks — and is no privilege the agent lacked: it already has a shell
  and sudo. Results are clipped to the observation budget; events carry the action, the host
  and the size, never the text.
- **Requirement** — a Chromium that is not running is started by the tool, detached and as the
  agent, through the same `commandArgv` a background `run_command` uses, and the port is polled
  until it answers. One tool call instead of a `run_command`, a guess at a sleep and a retry.
- **Requirement** — no `--remote-allow-origins`. The daemon's WebSocket client sends no `Origin`
  header, which is what Chromium accepts by default; allowing origins would let a page open in the
  browser reach its own debugging port.
- The port is loopback but not per-user: any local process, another agent's included, can reach
  it. That is inside the stated boundary — the machine, not the agent user — and is the same
  standing `sudo` already gives every agent.
- A task worker is not offered the tool. It shares its parent's Chromium, and two loops steering
  one tab is the two-loops-one-mouse problem the computer tool already avoids.
- `Page.loadEventFired` is waited for with a timeout and the page is read either way: a page that
  keeps a request open never fires load, and what has rendered is still the answer.
- **Deferred** — tab selection (the first page target wins), an accessibility tree, and a
  screenshot from CDP rather than `scrot`. Each is one more action when a model asks for it.

### The model provider

- **Requirement** — one seam, one implementation. `Provider` is a function from a transcript
  and a set of tool definitions to a reply, and `openAiProvider` is the only thing behind it:
  chat completions with tool calling and vision, against the base URL, model and API key the
  owner stored. There is no provider registry and no second client; a different endpoint is a
  different base URL.
- **Requirement** — tool definitions are generated from the same constants and the same action
  list the validators enforce, in `computer.ts` and `terminal.ts`. A separate schema file would
  be a second copy of the vocabulary and would drift; a test asserts the advertised bounds are
  exactly the bounds the parser accepts.
- **Requirement** — a screenshot travels as base64 PNG from the tool layer to the model without
  being re-encoded, and it is stored that way, so the transcript survives a restart.
- **Recommendation** — the image rides in its own `user` message rather than in the `tool`
  message that reported it. An assistant message carrying tool calls must be followed
  immediately by one tool message per call id and nothing else, so with two tool calls in a
  turn an image placed inline would split the pair and a strict endpoint would reject the whole
  transcript. Every tool result for a turn is emitted first, then the images.

### The agent loop

- **Requirement** — the loop is an in-process async task and the database is the durable state.
  Every transition is written the moment it happens, not at the end of the turn, so a reader —
  or a later daemon — sees the same history the loop does.
- **Requirement** — states are `idle`, `thinking`, `using_computer`, `using_terminal`,
  `waiting_for_user`, `waiting_for_agent`, `failed` and `completed`, with an explicit table of
  legal transitions. A permanent agent ends a turn in `waiting_for_user`, or in
  `waiting_for_agent` when it spent the turn writing to another agent; `completed` is the
  terminal state of a task worker and nothing reaches it yet. `failed` is reachable from every state, so the catch
  that ends a broken turn never has to bypass the table, and both terminal states lead back to
  `thinking`, which is what lets an owner send a second message.
- **Requirement** — a tool that refuses or fails becomes an observation the agent can react to.
  Only the model itself failing ends the turn as `failed`. A turn is capped at a fixed number of
  steps so a model that never stops calling tools fails instead of running forever.
- **Requirement** — execution events are structured and small: a tool call, a tool result, a
  state transition, a failure. They carry what was asked for and how it turned out, never the
  screenshot bytes, never command output in bulk, and never model reasoning.
- **Decision** — the model call is streamed, and the reply so far lives in process memory for
  exactly as long as the agent is `thinking`. `GET /api/agents/:name/live` reads it, the UI
  polls that once a second on an agent's own thread, and the stored message replaces it. The
  reasoning a model streams is shown there and nowhere else: it is not stored, not replayed to
  the model, and not an event.
- One turn per agent at a time, owned by a runner rather than a route closure: both the HTTP
  routes and `send_message` inside a turn start turns through it.
- **Requirement** — the transcript carries a **bounded number of screenshots**. Only the last
  few images are sent; older ones stay in the transcript as text saying they are no longer
  visible, so an agent knows the screen it remembers is stale rather than reasoning about a
  picture it can no longer see. The tool result naming each dropped screenshot is kept: it is
  small, and it is the only record the call happened. Replaying every stored image grew each
  request with the conversation until a real endpoint would refuse it.

### Context compaction

**Requirement** — a thread past a budget is replayed as a summary plus a verbatim tail. Bounding
the screenshots and trimming the older tool results bounds what one *step* costs, but every
message ever written was still replayed, so a thread that runs for a week outgrows any context
window on its text alone.

- **Requirement** — compaction **never rewrites history**. A summary is a row in `summaries`
  naming the message ids it stands for; the `messages` rows are untouched, `listMessages` keeps
  returning all of them, and the UI is unaffected. A second pass only reads what no summary
  covers yet, so nothing is summarised twice.
- **Requirement** — a summary belongs to one agent, not to the thread. Each agent in a group
  sees its own projection — its own tool traffic and nobody else's — so a shared summary would
  replay another agent's work as this one's.
- **Requirement** — the cut lands **between turns**. A tail beginning inside one hands a strict
  OpenAI-compatible endpoint either an assistant message whose tool calls nothing answers or a
  tool result answering nothing, and it rejects the whole request. The pass only ever cuts where
  every call this agent made has been answered; `assertEveryCallAnswered` in `loop.test.ts` is
  the contract, and its other half is that no kept tool result is left orphaned.
- **Requirement** — once per turn, in front of the first step, at the same point as the home
  load, and the summary rides after the stable system text as a message of its own. Compacting
  between steps would change the request head mid-turn and throw away the prompt cache.
- **Recommendation** — the budget measures the characters `transcript` would send after the
  trimming, not the row count: trimmed is what the request costs. Screenshot bytes are left out
  because `MAX_REPLAYED_IMAGES` already bounds them and counting them would put every
  desktop-driving agent permanently over a budget no cut could bring it back under. Where to cut
  is then chosen on raw content length, which overstates a trimmed observation and so lands the
  tail under the target rather than over it.
- **Recommendation** — a summary that cannot be written costs the agent the compaction, not the
  turn: the same rule the home load follows. The request that follows is oversized, which is the
  endpoint's answer to give, and the next turn tries again. The summariser runs on the turn's own
  provider with its own system text and no `onDelta`, so what it writes is never mistaken for the
  agent speaking.
- **Requirement** — the owner can compact on demand, `POST /api/agents/:name/compact` or
  `POST /api/conversations/:id/compact`, budget or no budget. It is the same summariser with a
  different cut: **everything** since the newest summary is folded in and nothing is kept
  verbatim, so the next turn opens on the summary and what the owner writes after it. One summary
  per agent in the thread, on that agent's own projection, like the turn's pass. Refused with a
  409 while any participant is mid-turn, for the reason a rewind is: the loop writes every result
  before it asks for more, so *between* turns every call is answered and the whole stretch is one
  legal cut, and inside one it is not. The answer says how many rows each agent's summary now
  stands for; zero is an agent with nothing new, and costs no model call.
- **Deferred** — compacting an agent's memory files, and any retention of the summarised rows.
  Nothing is deleted; the summary is a shorter *reading* of rows that all stay.

### Memory and skills

**Requirement** — an agent remembers across conversations, and carries reusable instructions it
can write itself. Both are files in its home rather than tables, because an agent already owns a
filesystem, a shell and `ripgrep`, and a row would be a second place to look.

- **Requirement** — `~/memory/MEMORY.md` is loaded into the system prompt at the start of every
  turn; `~/memory/<date>.md` is appended to and never loaded. `create-agent-user.sh` creates both
  directories, so the boot reconcile that already runs it gives them to agents created before
  this existed. No second reconcile path.
- **Requirement** — the load is one `sudo -u agent-<name>` invocation per turn, not one per file:
  a script that prints the head of `MEMORY.md` and the head of every `SKILL.md` it globs, with
  sections announced by a marker generated per call so nothing a file contains can forge one.
  The daemon parses; the shell finds and clips.
- **Requirement** — once per turn, not once per step. Everything injected this way lands after
  the stable system text and is byte-identical across the steps of one turn, which is what keeps
  the prompt cache warm.
- **Recommendation** — a home that cannot be read costs the agent its memory for that turn, not
  the turn. The alternative is an agent with an unusual home that can never take a turn at all.
- **Requirement** — `remember` exists because a model does not save unless a tool makes saving a
  one-step act. It takes a scope (`lasting` for `MEMORY.md`, `today` for the daily note) and one
  line, flattened. The line goes in on stdin and the path is derived from the agent's home, so
  nothing the model writes is ever an argument, let alone a path.
- **Requirement** — the prompt carries a skill's `name` and `description` from its frontmatter
  and the path to read, never the body. A folder with no frontmatter is still a skill and its
  folder name stands in. No skill registry table: the filesystem is the registry.
- **Requirement** — a task worker gets neither and cannot call `remember`. It knows its brief and
  nothing else, it has no Linux user of its own, and a memory written by a throwaway would be
  written into its parent's home under its parent's name.
- **Deferred** — memory search beyond what `ripgrep` through `run_command` already gives, and
  `MEMORY.md` past its cap keeps its head, so lines added after that are written but not loaded.
  Summarising the daily notes is no longer deferred *for want of a mechanism*: the cron slice
  decided the daemon seeds no nightly job, and an agent that wants one writes it with
  `schedule_task`. See **Scheduled tasks** below.

### Profile and the interview

**Requirement** — an agent is created as a name and an avatar, and nothing tells it what it is
for. It finds out by asking: its first turn is an interview of the owner, and what it learns is
its **profile**, a Markdown text in its system prompt every turn after.

- **Requirement** — the profile is a column on `agents`, not a file in the home. The owner reads
  and edits it from the app, which means a route, and a task worker has no home to keep one in.
  `set_profile` replaces it whole; the owner's `PATCH /api/agents/<name>` does the same, and a
  blank clears it, which puts the agent back to asking.
- **Requirement** — `ask_owner` takes up to four questions, each with optional choices, and the
  owner may always type instead of picking. **The questions travel in the call's own arguments**,
  which the transcript already stores: the client reads them from the newest unanswered call and
  answers as an ordinary owner message. No table, no route, no queue, and a client that does not
  know the tool shows the call folded like any other and the owner answers in the composer.
- **Requirement** — a call to `ask_owner` **ends the turn** in `waiting_for_user`, whatever else
  the reply asked for. The tool text says so, and a model told so still sometimes goes on; the
  loop stops it where the approval flow relies on the model stopping itself. Every call in that
  reply still gets its result first, so the transcript is one a strict endpoint accepts.
- **Recommendation** — the interview opens with one free-text question, what the owner wants
  the agent for in their own words, and the focused questions with options follow from that
  answer. Four generic questions up front asked the owner to fit their idea into the agent's
  categories; one open question lets the model build the categories from the idea.
- **Requirement** — the interview starts the way a routine does: `POST /api/agents` appends the
  kickoff as an owner message into the new agent's thread and starts a turn. With no provider
  configured nothing can run, so the system prompt of a profile-less agent tells it to ask before
  any other work, and the owner's first message gets the interview instead. Creating an agent
  *with* a profile skips it, which is also what the API tests do.
- **Requirement** — the system text reads the profile from the row at the start of the turn,
  not from the agent passed in: `set_profile` writes mid-turn, and the next turn has to carry it.
- **Recommendation** — a task worker gets neither tool. It is one brief, and its parent is who
  it would be interviewing.

### Scheduled tasks

**Requirement** — an agent runs without its owner. Until this existed the only thing that could
start a turn was a message arriving, so an agent could do nothing at all while the owner was
asleep. A heartbeat is a schedule with a fixed prompt, **not a second mechanism**.

- **Requirement** — a `schedules` row per job: the agent it belongs to, the cron expression, the
  prompt, whether it is paused, and when it is next due. `next_run_at` is the whole clock; there
  is no in-memory timer per job and nothing to rebuild at boot.
- **Requirement** — **a run missed while the daemon was down runs once, not once per missed
  slot.** That is a property of the column, not a catch-up pass: the tick fires every row that is
  due and then advances `next_run_at` from *now*, so a laptop closed over a weekend wakes its
  agents once each. The same rule makes an expression finer than the tick fire once per tick.
- **Requirement** — delivery is **the existing messaging path and nothing else**: `appendMessage`
  into the agent's own thread with the owner, then `runner.start`. A busy agent picks the row up
  through the same drain a peer's message goes through, which is why this needs no queue and no
  second runner.
- **Requirement** — the delivered row is written as **the owner's**, with no sender. An
  agent-authored one is excluded by `notSentBy` in `pendingConversation`, so the agent would
  never wake on it, and it would be counted by `agentChain`, so a handful of fired jobs would
  refuse the agent's next `send_message`. The message names the schedule it came from in its
  text instead, so the agent does not read it as the owner typing at four in the morning.
- **Requirement** — one tick, `setInterval` at `SCHEDULE_TICK_MS`, started in `main.ts` next to
  the rest of the boot. Its body is **synchronous** and advances the column *before* it starts
  the turn: `runner.start` returns at once, and an await in the due loop would let the next tick
  see the same un-advanced rows and fire them twice.
- **Requirement** — **cron expressions only**, parsed by `croner`. The model translates natural
  language before it calls the tool, and the tool description is where it is told so. One small
  dependency rather than a hand-written parser, whose edge cases — `L`, ranges with steps, day-of-
  week *and* day-of-month — are exactly what a scheduler is judged on.
- **Requirement** — an expression with no next run (`0 0 30 2 *`, February the 30th) is refused
  at validation, and a row that stops having one is dropped rather than left permanently due.
- **Requirement** — the agent's own schedules ride in the **same once-per-turn tail** as memory
  and the skills index, so it knows what it has already set up. `homeTail` is the one place; a
  second per-step load would change the request head mid-turn and throw the prompt cache away.
- **Requirement** — a task worker is offered none of the tools and falls through to the
  unknown-tool answer, like it does for `remember`. It is one job that reports back and is never
  started again, so a standing job of its own would fire into nothing.
- **Recommendation** — pause is **its own tool** taking a boolean rather than an argument on
  `cancel_schedule`. One tool covers both directions, and the alternative makes the one
  irreversible verb in the set ambiguous — a `cancel` that does not cancel is a bad thing for a
  model to be holding.
- **Recommendation** — every lookup is scoped to the agent the caller already named, in the
  tool and in the route alike. A schedule id is a small integer a model can guess, and the scope
  is what stops one agent pausing another's job.
- **Deferred** — a schedule addressed to a group conversation. The owner thread is where the
  owner already reads, and a job that fired into a group would start a turn for every agent in
  it. The default stands until somebody needs otherwise.
- **Deferred** — a nightly job the daemon seeds by default to summarise `~/memory/<date>.md`
  into `MEMORY.md`, which is the open question the memory slice left here. The mechanism now
  exists — `schedule_task` plus slice 2's `SUMMARY_PROMPT` — and that is what the question was
  waiting on; seeding one would need a creation-time path, a boot-reconcile path and a
  summariser that rewrites a file rather than a transcript. An owner or an agent that wants it
  writes the schedule.
- **Requirement** — a schedule the tick throws away because **its cron has no next run left**
  records a `schedule_dropped` event, so a job that stopped existing on its own leaves a trace in
  the agent's activity log rather than just ceasing to appear. The tick's *other* drop — a row
  whose agent is gone — has none and can have none: `events.agent_id` is `NOT NULL` and references
  `agents`, so there is no row to hang the event on. That case is also unreachable through the
  API, which has no route that deletes an agent.

### Web search and fetch

**Requirement** — an agent that needs a fact off the internet had to drive a browser: launch
Chromium in the background, screenshot it and read pixels. That is three tool calls and an image
per page against one tool call and some text. `web_search` finds a URL, `web_fetch` reads it.

- **Requirement** — search is **Brave**, and the response parser is Brave's shape and nothing
  else. The key travels as the `X-Subscription-Token` header rather than in a JSON body, which
  keeps it out of anything that logs a request, and `web.results[]` is already
  `{title, url, description}`, which is the answer the tool has to give. The endpoint is a
  setting so it can be pointed at a proxy or a mirror, **not** so a differently shaped API can be
  swapped in.
- **Requirement** — the endpoint and the key are **settings rows**, and the key is AES-GCM
  encrypted with the master key exactly like the provider key. `GET /api/settings` answers with
  `searchKeySet` as a boolean, and the error body an endpoint echoes back goes through
  `withoutKey` before it becomes an observation, an event or a log line — the same reason
  `provider.ts` strips it there.
- **Requirement** — a search with **no key configured is an observation** telling the agent so,
  not a crash and not an empty list. A key nobody has set is the normal state of a fresh install.
- **Requirement** — `web_fetch` returns **readable text**, not markup. `html-to-text` does the
  conversion: there is no HTML parser in the standard library, no installed dependency that does
  it, and a regex that strips tags silently hands the model a page of CSS. Scripts, styles,
  navigation and footers are dropped and links keep their words rather than their hrefs.
- **Requirement** — **the SSRF guard**. A URL the model chose is checked against loopback,
  link-local, private, CGNAT, multicast and reserved ranges, by `net.BlockList`, twice: once at
  parse time against an address written into the URL, and once against every address the name
  resolves to. `BlockList` maps an IPv4-mapped IPv6 address onto the IPv4 rules itself, so
  `[::ffff:169.254.169.254]` is caught by the `169.254.0.0/16` entry — adding `::ffff:0:0/96` as
  a rule of its own would block every IPv4 address on the internet instead.
- **Recommendation** — **redirects are not followed**. A 3xx comes back as the target URL in an
  observation, so the agent's next call is an ordinary `web_fetch` that re-enters the guard with
  the new host. Following a hop and re-checking it costs more code and is strictly worse: this
  way the guard can never be walked past by a chain.
- **Requirement** — two caps, for two reasons. `MAX_PAGE_BYTES` stops a stream nobody asked for
  being buffered at all, and the extracted text is then clipped to `MAX_OBSERVATION_CHARS` like
  every other observation. A response whose content type is not text, JSON or XML is refused
  rather than converted.
- **Recommendation** — a **task worker is offered both tools**, which makes them the only ones it
  shares with a permanent agent. `remember` and the schedule tools are withheld because a worker
  has no home and is never started again; neither applies to an HTTP request the daemon makes on
  its behalf, and "go read this and report" is the job a worker exists for. It costs nothing
  besides: a worker already has `run_command` and therefore `curl`.
- **Requirement** — the `tool_result` event carries **the host and the status, never the page**.
  An event is a trace, not a second transcript.
- **Deferred** — the guard is **defence in depth, not a new boundary**. The daemon and the agent
  Linux users share one network namespace, so `run_command` plus `curl` already reaches
  `127.0.0.1:7777` and anything else on this host. What the guard buys is that the *daemon* does
  not become the proxy for a URL that arrived from somewhere other than the agent's own judgement
  — a search result, a page it was told to read. Making it a real boundary means giving the agent
  users a network namespace of their own, which is its own task.
- **Deferred** — the DNS rebinding window. `fetch` resolves the name a second time after the
  guard has checked it, so an answer that changes in between is not caught. Closing it means
  connecting to the address already checked and carrying the name in a `Host` header, which needs
  a dispatcher `fetch` does not expose.
- **Requirement** — the search key is a field on the settings screen with the provider key's
  write-only behaviour: `searchKeySet` says whether one is stored, the field is never filled in
  from a response, and a blank field is **left out of the body** rather than sent as `''`, which
  the daemon would write. The endpoint beside it is not write-only and its placeholder says that
  empty means the built-in Brave endpoint, not "unconfigured".

### MCP

**Requirement** — the owner points the daemon at MCP servers and their tools are offered to the
model alongside the built-in ones. `@modelcontextprotocol/sdk` is the client, **stdio and
streamable HTTP**, and nothing about the protocol is hand-rolled: it is a moving target, and the
SDK is the only reason this is one piece of work rather than three.

- **Requirement** — a stdio server **runs as the agent's own Linux user**, through the `asAgent`
  prefix, never as `schermes`. The daemon's user owns the sudoers rules and the master key, and
  an MCP server is somebody else's code. The env block rides in as operands to the `env` that
  `asAgent` already builds, which is the only way through: neither sudoers rule grants `SETENV`,
  so `sudo` strips the environment it was handed.
- **Requirement** — the servers are **one settings row**, `mcp.servers`, holding the whole list
  as JSON and encrypted with the master key like the provider key. A stdio server's `env` block
  and an http server's headers are where an API key goes, so the row is encrypted as a whole
  rather than field by field. `GET /api/mcp/servers` answers with each server's identity and the
  *names* of the secrets it carries, never their values.
- **Requirement** — never reading a secret back must not force the owner to retype one.
  `PUT /api/mcp/servers/<name>` adds or changes **one** server and `DELETE /api/mcp/servers/<name>`
  removes one; both read the row, edit it by name and write it back through the loader's own parse,
  which is also what holds an append to the server cap. On the per-server `PUT` a secret sent blank
  keeps its stored value and a key left out is removed, merged in **before** the parse so a spec
  that can be stored is still a spec that can run. The replace-all `PUT /api/mcp/servers` stays as
  the whole-list write.
- **Requirement** — tools are namespaced **`mcp__<server>__<tool>`**, and a server name may not
  contain an underscore, so the name reads one way however either half is written. Routing is the
  session's own map from the namespaced name, never a split: a lookup cannot be ambiguous, and a
  split on a server called `a__b` would be.
- **Requirement** — **connected lazily, per turn, and dropped when the turn ends.** A server
  nobody's agent has called is not a process the daemon starts at boot and keeps. Pooling with an
  idle timeout would buy a reconnect per turn and cost a lifetime nothing owns — an idle `npx`
  per configured server, surviving every turn that made it. Dropping is cheaper and has no state
  to get wrong. The close is in a `finally` around the whole turn, because a failed turn leaks a
  child process just as happily as a successful one.
- **Requirement** — connecting happens **once, in front of the first step**, with the system text
  and the compaction: every step of a turn is handed the same tool list, so the request head the
  prompt cache keys on does not change between them. The tools are sorted by name inside each
  server and appended after every built-in tool, so the order is the same turn after turn.
- **Requirement** — a server that is down, slow or misconfigured **costs the agent that server's
  tools and not its turn**, the rule every other tool follows. A settings row that cannot be read
  at all costs it every MCP tool and still not the turn. A result is an observation like any
  other, clipped to `MAX_OBSERVATION_CHARS`; a result the server marks as an error is an
  observation the agent can read rather than a failed run.
- **Requirement** — an error on its way to the agent or the log is **stripped of the values the
  owner stored** for that server, through the same `withoutKey` the provider and the search key
  use. A transport failure can carry the request back with it.
- **Recommendation** — non-text content is **named, not shown**. An image an MCP tool returns
  becomes `[image content, which is not shown here]`: the screenshot path belongs to the computer
  tool, which has a display behind it and a replay budget.
- **Recommendation** — the connection test is **agent-scoped**,
  `POST /api/agents/<name>/mcp/<server>/test`, and goes through the same `openMcp` a turn does.
  An owner-scoped test would have to spawn a stdio server as `schermes`, which is exactly the
  thing this section forbids; one connect path means a test cannot be right about a spawn a turn
  gets wrong.
- **Recommendation** — a **task worker is offered no MCP tools**, which makes the web pair still
  the only ones it shares with a permanent agent. A worker has no Linux user of its own, so a
  stdio server would run as its parent, and it is one job that reports back and is never started
  again.
- **Deferred** — running as the agent's user is **a separation of duties, not a boundary**, for
  the same reason the SSRF guard is defence in depth. `%agents ALL=(ALL) NOPASSWD: ALL` is in the
  [privilege model](#privilege-model) on purpose, so a server started as `agent-alpha` can become
  any other user on the machine. What the rule buys is that the daemon does not hand its own
  process, environment and file ownership to third-party code by default. The env block travelling
  in argv is visible in `/proc` to every user on the box and folds into the same ceiling. Closing
  either one means the agent users stop being able to sudo, which is its own task.
- **Deferred** — no OAuth. An http server is reached with the headers the owner configured and
  nothing else; the SDK's `authProvider` needs a redirect the daemon has nowhere to send.
- **Deferred** — resources and prompts. Only `tools/list` and `tools/call` are used, because a
  tool is the one MCP concept the agent loop already has a shape for.
- **Requirement** — the owner's panel writes the server list as **a JSON array in a textarea**,
  not a form. A server is an object of two shapes with a free-form env block or header set, so a
  form would be a second copy of `parseMcpServers` in the browser that could disagree with it; the
  textarea posts what the owner wrote and the daemon's own parse is the only validator, reporting
  its error as the panel's error. The box **does not start filled in from `GET`**, for two reasons
  that both have to hold: the secrets are never read back, and `summarise` joins a stdio server's
  `command` and `args` into one string that cannot be split back apart reliably. Round-tripping a
  `GET` into a `PUT` would write every server with empty secrets, so the panel says in as many
  words that a save replaces the whole list.
- **Requirement** — the **test-as** select offers permanent agents only. A stdio server runs as
  the agent's own Linux user and a task worker has none, so testing as one would spawn the server
  as its parent and be right about a connection a turn never makes.

### Messaging

- **Requirement** — a conversation **is its participant set**. One agent is that agent's own
  thread with the owner, two is the thread those two share, more is a group; the owner is in
  every conversation and is never listed as a participant. Look-up is find-or-create, so
  `send_message` and the group route land in the same row rather than growing a thread per
  message. A group of exactly two and the direct thread between those two are deliberately the
  same conversation: they are the same set of people.
- **Requirement** — an owner's message may carry an image, stored on the row like a screenshot
  observation is. It reaches every agent in the thread as a user message with the picture, and
  it counts toward `MAX_REPLAYED_IMAGES` with the screenshots: both are bytes in the request,
  and an old picture is one the model has already looked at.
- **Requirement** — every message carries the name of the agent that wrote it, and a missing
  sender means the owner. The name is stored rather than an agent id: names are unique and
  immutable, there is no delete endpoint, and the transcript needs the name anyway.
- **Requirement** — reading a thread over HTTP is **paged**, because a thread carries base64
  screenshots and the whole of one is not a response anybody wants. `?limit=` (50 by default,
  200 at most) and `?before=<message id>` walk it backwards; no cursor is the newest page,
  which is where a chat view opens. Pages come back oldest first, images inline, and a page
  shorter than the limit is the start of the thread — the only end marker a reader needs, which
  is why nothing counts the rest. **A page is a window on the rows, not on the turns**: a
  boundary can land inside a turn and hand back a tool result whose assistant message is on the
  page before it. Nothing a reader gets becomes a model request, so that is a rendering problem
  for whoever draws the thread, and the other half is on the page it is walking back to anyway.
  Paging is a **reader's** view and lives in `pageMessages`,
  never in `listMessages`: the turn's high-water mark, the transcript, the interrupted-call
  repair and the runaway guard are all wrong on a truncated history, and a page boundary
  between an assistant message and its tool results is the exact shape a strict endpoint
  rejects.
- **Requirement** — the transcript is a per-agent projection of the shared conversation. What
  the agent wrote itself is replayed verbatim; everything else becomes a `user` message reading
  `Message from <who>:` when it was written to this agent, or `<who> said here, to the owner:`
  when it is another agent's own reply in a shared thread, so a reply is not mistaken for a
  question that needs answering. Another agent's tool traffic is dropped along with the tool calls that
  asked for it, because half of an assistant/tool pair is a transcript a strict endpoint
  rejects.
- **Requirement** — anything the agent did not write is **buffered until the transcript is
  between turns**, exactly like a screenshot. Delivery to a busy agent means a foreign row can
  be stored at any point of a turn and stays there, so on the next read it would otherwise sit
  between an assistant message and its tool results.
- **A message to a busy agent is taken, not refused.** There is no 409 left: nothing would
  retry it, because the sender may be another agent inside a turn. The message rows are the
  queue — a running turn looks for arrivals before it releases the agent, and the check and the
  release are one synchronous block so nothing can land in the gap. A message that arrives
  mid-turn is excluded from the transcript of the turn already under way and answered by the
  next one.
- **An agent that wrote to another one ends its turn** in `waiting_for_agent` rather than
  blocking inside it. Blocking would hold a process across an unbounded wait, and a restart
  during that wait leaves nothing to resume; the reply is a durable row, so being woken by it
  costs nothing and survives a restart.
- An answer is addressed to nobody, so it wakes **only** an agent standing in
  `waiting_for_agent` for exactly that reply. Without that rule two agents in a group would
  answer each other forever off one message from the owner.
- **Requirement** — two agents cannot write to each other forever. A conversation counts the
  messages agents have passed since the owner last spoke in it, and `send_message` refuses past
  the cap with an observation the model can act on. It is a query over the rows rather than a
  counter on the message, so nothing has to be threaded through the loop. Known ceiling: an
  agent-to-agent thread the owner never posts to reaches the cap permanently, and a post from
  the owner clears it.

### Task workers

- **Requirement** — a task worker is a **row in `agents` with a parent**, not a table of its
  own. Everything a turn needs already keys off an agent row: the loop, the transition table,
  the event log, and `conversation_participants`. What a worker does not get is a Linux user, a
  desktop or a display: it runs as its parent's own Linux user, in a directory under that
  agent's workspace, so it needs no new sudoers rule. `parent_id` is what tells the two apart,
  and the desktop reconcile skips anything that has one — `start-desktop.sh` takes three digits,
  and a worker's `display` is a placeholder above that range because the column is unique.
- **A worker gets `run_command` and nothing else.** It shares its parent's X display, so giving
  it the computer tool would put two loops on one mouse. It cannot spawn workers of its own and
  nobody can `send_message` to it: it reads one brief, does the job and answers once.
- Its brief is the first message of a thread of its own, so it never sees the conversation it
  was spawned out of, and the daemon derives its working directory from its name rather than
  letting the model choose a path. The directory is created before the row exists, so no worker
  is ever left pointing at a directory that is not there.
- **Requirement** — the result comes back **through the messaging path**: the worker's final
  reply is written as a message from it into the thread its parent was in when it spawned it,
  and the parent is started on that thread. A parent that is mid-turn therefore picks the result
  up through the same drain a peer's message goes through, rather than losing it. A worker that
  fails sends the same kind of message saying so, because a silent worker leaves its parent
  waiting forever.
- A worker ends in `completed`, which is what that state is for. Its parent ends the spawning
  turn in `waiting_for_task_worker` rather than blocking, for the same reason it does not block
  on `send_message`. Known ceiling: unlike `waiting_for_agent`, that state does not gate the
  wake — a worker's result is a `user` row and wakes a parent in any state — so it is load
  bearing only for restart recovery and for what the UI shows.
- **Requirement** — two caps, because an agent that can spawn workers is the first thing here
  that can multiply. The **loop cap** is the number of turns running at once and lives in the
  runner, which holds the only process-local view of what is running; it is per process, so two
  daemons against one database allow twice as many. The **worker cap** is the number of live
  workers and is a query over the rows. A request above a cap fails with the cap named: a 429
  for the owner over HTTP, an observation the model can act on for a tool call. Spawning also
  passes through the runaway guard `send_message` uses, since a worker's result counts as an
  agent-authored message in that thread.
- **Requirement** — boot marks every worker that was still running as `failed` and writes its
  parent a message saying the daemon restarted, before the pass that rescues stranded agents:
  the parent is only stranded once its worker has been given up on, and that message is what the
  rescue looks for.

### Human takeover

- **Requirement** — the owner watches an agent's desktop over a **WebSocket on the one exposed
  web port**, behind the same session guard as every route, proxied to that agent's Xvnc on
  `127.0.0.1:(5900 + display)`. The proxy adds no listener of its own: it hangs off the HTTP
  server's upgrade event, so the check that only the web port is bound off loopback still holds.
  Xvnc lets in anyone who can reach it, which is why the guard is in the daemon and why the
  proxy is the only route in from off the machine. A task worker has no desktop of its own, so
  there is nothing to connect to and the upgrade is a 404.
- **Requirement** — **input ownership is per desktop and lives in the daemon process**, the way
  the loop cap does, not in a column. A hold is a human at a live socket; a daemon that dies
  takes every viewer with it, so a persisted flag would outlive the person behind it and boot
  would only have to clear it again. What survives a restart is the agent's side of it: the
  refusal in its transcript, the `control` event in its history, and the state it landed in.
  Known ceiling: a hold with a closed browser behind it stays held until the owner returns it or
  the daemon restarts, because nothing ties it to the viewing socket.
- **Requirement** — while the owner holds a desktop, **every computer action against it is
  refused**: the agent's tool call becomes an observation it can act on, and the `/computer`
  route answers 409. The refusal ends that turn in `waiting_for_user` — every call in the reply
  still gets its tool result first, because a reply answered by fewer results than it asked for
  is the broken shape restart recovery exists to repair. Returning control does not restart the
  turn; the owner's next message does, the same answer restart recovery gives.
- Taking control **does not interrupt a tool call already in flight**. There would be no result
  to hand back, and a half-finished drag would leave a mouse button down; a computer action is
  bounded at 60s anyway. It refuses what the agent asks for next.
- **`run_command` is not gated**, because it is not input to the display: a human looking at a
  screen should not stop the agent writing files or running a build. Known ceiling: `DISPLAY` is
  exported into every command, so an agent that runs `xdotool` itself is not stopped by the gate.
  Closing that means gating on what a command does rather than on which tool asked.
- Known ceiling: the proxy is a byte pipe with no backpressure and no RFB parsing, so a viewer
  that sends pointer and key events while it does not hold control is stopped by its own client
  rather than by the daemon. Enforcing view-only would need to filter RFB message types 4 and 5
  out of a stream that is not message-framed.

### Stopping a turn

- **Requirement** — the owner can end a turn, `POST /api/agents/:name/stop`. Without it an
  agent that had gone in circles ran until `MAX_STEPS`, two hundred model calls, with nothing
  the owner could do but watch. The runner holds one `AbortController` per turn in flight; the
  route aborts it and answers `{stopped}`, false when nothing was running, because the press
  that lands as a turn ends by itself is not an error.
- **Requirement** — the stop lands **between steps, never between a call and its answer**. The
  loop checks the signal before each model call and after the results of a reply have all been
  written, so the stored transcript is one the next turn can be built on; a call that was
  waiting on the model is aborted through the provider, and nothing of that step is stored
  because nothing of it arrived. The turn ends with an assistant row saying it was stopped, a
  `stop` event, and `waiting_for_user` — the owner who stopped it is who starts it again. A
  worker reports the stop as the failure its parent is waiting on.
- **Requirement** — a stop reaches into a running `run_command`. The abort signal travels
  through `exec` as SIGTERM to `sudo`, which relays it to GNU `timeout`, which signals the whole
  process group; the command's exit code becomes its tool result and the turn ends after it.
  The computer tool is bounded at seconds and is not interrupted; an MCP call is not either.
- **Requirement** — every turn ends with a `turn` event carrying the number of model calls and,
  when the endpoint reported it, the prompt and completion tokens. The request asks for usage
  with `stream_options`, and an endpoint that reports none leaves the count of calls, which is
  still a cost.

### Rewinding a thread

- **Requirement** — the owner can take a thread back to an earlier point,
  `POST /api/agents/:name/rewind` or `POST /api/conversations/:id/rewind` with `{from, retry}`.
  Every row from `from` on is deleted; the app restores to one of the owner's messages by cutting
  at it and putting its text back in the composer. With `retry` the cut lands just after the
  message a reply answered, and every participant but that message's author answers it again.
  Refused with a 409 while any participant is mid-turn, because the loop re-reads the thread
  every step.
- **Requirement** — a rewind never leaves a call unanswered. An owner message sent to a busy
  agent can land between a call and its result, so a tool result answering a call from before
  the cut is kept. Summaries reaching past the cut are deleted, or the next turn would replay
  rows that no longer exist.
- Known ceiling: only the thread is rewound. Files, commands, messages to other agents and
  workers spawned in the deleted stretch stay as they are, and pending approvals asked for there
  stay in the queue. Another client that has the deleted rows on screen keeps showing them
  until it reopens the thread.

### Files, memory, search

- **Requirement** — the owner hands an agent a file through `POST /api/agents/:name/uploads`,
  base64 in JSON like a screenshot, written into `~/uploads` **as the agent** so it owns what it
  is given. The name is an operand to the script, never a word in it, and matches one plain path
  segment; the client names the landed path in the message it sends next, and the agent reads
  it with the tools it has.
- **Requirement** — the other direction: `GET /api/agents/:name/files?path=` hands the owner a
  file an agent names in a reply, base64 in JSON the same way. The path is `~/…` or spelled out,
  resolved before the check so `..` cannot leave the agent's home, and read **as the agent**, so
  it is nothing the owner could not already reach through the terminal. A truncated read is an
  error, not a short file. The client finds the paths in the reply's text rather than the agent
  calling a tool, so replies written before this existed get the same cards.
- **Requirement** — `GET` and `PUT /api/agents/:name/memory` read and rewrite `MEMORY.md` as the
  agent, and read today's note. The prompt keeps the head of the file; the owner's screen shows
  more, because the lines past the cap are exactly what nobody could otherwise see. The daily
  note is shown and not edited: it is the agent's own log.
- **Requirement** — `GET /api/search?q=` reads across every thread, `LIKE` over the rows, fifty
  newest hits cut to a snippet, no image and no tool calls. A personal machine's threads are
  small enough for a scan, and a search is a person's request rather than a poll.
- **Requirement** — `GET .../events?limit=` answers the newest that many, oldest first. The log
  grows for the life of the install and a screen that polls it wants the tail; without a limit
  the route answers as before.
- **Recommendation** — `POST /api/settings/test` makes one model call against the stored
  provider settings with no tools. The first message otherwise found out for the owner a turn
  later, in an agent's thread, that the base URL had a typo.

### Push notifications

**Requirement** — an agent that finishes at four in the morning reaches the owner's phone. A
push, straight from the daemon to APNs, with nothing in between: no relay service holding a
second copy of what an agent said, no bot token, no account with anybody but Apple.

- **Requirement** — the daemon speaks to APNs over `node:http2` itself. APNs speaks nothing but
  HTTP/2 and undici's `fetch` cannot, so the client is a hundred lines over the standard library
  rather than a dependency. One session per batch of devices, closed after.
- **Requirement** — the provider token is an ES256 JWT over the key id and the team id, signed
  with the `.p8` key the owner pasted into settings, which is AES-GCM encrypted with the master
  key like the provider key and never returned. The token is cached and re-minted after fifty
  minutes: APNs refuses one older than an hour and throttles a client that mints one per push.
- **Requirement** — a device registers its token through `POST /api/devices` on every launch,
  because Apple may hand it a new one, and a token APNs reports dead — a `410`, or a `400` with
  `BadDeviceToken` or `Unregistered` — is dropped from the table by the push that learnt it.
  Every other failure is a log line and not retried: a push is a nudge, and the thread holds the
  truth.
- **Requirement** — delivery hangs off the loop's one `deliver` seam: what a permanent agent said
  at the end of a turn **in its own thread with the owner**, why a turn failed, and a deletion
  request wherever it was made. A reply in a group is one agent talking to another and a
  worker's report goes to its parent; neither is pushed. Nothing configured or nobody registered
  is silence, never an error.
- **Requirement** — `POST /api/settings/push/test` sends one push to every device, so the owner
  learns on the settings screen whether the key, the ids and the phone line up.
- The app needs a real Apple team and the `aps-environment` entitlement on a device build to be
  handed a token at all. An ad-hoc build and the simulator register nothing, and the daemon then
  simply has nobody to push to; the sandbox switch is for a development-signed device build.
- **Deferred** — other channels. The app is the client and the phone is where the owner is.

### Restart recovery

- **Requirement** — a daemon that dies mid-turn leaves two things broken, and boot repairs both
  before the HTTP server listens, so no reader ever sees the broken shape. The `agents.state`
  row claims work no process is doing, and the transcript ends in an assistant message whose
  tool calls no `tool` message answers.
- **Requirement** — the transcript repair is the load-bearing half. An unanswered tool call is
  not merely a stuck-looking turn: a strict OpenAI-compatible endpoint rejects the whole request
  until every call id has a result, so the agent cannot be spoken to again at all. Each
  unanswered call gets a synthetic tool result saying the daemon restarted and that nothing of
  what the call did was kept. Only the last assistant message can be short an answer, because
  the loop writes each result before asking the model for more.
- The repair lives in the persistence layer, not in transcript assembly. Assembly is a pure
  function of what is stored; if it patched over the gap, the stored history would stay invalid
  and every future reader would have to know to patch it too.
- **Requirement** — the repair is recorded as a `restart` execution event naming the state the
  agent was in and the call ids that were answered for it, so the history says a restart
  happened rather than silently growing a message nobody wrote.
- A repaired agent moves to `waiting_for_user` and **waits for its owner rather than resuming by
  itself**. Resuming is defensible — the synthetic observation is exactly the "system restarted"
  note an agent would need — but a turn that killed the daemon would then be re-run on every
  boot, and auto-resume needs a provider configured at boot for every interrupted agent at once.
  The observation is already in the transcript, so the next message the owner sends carries the
  restart into the model call. `waiting_for_user` also means the agent resumes from persisted,
  repaired history, which is what the restart-recovery requirement asks for.
- **Requirement** — boot also rescues an agent stranded in `waiting_for_agent`. The reply it is
  waiting for wakes it only from inside a live turn, so an answer written before the daemon died
  would never reach it. Boot moves such an agent to `waiting_for_user`; an agent whose reply has
  genuinely not been written yet is left where it stands, because that state is what lets the
  answer wake it later.
- Because a restart ends a turn from wherever the dead daemon was standing, `using_computer` and
  `using_terminal` reach `waiting_for_user` in the transition table. The loop itself still only
  ends a turn from `thinking`.
- Known ceiling: the tool the killed daemon was running keeps going as an orphan, and nothing
  reaps it. The synthetic result tells the agent the outcome is lost, which is true either way.

### Secrets and logging

- **Requirement** — the provider API key is AES-256-GCM encrypted with a 32-byte master key at
  `/var/lib/schermes/master.key`, mode 0600, owned by `schermes`, generated on first boot. The
  file is created with an exclusive open, so two daemons starting at once cannot both generate
  a key and leave one of them unable to decrypt.
- **Requirement** — the API key is never returned by the API. Reading settings reports
  `apiKeySet` as a boolean and nothing else.
- **Requirement** — logs are structured JSON written through one function that recursively
  redacts secret-looking field names before serialising. Redaction is by key name, which cannot
  catch a secret pasted into free text, so routes do not log request bodies at all. That keeps
  the settings endpoint off the leak path entirely rather than relying on the filter.

## Persistence model

**Requirement** — one SQLite database at `$SCHERMES_DATA_DIR/schermes.db`, through
better-sqlite3, with Drizzle for the schema and the migrations. There is no second store, no
cache and no queue: the rows are the queue.

Ten tables, defined in `daemon/src/schema.ts`.

| Table                       | Holds                                                                 |
| --------------------------- | --------------------------------------------------------------------- |
| `owner`                     | One row: the scrypt hash of the owner password                        |
| `sessions`                  | Session ids and their expiry, so a restart does not log you out       |
| `settings`                  | Key/value, with an `encrypted` flag — the provider API key lives here  |
| `agents`                    | Name, X display, durable state, and a worker's parent and thread      |
| `conversations`             | A thread, identified only by its id                                   |
| `conversation_participants` | Who is in a thread. The owner is in every one and is never listed     |
| `messages`                  | Role, content, sender, tool calls, tool call id, an optional image    |
| `summaries`                 | A compacted stretch of a thread, for one agent, and the ids it covers  |
| `schedules`                 | A standing job for one agent: cron, prompt, paused, and when it is next due |
| `events`                    | The structured record of what an agent did                            |

- **Requirement** — durable state is the database, not the process. An agent's `state` column is
  the truth and the loop is a process that can be killed. What is deliberately *not* persisted
  is the one-turn-per-agent set and the desktop input hold: both are properties of a live
  process, and a daemon that dies takes the thing they describe with it.
- **Requirement** — migrations are committed under `daemon/migrations/` and applied on boot, so
  the deployed code and the schema move together and there is no separate migration step.
- **Requirement** — foreign keys are **off across the migrations and on for everything after**,
  decided once in `openDb`. That is step 1 of SQLite's own table-recreate procedure and it must
  happen outside the transaction drizzle wraps each migration in, where `PRAGMA foreign_keys` is
  a documented no-op. `PRAGMA foreign_key_check` is the same procedure's last step, runs after
  the migrations, and **throws** — a referentially broken database refuses to boot rather than
  accumulating more rows. Never put a `PRAGMA foreign_keys` line in a migration file.
- **Requirement** — WAL journal mode, set in the same place.
- **Requirement** — paging is a reader's view and lives in `pageMessages`, never in
  `listMessages`. Every in-daemon caller — the turn's high-water mark, transcript assembly, the
  interrupted-call repair, the agent-chain count — is wrong on a truncated history, and a page
  boundary falling between an assistant message and its tool results is exactly the shape a
  strict model endpoint rejects. Giving `listMessages` a default limit would ship that bug
  silently.
- **Requirement** — the interrupted-call repair lives in the persistence layer, in
  `repairInterruptedCalls`, so the *stored* history becomes valid. Transcript assembly is a pure
  projection and must never paper over a gap instead.
- **Requirement** — `/var/lib/schermes` is a named Docker volume, not a bind mount. A fresh
  named volume is seeded from the image with its ownership and modes, which is what keeps
  `master.key` at 0600 owned by `schermes`. Agent home directories are deliberately outside it:
  a recreated container rebuilds the Linux users and desktops from the surviving agent rows.
- **Deferred** — retention and trimming. Nothing is ever deleted, so a long-lived install grows
  monotonically. Reads are paged and model requests are bounded, so this is disk, not
  correctness.

## Security model

The isolation boundary of schermes is **the machine**, not the agent user. Agents have
passwordless sudo because an agent is the operator of its own computer. Deploy it somewhere you
would be comfortable giving a person root.

What that leaves the product responsible for is the perimeter, and there is exactly one:

- **Requirement** — one exposed port. Every per-agent VNC server binds `127.0.0.1` on
  `5900 + display` and is reachable only through the daemon's proxy, which checks the session
  cookie *and* the input-ownership state before piping a byte. `infra/desktop/check.sh`
  enumerates listening sockets and fails if anything but the web port is bound off loopback.
- **Requirement** — the auth guard is registered before any route and denies by default. Three
  paths are public: health, first-run setup, and login. The static UI is public too, because it
  is a login form until the API answers and putting it behind the session would only mean
  serving a login page in front of the login page.
- **Requirement** — the daemon runs as the unprivileged `schermes` user with the two sudoers
  rules under [privilege model](#privilege-model), and nothing widens that.
- **Requirement** — secrets at rest and out of logs, under
  [secrets and logging](#secrets-and-logging).
- **Requirement** — the daemon makes outbound requests on the model's say-so, and a URL the
  model chose is checked against loopback, link-local and private ranges before it does. See
  [web search and fetch](#web-search-and-fetch), which also says why that is defence in depth
  rather than a boundary: `run_command` and `curl` share this network namespace already.
- **Requirement** — third-party code the owner configures runs as the **agent's** Linux user and
  never as `schermes`. See [MCP](#mcp), which also says why that is a separation of duties rather
  than a boundary: the agent users have passwordless sudo already.
- **Requirement** — the daemon binds `0.0.0.0`. It has to: the machine is reached over the
  network from the app. The port itself is the perimeter, so put a firewall or an authenticating proxy in
  front of anything not on a trusted network.

**First boot is claim-once, and that is the whole of the story.** A fresh image ships with no
owner password and no provider settings, so between the first boot and the first visit, whoever
reaches the port becomes the owner. The window is closed rather than guarded: setup succeeds
exactly once and every later attempt is refused, which `infra/smoke.sh` asserts on every run.
There is no out-of-band claim token and no console-printed secret, because either would be a
second secret to distribute for a machine that is meant to be claimed from the browser thirty
seconds after it boots. Boot it on a network you trust and claim it promptly.

- **Requirement** — the session cookie is `HttpOnly`, `SameSite=Lax`, and deliberately **not**
  `Secure`: a `Secure` cookie is dropped over the plain HTTP the daemon speaks, so setting it
  would break login for every deployment without a TLS proxy.
- **Deferred** — TLS inside the product, a credential vault beyond the encrypted settings row,
  and any notion of a second user. See [deployment](deployment.md) for the proxy.

## Clients

**Requirement** — the daemon is an HTTP API and nothing else. It serves no static files and has
no bundled front end; the native SwiftUI app in `apple/` is the client, and any other one talks
to the same routes. Exactly one port is exposed, and everything on it is `/api`.

- **Deferred** — the React + Vite web UI that used to be served off this port, removed once the
  native app reached parity. It cost a build stage in the image, a dev-dependency tree, and a
  second implementation of every thread and paging rule. Bring it back only if a browser-only
  client becomes a requirement. The API it needs is unchanged, but the implementation is **not
  recoverable from this repository**: the UI was deleted while it was still uncommitted, so it
  is in no commit and `git log -- ui/` finds nothing.
- **Recommendation** — a client learns that something changed by **polling**, not by a WebSocket
  event stream. The daemon has no push side at all, so a stream would be a new module, a
  subscription registry and a reconnect story on both ends; a timer is none of those, it heals
  itself after a laptop sleep or a rebuild, and — because nothing on the server depends on it —
  closing the client cannot stop agent work. Push is the upgrade path if an install ever wants
  sub-second latency.
- **Requirement** — polling is affordable only because a read can ask for what it has not seen.
  `GET .../messages?after=<id>` returns the rows after that id, **ascending from the mark**
  rather than the newest rows above it: a poll that missed a burst longer than its limit has to
  resume where it stopped instead of skipping the middle. An idle poll is an empty array rather
  than a page of base64 screenshots. `before` and `after` are alternatives; asking for both is a
  400. A reader that only shows *that* a row has a screenshot — the sidebar preview, polled for
  every agent — adds `images=0`, which keeps each image's media type and drops its bytes.
- **Requirement** — view-only is enforced by the **client**. The VNC proxy is a byte pipe with
  no RFB parser, so a viewer that does not hold control must not send pointer or key events; the
  client suppresses input before the socket is opened and allows it only when the daemon says
  this client holds the desktop. Unknown ownership is view-only.
- A **task worker** is nested under the agent that spawned it, opening a read-only transcript. It
  has no desktop and no composer: the owner *can* post to one over HTTP, which starts a fresh
  turn on a finished worker, and a client declines to offer that and says to write to the parent
  instead.
- A page is a window on the rows, not on the turns, so a **tool row whose assistant message is
  on an earlier page** renders with a note rather than crashing; the other half arrives when the
  reader walks back one more page.
- The **settings screen is the owner-wide one**, and it is **one entry point with categories**
  rather than several exits from the sidebar: the model, web search, notifications, plugins, the
  daemon connection and about. Each category is its own page with its own Save, sending only the
  fields it owns — `PUT /api/settings` keeps every field a body leaves out — and each follows the
  platform's own convention for a settings surface rather than a look of its own. Every
  write-only field takes blank as "keep the stored one", the provider key's rule, and that rule
  lives in one place on the client side so it cannot drift between them.
- **Scheduled tasks belong to one agent**, not to the install, so they sit beside that agent's
  chat and desktop. A client lists the rows with their next and last run, pauses and resumes
  them, cancels them and creates one from a cron expression and a prompt. It polls on the same
  five-second timer the conversation list uses: **the agent writes its own schedules through
  `schedule_task`**, so the list is somebody else's as well as the owner's.
- Every call goes through one API layer, because it is the one place a 401 is noticed: a screen
  that fetched for itself would leave an expired session on screen until something else asked.
- A client renders a reply's **Markdown**: fenced code in a box with a copy button, inline marks
  in the text, headings and list markers folded to bold lines and bullets. The owner's own rows
  stay plain. What a reply looks like is the client's business; the daemon stores what the
  model wrote.
- The composer takes **slash commands**, the way a Telegram bot does: `/` lists them with a line
  each, letters narrow the list, the arrows and Tab move and complete, Return runs. Every one is
  something the thread already offers — `/new` (a rewind from the first id), `/compact`, `/stop`,
  `/retry`, `/undo`, `/remember <note>` (a line appended to `MEMORY.md` through the memory
  routes), `/interview`, `/screen` and the four pages — so the daemon knows nothing of them; a
  command never becomes a row. Only a whole name is a command: `/home/agent-x/…` is a path and
  goes to the agent as written. A shared thread offers only the five that need no single agent.
- A client shows a **stop** control while the one agent behind a thread is mid-turn, an
  **attach** control that uploads into the agent's home before the message that names the
  files, a **memory** page beside routines and activity, and a **search** across every thread
  next to the agent filter. It asks `GET .../events` for the newest 200 rather than the log.
- A client that polls while it is not in front **announces** rather than draws: a turn that
  ended, or a deletion request that arrived, becomes a system notification. On a phone the
  process is suspended and the push above is the answer; this is the Mac's story.
- The owner can send a **picture** with a message, or as the whole message: base64 in the body
  the way a screenshot travels, PNG or JPEG.

## Docker

**Recommendation** — the Docker image is the deployment and the dev harness, one compose file
for both. It builds `debian:trixie`, runs the real `infra/install.sh`, and is therefore the same
machine a bare Debian host would be. Unraid runs Docker natively, which is why the qcow2 image
build was dropped: it duplicated the provisioning for nothing the container did not already do.

`install.sh` stays the single provisioning path, but the image splits the dependency install
out of it. `install.sh` runs first and on its own layer, because it is a full apt cycle plus a
Node download and must not be invalidated by a source edit; the manifests and `pnpm install`
come next; the sources come last. Only `install.sh` and the systemd unit are copied into that
first layer — the other scripts under `infra/` are named by path and arrive with the final
`COPY`, so editing `smoke.sh` or a desktop script no longer rebuilds everything above it. `install.sh` installs dependencies itself only when the
repository is already present, which is true on a real host and false in the image, so neither
path does it twice.

The container command drops to the `schermes` user with `setpriv` rather than `su`. It execs in
place, so signals from `docker compose stop` reach the daemon instead of a shell.

Five container settings are load-bearing:

- `volumes: schermes-data:/var/lib/schermes` — without it every `docker compose up --build`
  silently started on an empty database. It is also what makes the migrations run against a
  populated database for the first time, which is how the table recreate in `0003` was caught.
- `volumes: schermes-homes:/home` and `schermes-shared:/srv/schermes` — agent workspaces,
  uploads, Chromium profiles and the shared directory outlive a replaced container. The Linux
  users do not: `/etc/passwd` is in the image layer, so `create-agent-user.sh` recreates them
  on boot and chowns a home that already exists, because the uid it is handed is not guaranteed
  to be the one the files carry.
- `hostname: schermes` — Chromium's profile lock is a symlink naming `hostname-pid`. Under a
  different hostname a lock left by the previous container reads as "in use on another
  computer" and Chromium refuses the profile; under the same one it checks the pid, finds no
  Chromium there, and takes the lock over.
- `init: true` — `setsid` reparents detached Xvnc and Chromium processes to PID 1. Without an
  init that reaps them, dead browsers linger as zombies and process checks misfire.
- `security_opt: seccomp=unconfined` — Chromium's own sandbox needs `unshare(CLONE_NEWNET)`,
  which Docker's default seccomp profile denies. Relaxing the container is the better trade:
  the alternative is `--no-sandbox`, which would also weaken Chromium on bare-host deployments
  where the sandbox works fine.

## Cookie persistence and Chromium shutdown

Worth knowing before writing browser automation against this stack. Chromium batches cookie
writes and commits them to the profile on a timer. Its `SIGTERM` handler takes the fast
session-end path and does **not** flush pending writes, so a cookie set seconds before a
restart is lost while an older one survives. `check.sh` therefore waits until the cookie has
actually reached the profile database before restarting the browser.

Sending `SIGTERM` to the browser process alone is still the right way to stop Chromium: it is
the only chromium process without a `--type=` argument, and signalling it exits the whole tree
in about two seconds. Signalling every chromium process at once is what corrupts the shutdown.

## Deferred

- Streaming model responses, a second provider, and a provider registry. One implementation
  behind the seam, chosen by settings.
- Trimming the event log and a retention policy for old conversations. Nothing is ever deleted,
  so a long-lived install grows monotonically. Reads are paged and model requests are bounded,
  so this is disk, not correctness.
- Chromium CDP automation. The computer-use tools cover the MVP; CDP would be an add-on.
- tmux-backed persistent terminals. The terminal tool runs one command at a time for now.
- Desktop idle shutdown. Desktops stay up for the life of the daemon.
- TLS inside the product. The compose file ships Caddy under the `domain` profile instead.
