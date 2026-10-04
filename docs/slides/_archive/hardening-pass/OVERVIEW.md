Completed (pending acceptance: 6 user-gated items plus runtime checks, see ACCEPTANCE.md)

# Hardening pass

## Goal
The 2026-10-02 review found schermes feature-complete but brittle where it has never been tried:
turns get dropped under load, a single context overflow or screenshot can break an agent for good,
real providers will hit wire-format gaps, and every agent has full root on the shared machine. The
app also hides most errors. Fix all of that, and add account security, **without removing any
capability** an agent or the owner has today. Agents keep root, but it becomes root inside their
own sandbox and stops being root over the daemon and the other agents.

## Scope
**Agent sandbox**
- Each agent runs inside its own unprivileged user-namespace sandbox. Its desktop, Chromium,
  terminal, workers and every `sudo` it runs all live there.
- Inside the sandbox the agent is root. It can `apt-get install` and edit system files, and the
  changes land in its own writable layer, not on the host.
- What the agent cannot see from inside:
  - `/var/lib/schermes`: the database, the master key and the APNs key.
  - Other agents' homes.
  - Other agents' VNC and CDP ports.
- What it still can see:
  - its own home;
  - `/srv/schermes/shared`;
  - the network, egress included.
- The daemon still screenshots, drives input, proxies VNC and runs commands as the agent.
- Workers run in their parent's sandbox, as they do today as the parent's user.
- Migration: existing agents move into a sandbox on first boot with their home, Chromium profile
  and memory intact.

**Agent loop correctness**
- No turn is ever silently dropped at the loop cap. Anything that would start a turn waits in a
  persisted queue.
- Nothing is left unread or `waiting_for_*` forever. A sweep catches those states.
- Models gain a context-window field and a vision flag.
  - Compaction budgets come from the model's context window, not from a fixed 400k characters.
  - A context-overflow 400 triggers compaction and a retry.
  - The summariser itself fits within the window.
  - A model without vision never receives images; it gets a text placeholder instead.
- `finish_reason` is honoured:
  - A reply cut off at the token limit is continued or marked as cut off.
  - A truncated tool call isn't executed.
- Rename mid-turn is safe. `busy` and `stops` follow the agent's id rather than its name.
- Stop reaches the summariser and the snapshot.
- The snapshot no longer blocks the first model call.
- Summariser tokens are counted.
- Backup-model retries are sane.
- Form-secret redaction survives a restart.

**Real-provider compatibility**
- Thought signatures from Gemini and OpenRouter (`extra_content` / `reasoning_details`) are
  sent back.
- DeepSeek `reasoning_content` is echoed back within the turn.
- Strict chat templates are handled by merging consecutive same-role messages.
- Streamed tool calls without an `index` are merged correctly.
- Tool schemas are sanitised for Gemini's OpenAI endpoint.
- Bare `data:` lines in a stream are tolerated.
- Setup notes cover vLLM (`--enable-auto-tool-choice`) and Ollama `num_ctx`.

**Daemon security and ops**
- Login:
  - async scrypt plus a per-IP failure backoff;
  - re-login is safe: one session per login, and expired rows are swept.
- Account security:
  - change the password;
  - list and revoke sessions;
  - TOTP second factor with recovery codes;
  - an audit log of owner actions;
  - logout clears the cookie.
- The cookie is `Secure` when the request arrived over TLS (`X-Forwarded-Proto`).
- Body-size limit on `/api/*`.
- A first-run setup token is printed in the daemon log and required for `POST /api/auth/setup`.
- Deleting an agent removes its Linux user, home and sandbox, so a reused name starts clean.
- Schedules and the idle budget's day boundary use an owner-set timezone.
- An idle pass interrupted by a restart still counts its tokens against the budget.
- Trigger checks run concurrently, each with its own timeout.
- Images:
  - Message images move out of SQLite into content-addressed files on the data volume.
  - Agent screenshots older than a configurable default retention (30 days) are pruned.
  - Images the owner sent are kept.
- Home snapshots: smaller, or incremental, with bounded retention.
- Performance: `contextFullness` is cached or stored instead of recomputed on every poll, and an
  index is added on `messages.sender`.
- `POST /api/agents/:name/computer`: keep it, document it, or remove it, with the decision
  recorded.

