# Troubleshooting

Symptoms that have actually happened, and what they turned out to be. Everything here was paid
for once already.

## The daemon

**`SQLITE_IOERR_SHMSIZE` on boot, or on the first write.** The disk is full. That is what a full
filesystem looks like from SQLite, and it does not say so. On Docker Desktop the culprit is
usually its Linux VM's disk rather than the volume: check `docker system df`, and prune this
project's dangling images and build cache before blaming the database. Nothing is corrupted.

**`/` answers 404.** That is correct: the daemon serves the API and nothing else. Connect with
the app in `apple/`, or call `/api/health`.

**The daemon refuses to boot with a foreign key complaint.** `PRAGMA foreign_key_check` runs
after the migrations and throws on purpose, so a referentially broken database refuses to start
rather than accumulating more rows on top. Fix the rows; do not disable the check.

**A request hangs forever and never returns a response.** Something detached while still holding
the daemon's stdout pipe. `close` fires on stdio EOF, not on process exit. Detach through the
terminal tool's `background` option, or use an `exec` redirect *inside* the shell — a redirect
on the command leaves the shell itself holding the pipe. This bit `xclip` and the background
command, and the fix is in `CLIPBOARD_WRITE_SH` in `daemon/src/computer.ts` if you need the
shape of it.

**Sessions are dropped and login never sticks.** The session cookie is deliberately not
`Secure`, because schermes speaks plain HTTP. If you put it behind a proxy that rewrites cookie
attributes, stop doing that.

**`scrypt` throws about memory.** Node's default `maxmem` is 32 MiB and an N above 16384 exceeds
it. That is why `SCRYPT.N` is 16384 in `daemon/src/auth.ts` and not higher.

## Agents and desktops

**An agent is stuck in `waiting_for_agent`.** It is waiting for a reply that only ever arrives
from inside a live turn. If the daemon died in between, boot moves such an agent to
`waiting_for_user` — an agent still sitting in `waiting_for_agent` is one whose reply genuinely
has not been written yet. Write to it and it moves.

**Two agents have wedged a thread between them.** `MAX_AGENT_CHAIN` stops them after six
messages without the owner. Posting to either agent, in its own thread or in the shared one,
resets the count.

**A message gets a 429.** The loop cap (`SCHERMES_MAX_LOOPS`, default 8) or the worker cap
(`SCHERMES_MAX_WORKERS`, default 4). A message to a *busy* agent is never refused — the message
rows are the queue and the running turn picks it up — so a 429 really means capacity, not
contention.

**A message gets a 400 about provider settings.** Base URL, model and API key are not all
stored. Note that an empty string counts as a value: sending `apiKey: ""` erases the stored key.

**A desktop will not start after a container restart.** A killed X server leaves
`/tmp/.X<n>-lock` behind, and X only clears a stale lock when the pid inside it is dead — pids
recycle, so a leftover lock can name a pid that now belongs to something else.
`start-desktop.sh` probes the display first and removes the lock when nothing is serving it.

**`scrot -` fails as an agent user.** It opens `/dev/stdout` by path, which an agent user cannot
do across a uid change. Captures land in the agent's home and are `cat`'d back instead.

**Cookies do not survive a Chromium restart.** Chromium's `SIGTERM` path does not flush pending
cookie writes, and only the browser process should be signalled — it is the one Chromium process
with no `--type=` argument. Signalling the process group kills the renderers first and loses the
write.

**`ss -p` shows no pids inside the container.** Docker does not grant `CAP_SYS_PTRACE`. The
socket list is still correct; only the owning process is hidden. `check.sh` matches on
`address:port` for this reason.

**A port check flags `127.0.0.11`.** That is Docker's embedded DNS resolver, and it is loopback.
Only non-loopback bindings matter.

## Building

**`pnpm` aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`.** A re-run of `install.sh`
changes which projects have a modules directory, and pnpm will not remove one without a TTY
unless told the run is unattended. The script exports `CI=true` for exactly this.

**A Docker build takes forever and eats gigabytes.** You edited `infra/install.sh`. It is the
base layer, it is a full apt cycle plus a Node download, and every layer above it is invalidated.
Budget roughly 2 GB of free space before starting one.

## Clients

**The desktop is view-only when it should not be.** View-only is the default and unknown
ownership is view-only, because the proxy is a byte pipe with no RFB parser — input is
suppressed before the socket opens and allowed only once the daemon confirms this client holds
the desktop. Take control, and check `GET /api/agents/:name/control`.

**A page looks stale.** The UI polls; there is no event stream. Agent list and open thread every
2s, control and events every 4s, conversations every 5s.

## Getting more detail

Events are the structured record of what an agent did: `GET /api/agents/:name/events`, or the
activity list in the agent view. They carry no payloads and no secrets — a screenshot event
records the byte count, never the pixels — so they tell you what happened and when, not what was
in it. Daemon logs go to `docker compose logs -f schermes` under Docker, and to journald on a
bare host (`journalctl -u schermes -f`).
