# Next slice — schermes-mvp

Read `docs/slides/schermes-mvp/OVERVIEW.md` (north star) and
`docs/slides/schermes-mvp/PROGRESS.md` (what's already shipped) first.

## This slice
Make the daemon exist. A Node 24 + TypeScript service under systemd that owns the single
exposed port, persists to SQLite, forces the owner to set a password on first visit, and stores
the model provider settings with the API key encrypted at rest. No agents, no desktops, no
model calls yet — this slice is the spine everything later hangs off.

## Scope boundaries
- Do:
  - pnpm workspace at the repo root with `daemon` and `shared` packages, TypeScript strict.
    (`ui` comes later; don't scaffold it now.)
  - Hono HTTP server on one port (`SCHERMES_PORT`, default 7777), bound to `0.0.0.0` — it is
    the only thing allowed off loopback. A `GET /api/health` that needs no auth.
  - better-sqlite3 + Drizzle, migrations committed to the repo and applied on boot. Database at
    `/var/lib/schermes/schermes.db`, owned by the `schermes` user.
  - Owner auth: first visit to the API reports "setup required"; a setup endpoint sets the
    single owner password (hashed with scrypt from `node:crypto` — no new dependency); a login
    endpoint issues an HttpOnly session cookie; every other route requires it.
  - Secrets: AES-GCM via `node:crypto`, master key in `/var/lib/schermes/master.key`, mode
    0600, owned by `schermes`, generated on first boot. Settings endpoints for provider base
    URL, model name and API key. The key must never come back in a response or reach a log.
  - Structured JSON logging with a redaction step, so "no secrets in logs" is enforced in one
    place rather than per call site.
  - systemd unit installed by `infra/install.sh`, and the Docker entrypoint runs the daemon
    instead of `sleep infinity`.
  - Unit tests (node:test, no framework) for the secrets round-trip, the redaction step, and
    the auth guard. A smoke script that curls health, setup, login and settings against the
    running container.
- Don't:
  - Any UI, React or Vite. Any agent, desktop, worker or messaging code. Any real model call.
  - Multi-user or roles — one owner, one password.
  - TLS inside the product. Caddy in front stays the documented answer.

## Done when
`docker compose up -d` starts the daemon, and the smoke script exits 0 against it: health
responds, setup sets a password, login returns a session cookie, settings round-trip the base
URL and model, and reading settings back never exposes the API key. `docker compose restart`
preserves the password and settings. Unit tests pass. `check.sh` from slice 1 still exits 0,
and the loopback assertion in it still holds with the daemon's port excluded explicitly.

When finished, run `/handoff`.