**Apple app**
- A visible error and offline surface across the app, not only in the empty state.
- No silent `try?` in the polling paths.
- Polling slows down or pauses when the scene is inactive or the Mac window is occluded. The
  agent-list fan-out is collapsed.
- Clipboard bridge for the desktop:
  - `ClientCutText` and `ServerCutText` both work;
  - Cmd is mapped to Ctrl for shortcuts, so Cmd+V pastes on the agent desktop.
- A failed older-page load can be retried.
- Tapping a push that cold-launches the app opens the right agent.
- One shared re-login in flight at a time.
- The logout race is fixed. "Forget server" unregisters push and clears the Keychain.
- Enum decoding tolerates unknown values from the daemon.
- UI for password change, session list, TOTP enrolment and login, the audit log, the timezone and
  image retention.
- Cleanup:
  - dead group-thread code and stale web-UI comments go;
  - Swift 6 concurrency warnings are fixed;
  - temp image files get stable names;
  - accessibility labels on icon-only buttons, and Dynamic Type for the fixed tiny fonts;
  - the Keychain item becomes `ThisDeviceOnly`;
  - a cleartext-HTTP warning shows for non-loopback servers;
  - the share extension uses less memory on large files;
  - duplicate resign-key observers are removed;
  - a failed take-control is surfaced.

**Docs and tests**
- README and `docs/` match the code: no web UI, the full config table, and the new sandbox
  privilege model in `docs/architecture.md`.
- The `hermes-parity` acceptance steps are rewritten for the app.
- Tests for every fix above. In particular, the thin areas get real coverage: imap, goals,
  triggers, workers, interview, snapshots, the models registry, and the app's Restore, Triggers
  and chat paging logic.

## Non-goals
- No new product features beyond account security: no backup/restore, no per-agent resource
  limits UI, no update checker, no multi-owner accounts.
- Passkeys are out, because the native app would need an associated domain that a server reached
  by IP can't have. TOTP is the second factor.
- No change to the agent-to-agent routing model from 43d8430, beyond fixing owed-request answering.
- No visual redesign. The new screens follow the existing Theme and the redesign canvas.
- No full container per agent, Kubernetes or VM. The sandbox lives inside the one existing
  container.
- No renaming of `schermes` identifiers. The repo is `desklings` on purpose.

## Key decisions & constraints
- **No functionality may regress.** Everything `infra/smoke.sh` and `infra/desktop/check.sh`
  assert today must still pass, including `apt-get install` by an agent, the Chromium cookie
  surviving a restart, adopting desktops after a daemon restart, and restart recovery. Extend
  those scripts rather than weakening them.
- **Sandbox mechanism.** It must work inside the existing Docker container with
  `seccomp=unconfined` and **without `--privileged`**, on Docker Desktop and on Unraid (later,
  possibly Coolify).
  - Candidates: bubblewrap, `unshare` plus overlayfs or fuse-overlayfs, or systemd-nspawn. The
    first slice picks one with evidence.
  - Chromium's own sandbox must still work nested inside it. No `--no-sandbox`.
  - The per-agent writable layer lives on a named volume, so packages an agent installed survive
    `up --build --force-recreate`.
- **Images:**
  - Retention defaults to 30 days for agent screenshots, configurable in Settings.
  - Owner-sent images are never pruned.
  - A pruned image renders as a "screenshot expired" placeholder.
  - The transcript sent to the model already caps images at 3, so pruning can't break replay.
- **Database:** migrations are additive and reversible where possible. Moving images out of
  SQLite is resumable if interrupted.
- **Client contract:** daemon contract changes follow `docs/architecture.md` `## Clients`. New
  enum values must not break an older app build, which is why the app decodes them tolerantly.
- **Testing:**
  - Daemon tests stay framework-free (`node:test`). `pnpm check` stays strict.
  - Provider quirks are reproduced in `infra/provider-stub.py` modes and unit fixtures.
  - App work is tested focus-free, per `~/.claude/skills/native-app-testing/SKILL.md` and the
    project memories (headless simulator, env-gated Mac renders). Never take over the cursor.
- **Concurrency on this checkout:** other agents may edit it at the same time. Commit only your
  own files, and re-read before you edit.
- **Docker disk:** the VM disk fills from rebuilds (SQLITE_IOERR_SHMSIZE). Prune build cache
  between heavy rebuilds, and never prune volumes without asking.

