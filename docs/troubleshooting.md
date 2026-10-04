# Troubleshooting

Symptoms that have actually happened, and what they turned out to be. Everything here was paid
for once already.

## The daemon

**`SQLITE_IOERR_SHMSIZE` on boot, or on the first write.** The disk is full. That is what a full
filesystem looks like from SQLite, and it does not say so. On Docker Desktop the culprit is
usually its Linux VM's disk rather than the volume: check `docker system df`, and prune this
project's dangling images and build cache before blaming the database. Nothing is corrupted.

**The database file stayed large after upgrading past the image move.** The first boot moves
every message picture out of `schermes.db` into `images/` beside it. SQLite keeps the freed pages
for its own reuse, so the file does not shrink. To give the space back, stop the daemon and run
`sqlite3 /var/lib/schermes/schermes.db 'VACUUM'` as `schermes`. That needs free disk about the
size of the database, which is why the daemon never does it on its own. The move logs
`images moved out of the database` when it finishes. A boot that logs that the move stopped
(usually a full disk) resumes it on the next boot.

**A screenshot shows as expired.** It is older than `imageRetentionDays` (default 30), or its
file under `/var/lib/schermes/images/` is gone. See [configuration](configuration.md#screenshot-retention).

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

**Sessions are dropped and login never sticks.** The cookie is `Secure` when the request says
it came over TLS, which includes an `X-Forwarded-Proto: https` header. A proxy that sends that
header while the app talks plain HTTP to it gets a cookie the app then drops. Send the header
only from a TLS listener. A proxy that rewrites cookie attributes breaks it the same way.

**Setup answers 403 "setup token required".** First-run setup needs the token the daemon
printed when it booted with no owner. Find it with
`docker compose logs schermes | grep 'first-run setup token'`; the value is in `code`. Each boot
without an owner prints a new one, so take the newest line. Send it as `setupToken` beside the
password; the curl call is in [deployment](deployment.md#docker). A 409 instead means an
owner already exists, and setup will never run again.

**Login answers 429.** Too many wrong passwords came from one address: after five, each failure
locks it out for 1 s, doubling, capped at 5 minutes. `Retry-After` says how long. Behind the
compose Caddy, every client counts as one address, so someone else's guesses can delay your
login too. Sessions you already have keep working, and a restart clears the count.

**Login answers 401 with `totpRequired: true`.** The password was right, and two-factor login
is on. Send the six-digit code from the authenticator as `totp`, or an unused recovery code as
`recoveryCode`, beside the password. A code the daemon refuses although the app shows it: the
phone's clock is more than 30 s off, or that code was already used (each 30 s code works once).
An app build that predates TOTP cannot send the code; update it.

**Locked out: the phone and every recovery code are gone.** There is no reset route, so a stolen
cookie cannot remove the second factor. Clear it in the database, as the `schermes` user so the
WAL files keep their owner (the image has no `sqlite3`, so this goes through the daemon's own
driver):

```sh
docker compose exec -u schermes -w /opt/schermes/daemon schermes node -e "
  require('better-sqlite3')('/var/lib/schermes/schermes.db').exec(
    'UPDATE owner SET totp_secret = NULL, totp_pending = NULL, totp_last_step = NULL; DELETE FROM recovery_codes;')"
```

On a bare-metal install, run the same `node -e` from `/opt/schermes/daemon` with
`sudo -u schermes`. The password alone then signs in, and the audit log keeps what happened
before.

**Changing the password signed out the other devices.** That is on purpose: a password change
deletes every session but the one that made it. Sign in again on the others.

**A request answers 413.** `/api` bodies are capped at 40 MB, comfortably above the largest
file the app uploads (25 MB, as base64 in JSON).

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

**An agent takes a while to start on a message.** Every loop (`SCHERMES_MAX_LOOPS`, default 8)
is taken, and the turn waits in `turn_queue` for the next free one. The log says
`turn queued at the loop cap` and later `queued turn started` with how long it waited. Messages
are never refused at the cap. A worker spawn is, as an error the agent sees, by the loop cap or
the worker cap (`SCHERMES_MAX_WORKERS`, default 4).

**A schedule or the idle window is an hour or more off.** Both run in the owner's `timezone`
setting, and unset that is the daemon's zone, which is UTC in the container unless `TZ` is set.
`GET /api/settings` shows the zone in force. Set the owner's with
`PUT /api/settings {"timezone": "Europe/Amsterdam"}`, which also moves every schedule's next run.
A stored zone the daemon no longer knows logs `the stored timezone is unknown here` and falls
back to the daemon's.

**A trigger shows `the check did not answer within 45 s`.** Its check hung: a mail server that
accepts the connection and never answers, or a command stuck past its own limit. Other triggers
are not held up by it. It is checked again at its next interval.

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
