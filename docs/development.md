# Development guide

schermes provisions a whole Linux machine, so most of it cannot be exercised on a Mac directly.
The Docker harness exists to close that gap: the container is a real Debian 13 host built by the
same `infra/install.sh` that a VM or VPS runs, running real Xvnc displays, real Chromium
profiles and real `sudo` boundaries.

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

Tests are `node --test` against `src/*.test.ts` in each package. There is no framework, no
fixtures directory and no runner config. Unit tests use a fake provider and a temporary SQLite
database; anything needing a display, a Linux user or a real `sudo` belongs in the harness
instead.

## The Docker harness

```sh
docker compose build
docker compose up -d
```

Then the two runnable checks. Both are safe to run repeatedly, including after
`docker compose restart` and `docker compose up --build`, because `/var/lib/schermes` is a named
volume and they reuse the owner and the agents they find.

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
messaging, task workers, caps, takeover, and a daemon killed mid tool call.

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
- **Migrations are generated, not written.** `pnpm migrations` runs `drizzle-kit generate`
  against `daemon/src/schema.ts`. Commit the SQL and the snapshot together. Never put a
  `PRAGMA foreign_keys` line in a migration file — drizzle wraps each one in a transaction,
  where that pragma is a no-op.
- **Anything that detaches must drop the daemon's stdout pipe**, or the request hangs: `close`
  fires on stdio EOF, not on exit. Use the terminal tool's `background` option, or an `exec`
  redirect *inside* the shell.
- **All shell access goes through `daemon/src/exec.ts`**, which modules above take as a
  parameter. That is what lets tests assert the exact argv, and it is why the tools are not
  hidden behind a capability-level fake.

More of these, with the symptoms attached, in [troubleshooting](troubleshooting.md). The
reasoning behind the design is in [architecture](architecture.md).

## Before you hand off

`pnpm check` and `pnpm test` clean, `./infra/smoke.sh` exiting 0 twice in a row, and `check.sh`
exiting 0. Twice in a row matters: several bugs in this codebase only appear on the second run,
because the first leaves state the second has to cope with.