## Preconditions & external dependencies
- **A real OpenAI-compatible endpoint and API key**, for the final end-to-end run. Ideally two:
  for example OpenAI or OpenRouter (Gemini through it), plus a local Ollama or vLLM. Until then,
  stub modes stand in.
- **Access to the Unraid server**, to confirm the sandbox works under its Docker and kernel.
  Check `kernel.unprivileged_userns_clone` and the AppArmor or SELinux setup.
- **A physical iPhone**, for the cold-launch push routing and share-extension memory checks.
- **An authenticator app**, for TOTP enrolment acceptance.
- None of these block the early slices.

## Building blocks
- Sandbox runtime: `infra/desktop/*.sh`, `install.sh` sudoers, `daemon/src/agents.ts`,
  `exec.ts`, `terminal.ts`, `computer.ts`, `browser.ts`, `vnc.ts`, `workers.ts`.
- Turn queue and sweep: `loop.ts` runner, `schedules.ts`, `triggers.ts`, `conversations.ts`.
- Model capabilities and compaction: `models.ts`, `loop.ts` projection and summariser,
  `provider.ts`.
- Provider wire compatibility: `provider.ts` (parsing, deltas, schemas), `provider-stub.py`.
- Auth and account: `auth.ts`, `app.ts` auth routes, new audit and TOTP tables, `log.ts`.
- Storage: `schema.ts` and migrations, an image file store, retention jobs, `snapshots.ts`.
- Time: an owner timezone setting threaded through `schedules.ts` and `idle.ts`.
- App: `Session.swift`, `SchermesClient.swift`, `Types.swift`, `ConsoleView.swift`,
  `ChatView.swift`, `RfbClient.swift` / `DesktopInput.swift`, `Notifier.swift`, `Settings.swift`,
  the share extension.
- Docs: `README.md`, `docs/architecture.md`, `docs/configuration.md`,
  `docs/troubleshooting.md`, `docs/deployment.md`.

## Definition of Done
**Sandbox**
- [x] `.dockerignore` excludes `data/` and `state/`, so a local build never bakes the APNs key
  into the image (found in slice 1).
- [x] `docs/architecture.md` `## Privilege model` describes the per-agent sandbox. `install.sh`
  no longer contains `%agents ALL=(ALL) NOPASSWD: ALL` for host root.
- [x] Each of the following is proven inside a sandboxed agent, by a check in `smoke.sh` or
  `check.sh`:
  - [x] it cannot read `/var/lib/schermes/master.key`;
  - [x] it cannot read another agent's home;
  - [x] it cannot connect to another agent's VNC or CDP port;
  - [x] it cannot reach the daemon's session table;
    (Via the gateway, a host-published web port answers like it does any network client, auth-guarded.)
  - [x] `sudo apt-get install -y <pkg>` succeeds and the package survives
    `docker compose up --build --force-recreate`.
- [x] Chromium runs with its sandbox on (no `--no-sandbox`). The cookie-survives-restart check
  in `check.sh` passes.
- [x] A pre-existing agent (created before this task) migrates into a sandbox with its home,
  Chromium profile and memory intact, shown by a scripted check.
- [x] Deleting an agent and creating one with the same name yields an empty home, shown by a
  test or smoke check.

**Agent loop**
- [x] With the loop cap set to 1, starting more turns than slots runs every one of them
  eventually, including a worker reporting to a busy parent and a schedule. A test proves no
  turn is lost and no agent stays `waiting_for_*` after its work is done.
  (Slice 4. At cap 1 a spawn is refused, so the test starts a directly inserted worker; its
  report to the parent is the start that hits the cap.)
- [x] A stub mode returning a context-length 400 leads to compaction and a successful retry. A
  model with a 32k context window gets a transcript that fits (unit test).
  (Slice 6. The fit holds for a thread of finished turns; one turn's own traffic can still exceed
  a 32k window, which is recorded as a known limit.)
- [x] A model with `vision: false` never receives an `image_url` part (unit test). An agent with
  screenshots in its history keeps working after switching to such a model.
- [x] `finish_reason: "length"` is handled: a cut-off reply is continued or marked, and a
  truncated tool call is not executed (tests).
  (Slice 7. A cut-off reply is marked, not continued; a truncated call is answered and not run.)
- [x] Renaming an agent while a turn is draining doesn't run the next round under the old name,
  and doesn't allow two concurrent turns (test).
- [x] Stop during compaction and during the snapshot returns within a few seconds (test).
- [x] Summariser tokens show up in turn usage. Form-secret redaction survives a restart (tests).
  (Slice 7, along with the backup-retry rules: `### Model registry and recovery`.)

**Provider compatibility**
- [x] `provider-stub.py` has modes for each of these, and `pnpm test` has a passing test per mode:
  - [x] Gemini thought signatures (plus OpenRouter `reasoning_details`);
  - [x] DeepSeek `reasoning_content`;
  - [x] a strict alternating-roles template;
  - [x] streamed tool calls without an index;
  - [x] bare `data:` lines;
  - [x] a schema-strict endpoint.
  (Slice 8. DeepSeek's current docs require `reasoning_content` back on every earlier reply
  when tools are sent, not only within the turn, so that is what is built.)
- [x] `docs/configuration.md` covers vLLM and Ollama setup.
- [ ] A real OpenAI-compatible endpoint completes a turn with a tool call and a screenshot, end to
  end on the owner's server. `[user-gated]`
- [ ] A second real provider of a different family (for example Gemini via OpenRouter, or a
  local model) completes a multi-step tool turn. `[user-gated]`

**Daemon security and ops**
- [x] Login uses async scrypt and backs off after repeated failures (test). A login flood doesn't
  stall `/api/health` (test).
  (Slice 9. `X-Forwarded-For` is trusted only from a loopback peer, so clients behind the
  compose Caddy share one count: a known limit, recorded in `### Owner authentication`.)
- [x] Password change, session list and revoke, TOTP enrolment, login and recovery codes, and an
  audit log of owner actions exist as routes with tests.
  (Slice 10. TOTP setup also needs the password, so a stolen cookie can't enrol its own phone.)
- [x] The cookie is `Secure` behind TLS, and logout clears it (tests).
- [x] First-run setup requires the token printed in the log. `smoke.sh` is updated accordingly.
  (Slice 9. The app has no token field yet, so the app alone can't claim a fresh daemon: see
  the Settings line.)
- [x] `/api/*` bodies over the limit get a 413 (test). (Slice 9: 40 MB.)
- [x] Schedules fire in the owner's timezone across a DST change (unit test with a fixed clock).
  (Slice 11. `timezone` setting; the idle window and the budget's day follow it too.)
- [x] The idle budget counts a pass interrupted by a restart (test).
  (Slice 11. Tokens are written per model call; boot closes the pass as `interrupted`.)
- [x] One hung IMAP trigger doesn't delay the others (test).
- [x] Images:
  - [x] new images are stored as files;
  - [x] the migration moves existing ones and can resume after interruption;
  - [x] retention prunes agent screenshots past the window and keeps owner images;
  - [x] the API serves pruned images as an expired placeholder (tests).
  (Slice 13. `messages.image_ref` beside the legacy column; `imageRetentionDays` setting, default
  30, 0 keeps all; a recording hand-over's picture counts as the owner's.)
- [x] Snapshot retention is bounded, and the snapshot no longer blocks the first model call
  (test). (Slice 5 did the second half. Slice 12: 7 days, 50 per agent and 2 GiB per agent,
  newest always kept, pruned after every snapshot.)
- [x] `GET /api/agents` no longer reads every thread in full. There is an index on
  `messages.sender` (migration plus test). (Slice 12: a memo per thread; migration 0037.)
- [x] The `POST /api/agents/:name/computer` decision is recorded in `docs/architecture.md`.
  (Slice 12: kept, because `smoke.sh` drives the tool layer through it.)

**Apple app**
- [x] An error or offline banner is visible in the main window and in chat whenever the daemon is
  unreachable or an action fails. There are no `try?` calls left in the polling paths
  (grep-checkable).
- [x] Polling pauses or backs off when the scene isn't active. Verified by a unit test of the
  poll scheduler.
  (Slice 16: `Session.reachability` + `TroubleBanner`, `PollSchedule`/`Session.poll`, one
  `AgentFeed`; `PollingTests.swift`; the grep is in the slice entry and `apple/README.md`. /complete moved the Idle page's own 30 s loop onto `session.poll` as well.)
- [x] Clipboard round-trip with the agent desktop. Cmd+V pastes on the agent desktop. RFB tests
  cover `ClientCutText` and `ServerCutText`.
  (Slice 17: Latin-1, 256 KiB each way; Cmd+C/V/X/A/Z(+Shift) → Ctrl. Cmd+V on a real agent
  desktop is Runtime-unverified, see the slice entry.)
- [x] Session, auth and paging fixes, each with a test:
  - [x] the older-page retry; (slice 17: `OlderPages`, `ThreadTests`)
  - [x] a single re-login in flight;
  - [x] the logout race;
  - [x] "Forget server" unregisters push;
  - [x] enums decode tolerantly.
  (Slice 14: `SessionTests.swift`, `TolerantDecodingTests.swift`.)
- [x] Settings has password change, sessions, TOTP enrolment, audit log, timezone and image
  retention, and the model editor has `contextWindow` and `vision` (slice 6). Login handles TOTP.
  The setup screen has a first-run setup-token field, sent as `setupToken` (slice 9). Until it
  does, the app gets a 403 on a fresh daemon and the owner has to claim it with curl.
  Login answers `totpRequired` with a code field (`totp` or `recoveryCode`), and the share
  extension and notification actions still work with TOTP on: today they re-login with the
  Keychain password, which fails once TOTP is on (slice 10, `## Clients`).
  (Slice 14 did the login/setup half: setup-code field, TOTP and recovery-code login, 429 wait,
  and a shared session cookie for the share extension. Slice 15 did the rest: Settings ▸ Account,
  the Daemon page's time zone and retention, and the model editor's capabilities.)
- [x] `xcodebuild` builds for macOS and iOS with zero Swift concurrency warnings. The macOS and
  iOS test suites pass.
- [x] Cleanup is done: no dead group-thread code, no `ui/src` comments, and icon-only buttons have
  `accessibilityLabel`.
  (Slice 18: clean builds into fresh DerivedData, 0 Swift warnings; macOS 302 and iOS 292 tests
  pass. `ChatThread` is one agent; the greps are in the slice entry.)
- [ ] A push that cold-launches the app opens its agent on a real iPhone. `[user-gated]`
- [ ] A share of a ~25 MB file from the share extension succeeds on a real iPhone. `[user-gated]`
- [ ] TOTP enrolment works with a real authenticator app. `[user-gated]`

**Docs and verification**
- [x] README and `docs/` describe the app as the only client. The config table is complete.
  The `hermes-parity` acceptance steps are rewritten for the app.
  (Slice 19: `docs/acceptance.md`, linked from `docs/README.md` and the root README; greps in the
  slice entry.)
- [x] Test files or substantial new tests exist for: imap, goals, triggers, workers, interview,
  snapshots and models.
  (Slice 19: one `daemon/src/<area>.test.ts` each, 73 tests in all.)
- [x] `pnpm check`, `pnpm test`, `infra/smoke.sh` and `infra/desktop/check.sh` all pass on the
  Docker harness.
  (Slice 19: all exit 0; 482 daemon tests; smoke and check.sh on a fresh `smoke` project build.)
- [ ] The sandbox, `smoke.sh` and `check.sh` pass on the Unraid server. `[user-gated]`

## Open questions
- ~~Which sandbox mechanism?~~ Slice 1 chose `unshare` with a subuid map, plus fuse-overlayfs
  and pasta. It needs `devices: /dev/fuse, /dev/net/tun`. It is proven on Docker Desktop; Unraid
  is still unverified. See `docs/architecture.md`, "Per-agent sandbox".
- ~~How should the daemon reach VNC and CDP?~~ Through a per-agent netns, with pasta forwarding
  `127.0.0.1:5900+n` and `9222+n` from the container loopback. The ports are unchanged.
- **Decided (owner, 2026-10-02):** "root inside" means the agent's own uid plus passwordless
  `sudo` to uid 0, because Chromium refuses root with its sandbox on.
- **Decided (owner, 2026-10-02):** compose adds `devices: [/dev/fuse, /dev/net/tun]` and a
  `schermes-sandboxes` named volume. This is not `--privileged` and adds no capabilities.
- Should the agent's sandbox network egress stay unrestricted? Default: yes, as today.
