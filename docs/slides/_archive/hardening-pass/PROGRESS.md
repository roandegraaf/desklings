# Progress — hardening-pass

## Current state
- **Done:** every non-`[user-gated]` DoD line (slices 1-19). **Open, user-gated only:** a real endpoint turn with a tool call and
  screenshot, a second real provider family's multi-step tool turn, push
  cold launch on a real iPhone, a ~25 MB share on a real iPhone, TOTP with a real authenticator,
  sandbox + `smoke.sh` + `check.sh` on Unraid. Acceptance steps: `docs/acceptance.md`.
- **Sandbox.** Each agent runs in its own userns sandbox and has no host sudo. Record:
  `docs/architecture.md` › `## Privilege model`. Files: `infra/desktop/sandbox.sh`, the
  `create-`/`rename-`/`delete-agent-user.sh` scripts, `agents.ts` (`asAgent()` → `sandbox.sh enter`).
- **Loop.** `queue.ts` + `createRunner` (`sweep`/`pump`/`repairWaiting`), migration 0031.
  `busy`/`stops` keyed by agent id. Models: `context_window`/`vision` (0032),
  `compactionBudget(window)`. `ChatReply.finish` → `CUT_OFF`/`CALL_CUT_OFF`. Redaction in
  `hidden_values` (0033). Record: `### The model provider`, `### Model registry and recovery`,
  `### Context compaction`.
- **Provider (8):** `messages.echo` (0034), stub `STUB_*` modes. **Auth (9-10):** `auth.ts`,
  `account.ts`, `AUDITED_WRITES`, `AppDeps.now`, 0036. **Time (11):** `timezone.ts`, `nextRun(…, tz?)`,
  `closeInterruptedPasses`. **Snapshots/list (12):** `snapshotsToPrune`, `contextFullness` memo, 0037.
- **Images (13).** `images.ts`: `$DATA/images/<sha[0:2]>/<sha256>`, `messages.image_ref` (0038),
  resumable `startImageMover`, hourly `pruneImages` (owner images never). Wire: expired =
  `{mediaType, base64: "", expired: true}`. `## Persistence model`.
- **App (14-17).** `Session`: `Credentials` seam (tests never touch Keychain/defaults/pasteboard:
  the macOS test host is the owner's real app), `epoch`, single-flight `reLoginTask`, `TolerantEnum`.
  `Account.swift` (Settings ▸ Account). `Polling.swift` (`PollSchedule`, `Session.poll`, `AgentFeed`)
  + `Session.reachability` + `TroubleBanner`. `RfbClient` cut text/`paste`/`shortcut`, `Clipboard`
  seam, `OlderPages`. Tests: `SessionTests` (URLProtocol `Daemon`/`Canned`, reads `httpBodyStream`),
  `PollingTests`, `RfbTests` (offscreen AppKit windows, never ordered front).
- **App cleanup (18).** `ChatThread` is a struct around one `Agent` (no group threads anywhere in
  the app; `ThreadSource.conversation` stays for fetches by conversation id). 0 Swift warnings on
  clean builds. `Session.isCleartext` + `CleartextWarning`; Keychain `…ThisDeviceOnly`;
  `writeUploadBody` + `upload(for:fromFile:)`, `mappedFile`; `imageFolderName` (SHA-256).
  App invariants: polls never clear action errors; `logOut()`/`forgetServer()` return the sign-out
  `Task`; `changePassword` saves the new password only after the daemon accepts it.
- **Uncommitted:** slices 2-19 (`git status`: `sandbox.sh`, `queue.ts`, `images*.ts`, migrations
  0031-0038, `Account.swift`, `Polling.swift`, `Offline.swift`, the new Swift tests, …).
- **Harness:** smoke in the throwaway `smoke` project: `COMPOSE_PROJECT_NAME=smoke
  SCHERMES_PORT=7779 COMPOSE_FILE=docker-compose.yml:<override with container_name:
  schermes-smoke>`; afterwards `down -v` it, prune build cache, `docker rmi smoke-schermes`.
  bash 3.2: no heredoc with `case …)` inside `$( )`. No `timeout` on macOS. Swift warnings only
  show in a build into a fresh `-derivedDataPath`. `check.sh` runs INSIDE the container
  (`docker compose exec -T schermes /opt/schermes/infra/desktop/check.sh`); on the Mac it dies
  on `declare -A`.

## Slice: 1 — sandbox feasibility spike
- **Shipped:**
  - `infra/desktop/sandbox-proto.sh`;
  - the decision record with captured output in `docs/architecture.md`.

  Every requirement was demonstrated in a throwaway container: Docker Desktop, kernel
  7.0.14-linuxkit, `seccomp=unconfined`, not privileged, on both the default bridge and a
  user-defined network.
  - Fake root: `sudo id -u` gives 0, and outside the sandbox root is uid 100000.
  - `apt-get install cowsay` lands in the upper layer. It survives a sandbox restart, a
    `docker restart`, and a new container on the same volumes.
  - Xvnc, openbox and Chromium run, and the Chromium renderer has its own userns and netns with
    seccomp 2.
  - xdotool and scrot work.
  - CDP and VNC answer on the container loopback, as `schermes`.
  - A full isolation battery from sandbox b passes, 17 denials in all:
    - `master.key` and the `/var/lib/schermes` volume;
    - other homes and other layers;
    - `/proc/<pid>/root` and signals;
    - VNC/CDP by loopback, own IP and gateway;
    - `/run/secrets` and the host `sudoers.d` grants.

    Its own home and the shared dir are read-write, and egress works.
- **Key decisions:**
  - Rejected:
    - kernel overlayfs, because of locked mounts and `clone_private_mount`;
    - bindfs plus kernel overlay, because of `O_NOATIME` EPERM and suid EINVAL;
    - bubblewrap, because it has no persistent writable root and maps only one uid;
    - systemd-nspawn, because it needs `CAP_SYS_ADMIN`;
    - slirp4netns, because it has no loopback port forwarding.
  - Literal "uid 0 inside" was replaced by "agent uid, plus sudo to 0".
- **Notes / leftovers:**
  - Compose needs `/dev/fuse` passed as a device: `mknod` is refused by the device cgroup,
    while tun can be mknod'ed.
  - `.dockerignore` lacks `data/` and `state/`, so a local build bakes the APNs key into
    `/opt/schermes/data`. Pushed images are clean because they are built from `git archive`.
    This is now tracked as a DoD item and scheduled in slice 2.
  - Unraid behaviour is unverified: userns sysctl, AppArmor, xattrs on the volume, and the FUSE
    exec rule.
- **Runtime-unverified:** none in product code, since nothing is wired yet.

## Slice: 2 — run every agent inside its sandbox
- **Shipped:**
  - **Image and compose.**
    - `install.sh`: `uidmap fuse-overlayfs fuse3 passt libcap2-bin`; newuidmap/newgidmap
      switched to `setcap`; `/var/lib/schermes-sandboxes` 0711.
    - `docker-compose.yml`: devices plus the `schermes-sandboxes` volume.
    - `entrypoint.sh` creates the sandbox dir. `.dockerignore`: `data`, `state`.
  - **`infra/desktop/sandbox.sh`** (replaces `sandbox-proto.sh`, deleted):
    - flock;
    - on-demand start in `enter`;
    - reaping of stale holders, fuse and pastas;
    - per-display forwarders;
    - setup refresh (sha-tracked root-only copies plus account-file merge), and setup prunes
      `/run`, so the APNs key file mount is never copied;
    - read-only bind of `infra/desktop` inside, for tint2rc and the launchers;
    - `/tmp/.X11-unix` created inside.
  - **Scripts.** `create-agent-user.sh` assigns the deterministic subid block plus the agents
    subgid, then runs setup. `rename-agent-user.sh` moves the layer. `start-desktop.sh` runs
    start, forward and then everything through `enter`; helper displays share the parent's
    sandbox.
  - **Daemon.** `asAgent()` gains `SANDBOX enter`. `stop` becomes `sandbox.sh stop`;
    `stopDisplay` also runs `unforward`.
  - **Tests:** the asAgent argv test (`tools.test.ts`), a new worker argv test, and an updated
    `mcp.test.ts` prefix.
  - **check.sh:** `on_agent` goes through `enter`, the test page is served inside each sandbox,
    and the screenshot comes out on stdout.
  - **smoke.sh:** brought up to the current API.
    - Model registry: create a provider, then a model with its `providerId`.
    - Rules: `preApproved` as a per-category object.
    - Schedule filter: `sender == "System"`.
    - "Agents talking" rewritten. A's request lands in B's thread under A's name, and B's
      answer lands in A's thread under B's name and wakes A. The group-thread and
      `POST /api/conversations` subsections went, since those concepts no longer exist.
  - **docs/deployment.md:**
    - Unraid: the sandboxes path, `--device=/dev/fuse --device=/dev/net/tun`, and the xattr
      and userns requirements.
    - Seven load-bearing settings, four volumes, and a `tar` backup of the layers.
  - **docs/architecture.md:** "(Proposed)" dropped, with the mechanism, locking, stop, adopt,
    the stale-copy policy, the Docker settings and the desktops requirement.
- **Evidence** (throwaway harness, Docker Desktop 7.0.14-linuxkit):
  - `ps`: holder and fuse-overlayfs run as 100000 and 165536.
  - Namespaces: Xvnc, openbox and tint2 report `user:[4026532565]`, and the terminal route
    reports uid 1000, `sudo` → 0 and `user:[4026532565]`. The container is `[4026531837]`.
  - Chromium runs in its own userns and the renderer in a nested one, with seccomp 2 and no
    `--no-sandbox`.
  - `master.key` is absent inside, and `/home` shows only the agent's own home.
  - The subid blocks survived smoke's container rebuild.
  - Worker: a stub-driven worker's command reported `NS=user:[4026532565]`, the same as
    smoke-one's Xvnc, with `PWD=/home/agent-smoke-one/workspace/workers/smoke-one-w2` and
    `UID=agent-smoke-one`.
  - Daemon-started Chromium: code-path evidence only. `browser.ts` `START_CHROMIUM` goes
    through `asAgent`, the same `enter` path check.sh's Chromium was measured on.
- **Key decisions:**
  - `enter` runs as the agent and reads its own pid file, rather than the daemon resolving pids.
    The 20 call sites stay as they are, and the holder is validated on every call.
  - Per-display ports-only pasta rather than restarting pasta with the union of ports, so live
    VNC and CDP connections survive a helper starting or stopping.
  - Stale copies: refresh untouched root-only copies; merge account files with the container
    winning, agent-* lines dropped and package users kept. dpkg status is not merged; a
    version-aware merge is the documented plan.
  - `stop` keeps `pkill -u` semantics: everything the agent runs, plus its block.
- **Notes / leftovers:**
  - The on-demand start in `enter` opens a window. Any `asAgent` call between `stop` and the
    end of a rename or delete (search scan, idle, triggers) brings the sandbox back. Rename
    then fails with "still running", the same class of race as `usermod` with live processes
    before. Delete cleanup (slice 3) must make the sandbox unstartable right after `stop`.
  - A boot race predates this slice: `search file scan failed: no home directory` logs at
    daemon start after a recreate, before reconcile recreates the users. Harmless.
  - Each forwarder pasta leaves a `DOWN` `fwd<n>` tap inside the sandbox.
  - The local macOS testbed's `sudo` shim must also skip `sandbox.sh enter` (memory updated).
- **Runtime-unverified:**
  - The app-side VNC viewer against a sandboxed desktop. smoke's VNC proxy stream check passed,
    but no human viewed it in the app.
  - Unraid.

## Slice: 3 — host root removed, isolation proven, delete cleanup
- **Shipped:**
  - **Sudoers (`install.sh`).** It deletes `/etc/sudoers.d/agents`. The `schermes` root rule
    is now the create, rename and delete scripts; the unused `apt-get` grant is dropped
    (`-o …Pre-Invoke` made it arbitrary root). As `%agents`: the five `sandbox.sh` forms plus
    `pkill`.
  - **`sandbox.sh retire <name>`** (root): writes `<layer>/disabled` under the lock, releases
    it, runs `stop` as the agent, then kills agent-uid and block stragglers until none are left.
    `start_locked` refuses a disabled layer.
  - **`delete-agent-user.sh`** (new, idempotent): retire, `userdel --force`, groupdel,
    `rm -rf /home/agent-<name>` (path hard-checked), and the layer plus its subid lines under
    the subid lock.
  - **`rename-agent-user.sh`** retires first, clears the marker under the new name on
    success, and under the old one on failure.
  - **`create-agent-user.sh`** clears the marker and re-owns the layer when the agent's
    uid/gid changed. The uid-change bug surfaced in this slice: after a recreate, reconcile
    order handed out other uids, the layer's `lock` was unopenable, and both desktops failed.
  - **Daemon.** `DesktopOps.remove`; `removeAgent` removes before the rows. DELETE answers
    500 and keeps the row on failure. An approved delete that fails sends a correction to the
    asker. Goal helpers (`goals.ts` `removeHelpers`, `loop.ts` undo) are removed the same way.
  - **Tests.** Fakes gained `remove`. New: DELETE uses `remove`; a failed remove → 500 with
    the row kept; a failed approved delete tells the asker. Helper assertions moved from
    `stop` to `remove`.
  - **smoke.sh** (new sections after the apt-get one, plus one after the rebuild):
    - **Sudoers:** no `%agents` grant; an agent's `sudo -n true` outside is refused; the
      daemon is refused `sudo -u agent id` and `apt-get`, and allowed `enter`.
    - **userns:** Xvnc and a command-route command share a userns ≠ the container's.
    - **Isolation probe from smoke-one, 21 denials**, each with a positive control first:
      - `master.key` and `schermes.db`, as the agent and as sandbox root, including through
        `/proc/<daemon>/root` and its fds;
      - smoke-two's home and memory, and its root through Xvnc;
      - smoke-two's VNC and CDP on loopback, the container IP and the gateway;
      - the daemon port on loopback and the container IP. Via the gateway, 000 or 401 is
        accepted.
    - **Migration:** a `useradd` user with an automatic subuid line overlapping block 100000,
      a seeded memory note, and a real headless-Chromium profile → `POST /api/agents`. Then:
      the subuid line is replaced, same uid inside a new userns, profile hashes unchanged,
      memory read back via the API, headless Chromium opens the profile.
    - **Delete under race:** a hammer of `sudo -u agent sandbox.sh enter true` as `schermes`
      runs during DELETE. Then: user, home, layer and subid lines gone, and no uid, block or
      fuse process left.
    - **Recreate:** the same name gets an empty home, no layer marker, and empty memory.
    - **Rename under the same hammer:** the user and layer move, the marker is cleared, and
      commands run.
    - **After the rebuild:** `hello` is still installed (`dpkg -s`) and runs.
  - **User-facing copy:** the app's delete dialog no longer says "Its files on the machine
    stay"; it names the computer, files, memory, browser profile and software. The
    `request_deletion` tool text says the same. The Swift change was only `swiftc -parse`'d,
    not built.
  - **Docs:** `## Privilege model` rewritten. Sandbox Retire/Rename/Delete lifecycle, uid
    re-own, migration proof, residual risks (gateway reach, concurrent ensure), MCP and
    security-model sudo wording, delete requirement, configuration.md rename, deployment.md.
- **Evidence** (throwaway `smoke` project, Docker Desktop):
  - `pnpm check` → 0; `pnpm test` → 312/312.
  - `check.sh` → 0, twice. The second run was after a rebuild, where alpha's layer was
    re-owned 1000→1002 and its cookie still persisted.
  - Full `smoke.sh` → 0 on the final image.
  - Negative control: with the `disabled` check stripped, the hammer restarted the holder
    after a plain `stop`; with `retire` there was no holder.
- **Key decisions:**
  - Marker file rather than stripping the subid lines, so `stop` still works after the marker
    is set.
  - A failed remove keeps the row, so a recreate can never inherit a home.
  - Helpers log and drop the row anyway, as before.
  - The gateway route to a published daemon port is accepted (auth-guarded, like any client).
- **Notes / leftovers:**
  - An `ensure` concurrent with a delete re-enables the sandbox (documented residual risk).
  - Headless Chromium with a live `DISPLAY` prints the page and never exits; smoke unsets
    `DISPLAY` for it.
  - The approval path now sends two lines on failure ("deleted", then a correction), since
    the asker is told before the removal.
- **Runtime-unverified:** Unraid.

## Slice: 4 — persisted turn queue at the loop cap, and the unread/waiting sweep
- **Shipped:**
  - **Migration 0031** (additive): `turn_queue` (id, `agent_id`, `conversation_id`, `kind`,
    `created_at`, unique on agent + thread) and `agents.read_through`, backfilled to
    `max(messages.id)`.
  - **`queue.ts`**: `enqueueTurn` (conflict = no-op; `retry` upgrades the entry in place),
    `queuedTurns`, `dequeueTurn`, `isQueued`, `markRead`, `readThrough`.
  - **Runner (`loop.ts`):**
    - `start(agent, conv, idle?, kind?)` queues at the cap instead of logging and dropping.
    - `pump` starts the oldest entries while loops are free and drops entries with nothing
      unread. `release` pumps on every exit, including the no-provider one.
    - `MAX_ROUNDS` re-enqueues at the back rather than releasing with input unread.
    - `sweep()`: `repairWaiting`, then a `requeue` entry for every idle agent with a model and
      unread input, then pump. `startSweeper` runs it at boot (before the schedule tick in
      `main.ts`) and every `SWEEP_MS` (60 s), `unref`'d.
  - **`reconcileAgents`** now uses the shared `repairWaiting` after the interrupted-state
    pass. It covers `waiting_for_task_worker` too.
  - **Callers:**
    - The message, forward, conversation-message, rewind-retry and kickoff routes no longer
      429 or skip at the cap.
    - Every `start` site passes a kind: report, reply, request, schedule, trigger, approval,
      answer, kickoff or retry.
    - `deleteAgent`, `forgetAgent` and `deleteConversation` remove queue rows.
  - **Docs:** architecture (agent loop: queue, read mark, sweep; messaging; scheduled tasks;
    task workers; background work timer; restart recovery; persistence table),
    `configuration.md` (`SCHERMES_MAX_LOOPS`) and `troubleshooting.md` (the 429 entry
    replaced).
  - **Tests (318 total, +6, 3 rewritten):**
    - **DoD:** maxLoops 1 with a fifth agent holding the loop. It covers owner messages to
      two agents, a worker whose report queues its `waiting_for_task_worker` parent, and a
      schedule. All of them run, the queue empties, and nobody is left `waiting_for_*`.
    - **Restart:** a queued entry survives two restarts, and the turns each restart killed
      are not re-run.
    - **Sweep:** queues unread input, skips an agent with no model, drops an entry with
      nothing to read, and a second sweep is a no-op.
    - **Waiting repair:** a stopped target and a finished worker are repaired; a target
      waiting on its own live worker, and a live worker, are not.
    - **Idle:** an idle pass at the cap is ended unrun, never queued.
    - **API:** a message at the cap is a 202 and runs later, and a rewind+retry at the cap
      runs once a loop frees.
    - **Rewritten:** the boot-reconcile and cap tests, and the API 429 test.
- **Evidence:**
  - `pnpm check` → 0; `pnpm test` → 318/318.
  - Negative controls:
    - with the old drop restored in `start`, the DoD and restart tests fail;
    - with the retry branch removed from `pump`, the retry-at-cap test fails.
  - Upgrade simulation: a DB migrated to 0030 with rows, then reopened with 0031, gives
    `read_through` = `max(messages.id)`, an empty `foreign_key_check`, and an empty queue.
- **Key decisions:**
  - Queue keyed by agent id, one row per agent + thread; fairness is oldest-first.
  - **"Worker reporting to a busy parent" at cap 1:** a spawn at the cap is refused (allowed
    by the slice), so the test inserts the worker directly and starts it. The worker then
    holds the only loop, and its report's `start(parent)` is the start that used to be
    dropped.
  - Spawns keep refusing. At `SCHERMES_MAX_LOOPS=1` an agent therefore cannot spawn at all;
    this is unchanged from before.
  - Idle passes never queue, because the callback is not persistable. The idle tick already
    keeps the pass `due`.
  - The backfill means anything dropped at the cap *before* the upgrade stays unread. The
    trade is that a prompt rewound without retry is never re-run.
  - The boot sweep auto-runs new unread input, including the restart notice boot writes to a
    failed worker's parent. The interrupted turn itself is never re-run.
  - `waiting_for_agent` counts as pending only while a target is on it. A stopped target
    (which never answers) frees the asker.
  - No new `EventType`, to protect the app's enum decoding: a sweep repair is the ordinary
    `state` event, and the boot repair keeps `restart`.
- **Notes / leftovers:**
  - `stop` on a merely queued agent returns false, and the turn still runs later.
  - Queued state is not exposed in `GET /api/agents`, so the app cannot show "waiting for a
    loop". This fits the app error/offline slice.
  - `loop.ts` imports `needs.ts`, which imports `loop.ts` (`RUN_FAILED`). This is fine at
    runtime because the import is used only inside functions.
  - The persistence table in `architecture.md` says twenty-four tables, but `providers` and
    `read_marks` were already missing from its rows.
  - The `send_message` observation still says the target "is now working on it", even when
    the turn is queued.
- **Runtime-unverified:**
  - `infra/smoke.sh` and `infra/desktop/check.sh` were not run; this slice made no infra
    change.
  - The backfill was checked only on the simulated upgrade, not on a real install.

## Slice: 5 — rename mid-turn, stop reaches the summariser and snapshot, snapshot off the first call
- **Shipped:**
  - `loop.ts`: runner `busy`/`stops` and `live` re-keyed by id; `drain` takes the id and
    re-reads the row around every round; capacity checks in `start` use the id directly.
  - `loop.ts`: `homeReady` gate (`untilStopped`) in front of every tool dispatch and handed to
    `deps.mcp`; snapshot settle in `finally` (`within`, `STOPPED_SNAPSHOT_GRACE_MS` = 2 s);
    `writeSummary` passes `deps.signal` and logs an abandoned summary at info.
  - `app.ts`: `liveReply(agent.id)`; the `mcp` dep awaits `homeReady` before `openMcp`.
  - `loop.test.ts`: five tests (rename mid-drain, stop during summariser, first call before
    the snapshot with the tool after it, MCP after the snapshot, stop while a tool waits on a
    snapshot that never returns), plus helpers `settlesWithin`, `untilAborted`, `slowSnapshot`.
  - `docs/architecture.md`: the four sections above.
- **Key decisions:**
  - Every tool call waits for the snapshot, not a list: `remember`, `spawn_task_worker` and
    others write into the home too. In practice the snapshot finishes long before the model
    answers.
  - With an MCP server configured the first model call still waits, because the tool list must
    be fixed before it. This is documented as a known limit.
  - `liveReply` takes the agent id rather than a name. NEXT_SLIDE asked for name-taking; the
    module has no db to resolve a name, there is one caller, and the route is unchanged.
  - A stop during the snapshot answers the waiting call `error: stopped by the owner` and then
    halts, so every call still has its result.
- **Notes / leftovers:**
  - The summariser's tokens are still not counted (a later DoD item).
  - Stop during `homeTail` (the home load) is still not interruptible; it is a short read.
  - Pre-existing window in the owner rename route (`app.ts` `PATCH` → `moveAgent`): it checks
    `runner.running`, then awaits `desktop.stop`/`desktop.rename` before `renameAgent` writes
    the row. A `runner.start` (schedule, message) in those seconds launches on the old row
    while the Linux user is being retired and moved. Closing it needs a runner "hold" API.
  - The real `exec` SIGTERMs `sudo`; whether `tar` under `bash -c` exits on it is not verified
    on the harness. The 2 s grace bounds it either way.
- **Negative controls (each made its test fail, then restored):** the drain using the
  first-round row (rename test); no signal to the summariser (summariser stop test); `await
  snapshot` before MCP (first-call test and the stuck-snapshot stop test); no gate on tools
  (first-call test and the stuck-snapshot stop test).
- **Runtime-unverified:** `infra/smoke.sh` and `check.sh` were not run; no infra change.

## Slice: 6 — model context window and vision, window-sized compaction, overflow retry
- **Shipped:**
  - `schema.ts` + migration `0032_model_capabilities.sql`: `context_window` and `vision`. The
    upgrade simulation (0031 → 0032 with a row) gave `null`/`1` and an empty `foreign_key_check`.
  - `shared` `ModelEntry`/`ModelUpdate`, `models.ts` (`ModelFields`, `toEntry`, `config()` →
    `vision: false`, `contextWindowFor`), `app.ts` `modelFields` validation.
  - `provider.ts`: `ProviderError.overflow`, `isContextOverflow`, `NO_VISION`, `wire(…, vision)`.
  - `loop.ts`: `CHARS_PER_TOKEN`, the reserve constants, `compactionBudget`, `overflowBudget`,
    `summariseHead`, `newestReplay`, the overflow retry in `runAgent`, `writeSummary` input and
    output sized to the budget. `keepEnd` now counts its marker and handles a limit of ≤ 0.
  - `infra/provider-stub.py`: the `STUB_MAX_CHARS` overflow mode, and a summariser answer.
  - Tests:
    - `loop.test.ts` (5): 32k fit with an unknown-window control; overflow mid-turn keeps a
      message that arrived meanwhile; a second overflow fails; an inherited big summary still
      fits; switching to a non-vision model with screenshots in history.
    - `provider.test.ts` (2): overflow classification; the vision wire.
    - `provider-stub.test.ts` (2, real python stub): compaction plus a successful retry, and a
      second refusal failing the turn.
    - `api.test.ts` (1): routes, defaults, an older-app body, null clears, validation.
- **Key decisions:**
  - Vision is handled in the request builder, not in `transcript`. It is one choke point, the
    backup's config carries its own flag, and stored history is untouched.
  - The window is a ceiling: budgets are capped at the old 400k/260k, so a big model's cost
    does not change.
  - Fixed reserves (reply ≤ 8 192 tokens, 3 × 1 600 per image, 24 000 schema chars), so
    `contextFullness` uses exactly the turn's budget without knowing the tool list.
  - The capability lookup happens in the loop from the db (`deps.idle?.modelId ??
    modelIdFor`), the same resolution `agentProvider` uses. No new `LoopDeps` field.
  - The forced cut is limited to rows `<= since`. Without that limit, a message another sender
    wrote mid-turn would be summarised past and lost (advisor catch; the test proves it).
- **Placeholder choices:**
  - `CHARS_PER_TOKEN` = 3, and the three reserves;
  - the 400k cap for large windows, and the 8k floor;
  - the overflow budget at a quarter;
  - the `NO_VISION` wording;
  - the overflow phrase list in `provider.ts` `OVERFLOW`;
  - the carried "story so far" capped at half the budget.
- **Notes / leftovers:**
  - The app has no UI for the two fields. Note this for the app slice (Settings).
  - Known limit: within one turn, the last 8 full tool results (16k per stream) or large MCP
    schemas can exceed a 32k budget by themselves. Such a turn overflows twice and fails.
  - A mid-turn switch to the backup keeps the primary's budget; only the overflow retry covers
    it. The vision flag does follow the backup.
  - `contextFullness` now does a model row lookup per agent on every `GET /api/agents`. Feed
    this into the "cache or store contextFullness" DoD item.
  - A screenshot past the image window still says "Take a new one to see the screen" on a
    non-vision model. Harmless, but slightly off.
  - A turn can now make two summariser calls (start and forced). Summariser token counting
    must count both.
  - smoke never compacts, so the stub's new summariser answer changes no smoke assertion
    (checked by grep).
- **Negative controls (each made its test fail, then restored):**
  - cuts not limited to `since` → the mid-turn message test;
  - the vision check removed from `wire` → the switch test;
  - budget forced to `null` → the 32k test;
  - the retry branch disabled → both stub tests;
  - the story-so-far cap removed → the inherited-summary test.
- **Runtime-unverified:** no real endpoint has seen the overflow wording or a request without
  images. `smoke.sh` and `check.sh` were not run (no infra change beyond the stub).

## Slice: 7 — finish_reason, summariser tokens, redaction across a restart, backup-retry rules
- **Shipped:**
  - `provider.ts`:
    - `FinishReason` and `ChatReply.finish`, from the streamed path (the last non-null value,
      including chunks with no `delta`) and the plain path;
    - `ChatReply.modelId` and `ProviderError.modelId`, tagged in `withRetries`;
    - the attempt counter restarts on a switch to the backup.
  - `models.ts` `backupConfig`: a backup with a recorded auth refusal is not offered.
  - `loop.ts`:
    - `CUT_OFF`, `CALL_CUT_OFF`, `CUT_OFF_AGAIN` and the `length` handling in `runAgent`;
    - `Meter` threaded through `compact` → `summariseHead` → `writeSummary`, with usage/metered
      hoisted above the turn-start compaction and `summaries` added to the `turn` event;
    - `follow()`/`switched`: the budget follows `reply.modelId` and `error.modelId`;
    - `compactNow` returns `usage`.
  - `app.ts`: `loadHidden` at creation, `hideFromAgent(db, masterKey, …)`, the
    `owner compaction tokens` log.
  - `forms.ts`: a WeakMap-per-Db cache, `loadHidden`, persisted `hideFromAgent`, and
    `MAX_HIDDEN_VALUES` = 200. The `ponytail` comment is gone.
  - `schema.ts`: `hiddenValues`, migration `0033_hidden_values.sql` (generated, only the new
    table). `agents.ts` deletes the row with the agent.
  - `infra/provider-stub.py`: the `STUB_FINISH=length` mode.
  - Tests (16):
    - `provider.test.ts` (4): finish_reason in both paths, the model tag on reply and error,
      the backup's own attempt count, and a refused backup key that fails at once and is
      reported against the backup.
    - `loop.test.ts` (7): text cut off (also empty text), a cut-off call not run and asked
      again, a second cut-off failing the turn, summariser tokens in the `turn` event and
      `idle.end` (start plus forced), `compactNow` usage, a switch to a small backup
      compacting before the next step, and an overflow on the backup's first call using the
      backup's budget.
    - `forms.test.ts` (2): restart (file db reopened, a cold cache, then `loadHidden`, stored
      encrypted, deleted with the agent) and the 200 cap.
    - `api.test.ts` (2): redaction across a restart through `createApp` and a real
      `run_command` result; a refused backup failing the turn and no longer being offered.
    - `provider-stub.test.ts` (1): the `STUB_FINISH=length` turn, where the command never runs
      and the follow-up is `valid=yes`.
  - Docs: the four architecture sections above, plus `docs/configuration.md` (`extraBody` and
    `models.backup` rows, and a `## Context compaction` paragraph).
- **Key decisions:**
  - A cut-off text reply is **marked, not continued**. It is bounded with no loop, and the owner
    can say "go on".
  - A cut-off tool call is **kept**, with its args sanitised to `{}`, and answered. Dropping it
    would leave an assistant→assistant pair, which is the strict-template problem of the next
    slice. Raw partial JSON would break endpoints that parse `arguments`.
  - Redaction uses **encrypted values, not keyed hashes**. Hashes cannot be found inside
    arbitrary text without hashing every window of every result. `form_vault` only holds
    values the owner ticked Remember for.
  - A backup's refused key **still fails the turn**: it is documented 401 behaviour and is
    pinned by a test, not changed. The fixes are the attempt reset, not offering a refused
    backup, and the budget following the answering model.
  - Owner `/compact` usage is **log-only**. A `turn` event with 0 model calls would read wrong
    in the app (`Readable.swift`), and a new `EventType` would break older app builds.
- **Placeholder choices:**
  - the `CUT_OFF`, `CALL_CUT_OFF` and `CUT_OFF_AGAIN` wording;
  - marking instead of continuing;
  - one retry per turn after a cut-off call;
  - `MAX_HIDDEN_VALUES` = 200;
  - encrypted storage over hashes;
  - log-only `/compact` usage.
- **Notes / leftovers:**
  - `turnOn` in `provider-stub.test.ts` uses `apiKey: 'k'`, so `withoutKey` turns every `k`
    in an error body into `[redacted]` ("to[redacted]ens"). Use a distinctive key before
    asserting on error bodies.
  - `waits` in `app.ts` is still keyed by agent name, so a rename mid-wait loses the retry
    levers. This was pre-existing and is out of scope.
  - The summariser ignores its own `finish` (a cut-off summary is kept as is, and already
    clipped).
- **Negative controls (each made its test fail, then restored):**
  - no `meter` in `writeSummary`;
  - no `follow(reply.modelId)`;
  - no `follow(error.modelId)`;
  - `cutOff` forced false (both the loop tests and the stub test);
  - no second-cut-off throw;
  - no `finish_reason` read in the stream;
  - no attempt reset;
  - no refused-backup skip in `backupConfig`;
  - no `hidden_values` write;
  - no `loadHidden` in `createApp`.
- **Runtime-unverified:**
  - no real endpoint has sent `finish_reason: "length"`;
  - `smoke.sh` and `check.sh` were not run. `STUB_FINISH` is unset by default and smoke never
    compacts, so no smoke assertion changes.

## Slice: 8 — real-provider wire compatibility
- **Shipped:**
  - `provider.ts`:
    - `Echo`, `ChatReply.echo`, `ProviderMessage` assistant `echo`; collected in both paths
      (`reasoning_content`, `reasoning_details` merged by `index`, `tool_calls[].extra_content`);
    - `wire` takes a `Dialect` (`vision`, `source`, `gemini`) and echoes only to the same source;
      `UNSIGNED_CALL` on the first call of an unsigned step, on a Google host only (`googleHost`),
      never on a proxy matched by model name;
    - `alternate()` after `wire`; `geminiSchema()` and `isGemini()` for tool parameters;
    - `dataLines` skips empty `data:`; `mergeToolCallDeltas` keeps `{ slots, open }` and slots
      index-less chunks by id.
  - `schema.ts` `messages.echo`, migration `0034_provider_echo.sql` (generated, one `ALTER
    TABLE … ADD`). `conversations.ts`: `NewMessage.echo`, `StoredMessage`, `toStored` used by
    `listMessages` only.
  - `loop.ts`: the assistant row stores `reply.echo`; `transcript` replays it;
    `projectedChars` counts it.
  - `infra/provider-stub.py`: the SSE answer path (`stream()`), seven quirk modes (see header),
    `refusal()`/`schema_problem()`/`decorate()`, and `heard()` over every text part and line.
  - Tests (18): `provider-stub.test.ts` (7, one per mode; the strict-schema test carries its
    own negative run on a non-Gemini model) and `provider.test.ts` (11: empty data lines,
    index-less deltas incl. a repeated id and two ids in one chunk, echo from a stream and from
    plain JSON, echo only to its source, the Gemini stand-in signature, `alternate` incl. an
    image and tool order, the request merge, `geminiSchema` incl. `properties` named
    `pattern`/`format`, `$ref`/`$defs`, the original unchanged, a recursive `$ref`, `isGemini`).
  - Docs: `### The model provider` quirks bullet; `docs/configuration.md` `### Endpoint notes`
    (vLLM, Ollama, Gemini).
- **Key decisions:**
  - **DeepSeek, against the brief:** its thinking-mode docs say that with `tools` in the request
    the `reasoning_content` of *all previous turns* must be passed back, or 400. A within-turn
    echo would break every second turn, so it is sent on every replayed reply that has it. The
    test runs two turns; a "tool-call rows only" control fails it.
  - **Echo tagged by source** (`baseUrl` + `model`): a backup or a new model never gets fields
    or signatures from another one. A Google host then gets `UNSIGNED_CALL` instead. A proxy
    matched only by model name does not, because adding a field is riskier than dropping a hint.
  - **Echo in its own column, not in the `tool_calls` JSON**, which the app reads. Only the
    loop's reader maps it.
  - **Merging is always on**, not a per-model flag. It changes no content, and text stays a
    string unless an image is involved.
  - **Gemini detection by host or model name** (`/gemini/i`), so proxies are covered and the
    stub can test it. No model flag, no migration.
  - Ollama: verified (Ollama docs) that `/v1` has no per-request `num_ctx`, so the notes say
    `OLLAMA_CONTEXT_LENGTH` or a Modelfile, plus a matching `contextWindow`.
- **Placeholder choices:**
  - the env var names and the stub's refusal wording;
  - the blank-line joiner in `alternate`;
  - the `MAX_REF_DEPTH` of 8;
  - the 32768 example in the Ollama notes.
- **Notes / leftovers:**
  - Assistant rows with no stored reasoning (older rows, `STOPPED`, other models' replies) go to
    DeepSeek without `reasoning_content`. Whether DeepSeek accepts that is unverified.
  - The rules for streamed `reasoning_details` are not fully specified. OpenRouter's docs say
    to concatenate pieces "in order"; merging by `index` is my reading of that.
  - Gemini may also refuse an object schema with empty `properties`. Not handled, and
    unverified.
  - `listMessagesWithoutImages` (the fullness estimate) does not read the echo, so
    `contextFullness` slightly undercounts a DeepSeek thread.
- **Negative controls (each made its test fail, then restored):**
  - no empty-`data:` skip;
  - index-less chunks forced to slot 0;
  - echo only on rows with tool calls (the DeepSeek all-turns rule);
  - no `reasoning_content` in `wire`;
  - no `extra_content` echo;
  - `reasoning_details` appended rather than merged;
  - no `alternate()`;
  - no Gemini schema rewrite.
- **Runtime-unverified:**
  - no real endpoint has been called;
  - `smoke.sh` and `check.sh` were not run. The stub's default answer path is unchanged, but
    `heard()` now also finds senders in merged messages and image messages, and the daemon now
    merges consecutive user messages. Smoke's `heard=` checks are all "contains", so they
    should hold.
  - **Owner, run these when an endpoint is at hand** (the two `[user-gated]` lines). Add the model in the app, then
    message an agent "take a screenshot, then run `uname -a`, then tell me both":
    - OpenAI or OpenRouter: base URL `https://openrouter.ai/api/v1`, model
      `google/gemini-3.8-flash` (unverified id: check the exact one on openrouter.ai/models).
      Gemini via OpenRouter exercises `reasoning_details` and the schema rewrite. Then send a
      second turn in the same thread.
    - DeepSeek: `https://api.deepseek.com`, model `deepseek-flash`, `extraBody`
      `{"thinking":{"type":"enabled"}}`; two turns in a row (the second proves the replay).
    - A local model: vLLM started as in `docs/configuration.md`, or Ollama with
      `OLLAMA_CONTEXT_LENGTH=32768` and `contextWindow: 32768`.
    - Watch `docker compose logs -f schermes | grep -i "provider returned"` for any 400.


## Slice: 9 — login and session hardening
- **Shipped:**
  - `auth.ts`:
    - `hashPassword`/`verifyPassword` are async (`crypto.scrypt` on the thread pool), with the
      stored format unchanged; `claimOwner`/`checkPassword` are async;
    - `createLoginGuard` (per address: 5 free failures, then 1 s doubling to a 5-minute cap,
      bounded at 10,000 entries, least recently failed dropped first);
    - `clientIp` (the TCP peer; `X-Forwarded-For`'s rightmost entry only from a loopback peer,
      `::ffff:` stripped);
    - `cameOverTls` (`X-Forwarded-Proto: https`, or an https URL);
    - `issueSession` sweeps expired rows, writes `last_seen_at` and `user_agent`, and sets
      `Secure` when `cameOverTls`;
    - `sessionValid` refreshes `last_seen_at` at most once a minute;
    - `dropSession(c, db, id)` deletes the row and `deleteCookie`s (`Max-Age=0`, `Path=/`, same
      `Secure`);
    - `newSetupToken`/`tokenMatches` (length check, then `timingSafeEqual`).
  - `schema.ts` sessions `lastSeenAt`/`userAgent`, both nullable; migration
    `0035_session_details.sql` (generated, renamed from `0035_famous_ezekiel`).
  - `app.ts`:
    - `MAX_API_BODY_BYTES` = 40 MB, one `bodyLimit` on `/api/*` ahead of the session guard,
      answering 413;
    - setup: backoff check, then 409 if an owner exists, then the `setupToken` body field (403
      `setup token required: it is printed in the daemon log`, counted as a failure), then the
      password; the token is cleared on success;
    - login: 429 + `Retry-After` while backed off, `fail`/`succeed` around `checkPassword`;
    - `AppDeps.setupToken`/`loginGuard`, and `createApp` returns `setupToken`.
  - `main.ts` logs `first-run setup token` with the value under `code`. `log.redact` hides any
    field named `*token*`.
  - `infra/smoke.sh`: on a fresh daemon it asserts the 403 without a token, then reads the token
    from `docker compose logs --no-log-prefix schermes` (newest line, `jq .code`), or from
    `SCHERMES_SETUP_TOKEN`. The second-setup check sends a token too, and still expects 409.
  - Tests, in `api.test.ts`: 13 new, plus the hash test made async. The fixture passes
    `setupToken: SETUP_TOKEN` and returns `desktop`, and all 52 setup posts carry the token.
    - the token is required, and a wrong one is refused;
    - a boot with no owner generates a token, and one with an owner has none;
    - a 16-login burst doesn't stall health: health answers before any login settles;
    - backoff: 429 with `Retry-After`, the right password refused while backed off, another
      address unaffected, doubling then capped, a success resetting it;
    - XFF from loopback versus a remote peer;
    - the table's bound;
    - setup-token guesses count as failures;
    - one row per login plus the sweep, with UA and last-seen;
    - Secure on XFP, https or a mixed-case list, and not on plain http;
    - logout clears the cookie and deletes the row;
    - 413 with a declared length and with a streamed body; a full 25 MB share with escaped
      slashes (33,854,200 bytes) passes;
    - a hash written by the old `scryptSync` still verifies.
  - Docs:
    - `docs/architecture.md` › `### Owner authentication`, covering async scrypt, backoff, XFF,
      sessions, Secure and the body limit; the security-model paragraph rewritten for the
      token; a `## Clients` bullet on `setupToken` and what an older build sees;
    - `docs/deployment.md`: the claim steps, the curl call, `journalctl` and the Unraid log;
    - `docs/troubleshooting.md`: 403 setup token, 429, 413, and the Secure-cookie entry
      rewritten;
    - `README.md`: the claim and dev steps.
- **Key decisions:**
  - **XFF only from loopback.** Trusting private ranges would let any LAN client, or every
    client on Docker Desktop, where all of them arrive from the gateway, rotate addresses and
    never back off. The cost: the compose `domain` profile's Caddy reaches the daemon over the
    compose network, so everyone behind it shares one count. The cap was cut from 15 to 5
    minutes for that reason, existing sessions are unaffected, and a trusted-proxy setting is
    the recorded upgrade path.
  - **XFP trusted from anyone.** A forged `https` only makes the forger's own cookie Secure.
  - **Body limit 40 MB**, from `MAX_FILE_BYTES` (25 MB): 33.3 MB of base64, plus about 1.6%
    because Swift's `JSONEncoder` escapes `/`. That makes 33.9 MB on the wire. 64 KiB of slack
    would have refused real shares.
  - **Token in the body (`setupToken`)**, not a header, because that is the app's simplest
    shape. The 409 for an existing owner comes before the token check, so smoke's
    attacker-password check keeps its meaning. The token lives in memory only, and a new one is
    printed every boot without an owner.
  - Backoff covers setup-token guesses too (they share `loginGuard`).
- **Placeholder choices:**
  - the backoff numbers: 5 free, 1 s base, 5-minute cap, 10k entries;
  - the 24-byte token (32 base64url characters);
  - the log message `first-run setup token` and the field `code`;
  - the 403, 429 and 413 wording;
  - the 60 s last-seen resolution and the 300-character UA cap.
- **Notes / leftovers:**
  - **Capability regression:** the app's setup screen sends no token, so the shipped app can't
    claim a fresh daemon (403 with an actionable message). Until the field lands the workaround
    is curl (`docs/deployment.md`). The field is recorded on the Settings DoD line.
    `Session.swift` `.setup` → `SchermesClient.setup(password:)` needs a `setupToken`
    parameter and a field.
  - **smoke.sh is stale since slice 4:** "a turn above the loop cap is refused with an error
    that names the cap" (around line 1461) still expects 429, but at the cap a turn is now
    taken (202) and queued. Smoke fails there; everything before it passes.
    - Fixing it means deciding what the queued turn for smoke-one does once the second daemon
      is `kill -9`'d: the next daemon's sweep would run it.
    - Not touched, being outside this slice.
  - "One row per login" already held. The slice added the sweep and the listing columns.
  - The negative control "clear without `path: '/'`" could not fail: Hono's `setCookie`
    defaults `Path=/`. The explicit path stays, for clarity.
- **Negative controls (each made its test fail, then restored):**
  - synchronous `scryptSync` (health waited behind the logins);
  - no backoff check;
  - success not resetting;
  - XFF trusted from anyone;
  - XFF never trusted;
  - an unbounded table;
  - token guesses not counted;
  - no token check;
  - no sweep;
  - never Secure;
  - always Secure;
  - no cookie clear;
  - no body limit;
  - a limit of 33.4 MB, too tight for escaped slashes.
- **Verification:**
  - `pnpm check` → 0.
  - `pnpm test` → 0: 379/379, none skipped. The burst test was repeated 6 times, all passing.
  - `smoke.sh` ran on the throwaway `smoke` project (port 7779, fresh volumes), on a rebuilt
    image → 1.
    - The new steps passed: `setupRequired=true`, the 403 without a token, the token read from
      `docker compose logs`, setup 201, the second setup 409, login.
    - So did the 70 sections after them, including the sandbox isolation battery and the second
      daemon reusing the session.
    - It then failed at the stale loop-cap check above.
    - `down -v` on the smoke project afterwards.
- **Runtime-unverified:**
  - the rest of smoke after the loop-cap check (restart recovery, rebuild survival);
  - `check.sh`, which was not run (no desktop change);
  - the app against the new daemon. Login is unchanged for it, but setup on a fresh daemon is
    a 403 by design (above).

## Slice: 10 — account security, and smoke repaired
- **Shipped:**
  - `daemon/src/account.ts` (new):
    - RFC 4226/6238 `hotp`, `totpStep`, `matchingStep` (±1 step, `timingSafeEqual`), RFC 4648
      `base32Encode`/`base32Decode`, `otpauthUri`;
    - TOTP state on the owner row: `beginTotp` (pending, encrypted with the master key),
      `confirmTotp` (atomic step spend, then ten recovery codes), `checkSecondFactor` (TOTP
      or a recovery code, spending it), `disableTotp`, `totpStatus`;
    - `sessionHandle` (16 chars of base64url SHA-256), `listSessions`, `sessionByHandle`,
      `revokeSession`, `changePassword` (one transaction: new hash, delete every other session);
    - `recordAudit` (prunes past 10,000 rows or 90 days on every write), `listAudit`.
  - `schema.ts`: `owner.totp_secret`/`totp_pending`/`totp_last_step`, `recovery_codes`,
    `audit_events` (index on `at`). Migration `0036_account_security.sql` (generated as
    `0036_blushing_vanisher`, renamed with its journal tag).
  - `app.ts`:
    - `POST /api/auth/password {current, next}`; `GET /api/auth/sessions`;
      `DELETE /api/auth/sessions/:handle`; `GET /api/auth/totp`;
      `POST /api/auth/totp/setup {password}`; `POST /api/auth/totp/confirm {code}`;
      `DELETE /api/auth/totp {password, code | recoveryCode}`; `GET /api/audit?before=&limit=`;
    - `reauthenticate`: a password check behind the session guard that shares `loginGuard`
      (429 while backed off, 403 on a wrong password);
    - login: the right password with TOTP on and no code → `401 {error, totpRequired: true}`,
      no session, not counted; a wrong code or recovery code counts; the `login` audit row
      says which method;
    - `AUDITED_WRITES` plus one middleware after the session guard, recording 2xx writes only;
      `PUT /api/settings` records field names only;
    - `AppDeps.now` (default `Date.now`) for the TOTP clock and audit timestamps.
  - `shared/src/index.ts`: `LoginError`, `SessionEntry`, `TotpStatus`, `TotpSetup`,
    `TotpConfirmed`, `AuditAction`, `AuditEvent`.
  - `daemon/src/account.test.ts` (new, 16 tests):
    - the RFC 6238 vectors at 8 and 6 digits, RFC 4648 base32, the ±1 window;
    - every new route is behind the session guard;
    - password change: the wrong current (403), a short next (400), other sessions gone and
      the caller kept, old password refused, guesses back off to 429;
    - the session list never contains a raw id, marks `current`, hides expired rows; revoke
      another (its cookie 401s), unknown handle 404, revoke your own clears the cookie;
    - enrolment needs the password, the pending secret is encrypted, a wrong confirm is 400,
      ten distinct codes, stored hashed, status, 409 when already on;
    - TOTP login: password alone 401 `totpRequired` with no cookie and no row; a wrong
      password says nothing about TOTP; the confirm code and a used step are refused again;
      a recovery code works once (any case, dashes or spaces) and is audited; wrong codes of
      both kinds count toward the backoff;
    - disable needs the password plus a code; a recovery code works; afterwards the password
      alone logs in;
    - audit: exact newest-first order of auth events and owner writes, a failed write and the
      reads unrecorded, no api key value anywhere, field names, paging with `before`, 400s for
      bad `limit`/`before`; the row and age bounds.
  - `infra/smoke.sh`:
    - **the loop-cap repair.** The stub is switched to `memory` (everyone reports at once)
      before the over-cap post. The post asserts 202, the second daemon's
      `turn queued at the loop cap` line for smoke-one's `message`, then `settle smoke-one`, a
      new `queued turn started` line for it in the **container** daemon's log, and an
      assistant row after the queued message. All of that happens before the `kill -9`, so the
      reconcile steps after it see an empty queue;
    - a new read-only step after login: the session list marks the current session by a
      16-character handle and never contains the raw id, and the newest audit row is this
      password login;
    - the closing summary line.
  - Docs: `docs/architecture.md` › `#### Account security` (under Owner authentication), a
    `## Clients` bullet on `totpRequired`, the persistence table (27 tables; `owner`,
    `recovery_codes`, `audit_events`); `docs/troubleshooting.md`: the `totpRequired` 401,
    locked out of TOTP (a `node -e` reset through `better-sqlite3` as the `schermes` user,
    tried on the smoke container), and a password change signing out the other devices.
- **Key decisions:**
  - **TOTP setup needs the password**, beyond the brief's `{code}`-only sketch. Without it a
    stolen cookie could enrol the thief's phone, and every new login and the disable would then
    need the thief's codes. Confirm needs only the code, because the setup step already proved
    the password.
  - **The password-only half of a TOTP login isn't counted** as a failure: it is step one of
    every normal login. The password was already checked, and a wrong one counts.
  - **A wrong current password is 403, not 401**, because the app treats a 401 as "signed out".
  - **The queued turn is run, not cancelled.** It can't be cancelled: the unread message would
    be requeued by any sweep. Any daemon on the DB drains the queue, so smoke now proves a
    stronger thing: a turn one daemon queued is run by another.
  - The audit bound is 10,000 rows or 90 days, pruned on every write (two indexed deletes).
    Owner writes come from one explicit table (`AUDITED_WRITES`); reads never are.
  - Recovery codes: SHA-256, not scrypt. They carry 80 random bits, so a slow hash adds nothing.
  - There is no route to regenerate recovery codes: turn TOTP off and on again.
  - Password change doesn't ask for a TOTP code. The brief didn't ask for it, and it's recorded
    as an option.
- **Placeholder choices:**
  - the code format `xxxx-xxxx-xxxx-xxxx`, ten codes;
  - the issuer `schermes` and the label `schermes:owner`;
  - the error wording ("enter the code from your authenticator app", "invalid code", "the
    current password is wrong", and the rest);
  - an audit page of 50 by default, 200 at most;
  - the action names;
  - 10,000 rows and 90 days.
- **Notes / leftovers:**
  - **Client contract:**
    - once TOTP is on, an older app build can't log in. It shows the error text, and sessions
      it already holds still work for up to 30 days;
    - the share extension and notification actions re-login with the Keychain password, which
      fails once TOTP is on.

    Both are on the Settings DoD line and in `## Clients`.
  - `AUDITED_WRITES` deliberately leaves out per-agent idle, schedules, triggers and memory
    writes. Rules are in, because they gate approvals.
  - A TOTP reset by hand (troubleshooting) bypasses the API, so it leaves no audit row.
- **Negative controls (each made its test fail, then was restored):**
  - a raw id as the handle;
  - the step spend without the `<` condition (a replay accepted);
  - a recovery code checked, not deleted;
  - other sessions kept on a password change;
  - no prune;
  - a ±2 window;
  - no TOTP gate on login;
  - a wrong code not counted;
  - setup without the password;
  - a password change without the current-password check;
  - audit values instead of names;
  - failed writes audited;
  - an own revoke without the cookie clear;
  - disable without a code;
  - the pending secret stored in plaintext.
- **Verification:**
  - `pnpm check` → 0.
  - `pnpm test` → 0: 395/395 (379 + 16 new).
  - `infra/smoke.sh` on the throwaway `smoke` project, a fresh build and volumes → **0, end to
    end**. That includes the new steps, the restart repair, the rebuild survival and everything
    after. Then `down -v` on the smoke project, and the build cache pruned.
- **Runtime-unverified:**
  - TOTP with a real authenticator app (`[user-gated]` on the DoD);
  - `check.sh`, which wasn't run (no desktop change);
  - the app against TOTP, which has no UI yet.

## Slice: 11 — owner timezone, idle tokens across a restart, concurrent trigger checks
- **Shipped:**
  - `daemon/src/timezone.ts` (new): zone validation (Intl and croner both), wall-clock parts,
    wall-clock to instant (DST gap lands after it, overlap on the first occurrence), local midnight.
  - `settings.ts`: `readTimezone`/`readTimeSettings`/`writeTimezone`. `GET`/`PUT /api/settings`
    carry `timezone`, validated before any write. A change runs `rescheduleAll`. Already
    audited as `settings_changed` with the field name.
  - `schedules.ts`: `nextRun` takes the zone; `insertSchedule`, `setPaused` and `runDue` read it.
    `schedulePrompt(list, timezone)` names the zone every turn, and `CRON_HELP` points at it.
  - `idle.ts`: the window and `tokensToday` in the owner's zone; `recordPassTokens` via the new
    optional `IdleTurn.spent`, called from the loop's `meter` (summariser included);
    `closeInterruptedPasses` called in `main.ts` after `reconcileAgents`.
  - `triggers.ts`: `runTriggerChecks` collects due rows synchronously (stamping `checked_at`),
    then settles every check concurrently, each raced against its own limit.
  - `shared`: `TimeSettings`, `IdlePassOutcome` gains `interrupted`.
  - Tests (`api.test.ts`, at the end): DST schedules in Amsterdam and New York, plus a zone change;
    the budget day and window across DST; an interrupted pass (parked second model call, then
    boot close, then a new app on the same db); a hung IMAP server plus a hung command beside a
    command trigger that fires at once. The settings round-trip test now expects `timezone`.
  - Docs: `architecture.md` (`### Scheduled tasks`, `### Idle work`, `### Triggers`,
    `### Restart recovery`, `## Clients` contract), `configuration.md` (`## Scheduled tasks`
    field table, idle default, trigger limit), `troubleshooting.md` (two new symptoms).
- **Key decisions:**
  - **Accrue, don't reconcile.** Tokens go onto the row after every metered call. Reconciling
    at boot had nothing to read from: the `turn` event is written in the same `finally` a dead
    daemon never reaches.
  - **A new outcome, `interrupted`,** rather than `ran`/`wasted` plus a reason. The app decodes
    `IdlePassOutcome` tolerantly (`.other(raw)`) and shows the raw word. The `reason` says why.
  - **Two validators for a zone.** `runDue` drops a row with no next run, so a zone croner
    refuses would delete every schedule. An unknown stored zone reads as the daemon's.
  - **Per-check limit 45 s**, above the command's own 30 s. The IMAP inner timeout is
    `min(30 s, limit)`, so a test's short limit leaves no stray timer.
  - **The zone is stored on every PUT that names it,** even when it equals the daemon zone, so a
    later `TZ` change doesn't move an owner who picked one.
- **Negative controls:** each was run and failed as expected:
  - `nextRun` without the zone: the DST test fails;
  - no `spent` hook: the restart test fails;
  - serial checks: the hang test fails (2008 ms against a 1 s limit);
  - `tokensToday` in the daemon zone: the budget-day test fails.
- **Notes/leftovers:**
  - A hung check's promise keeps running after its limit. Its late answer is ignored, but a
    command that never exits holds its process until the sandbox's own timeout kills it.
  - The pass still waits for every check to settle, at most one limit. The one-pass-at-a-time
    guard is therefore bounded.
  - The idle window test machine is in Europe/Amsterdam, so New York cases carry the negative
    controls.
  - No app UI for `timezone`. The Settings DoD line already includes it. The app still says
    "the daemon's clock" in `Routines.swift:83`, `Idle.swift:560` and `Idle.swift:643`, and in a
    doc comment at `Types.swift:862`. Those words should become "the owner's timezone" (or name
    it) in the app slice.
- **Runtime-unverified:** none. This is daemon-only; `smoke.sh` passed end to end against the
  rebuilt container.

## Slice: 12 — snapshot retention, agent-list cost and the sender index, the /computer decision
- **Shipped:**
  - `snapshots.ts`:
    - the script's `prune` mode is replaced by `sizes` (`inode size name` per snapshot file, GNU
      `find -printf`) and `remove <names…>` (names validated as digits-dash-digits);
    - `snapshot` ends by printing the `sizes` listing;
    - `snapshotsToPrune` (pure) applies age, `KEEP_SNAPSHOTS_COUNT` (50) and
      `KEEP_SNAPSHOT_BYTES` (2 GiB), dedupes inodes so a hard-linked tar counts once, and never
      caps away the newest by (mark, takenAt);
    - `snapshotWorkspace` prunes from the snapshot's own stdout. It makes a second call only
      when something must go, and skips it if the turn was stopped. `pruneSnapshots` (hourly)
      uses `sizes`.
  - `conversations.ts` `threadFingerprint`: newest id, row count, the agent's newest summary
    id, every agent's id:name. `loop.ts` `contextFullness` memoises the projected chars per
    thread (WeakMap per Db) under it and applies the budget on every read.
    `fullnessStats.projections` counts the misses.
  - `schema.ts` `messages_sender_idx`, migration `0037_messages_sender_index` (only the
    `CREATE INDEX`).
  - Tests (`api.test.ts`):
    - the retention policy (count, bytes with a shared tar, newest kept, age, junk listing);
    - a turn that prunes past the byte cap with one `remove` and no `sizes` call, after which the
      newest still previews a rewind;
    - the hourly count cap;
    - the agent list projecting once per change across appends, a compaction, a rewind, another
      agent's rename and a clear;
    - `PRAGMA index_list` plus `EXPLAIN QUERY PLAN` for the index.

    `fakeSnapshots` now answers `sizes`/`remove`, with optional per-name inode/size.
  - Docs:
    - `architecture.md`: `### Snapshots and putting files back` (retention requirement, why both
      caps, prune per snapshot, the ceiling); the background-work row; the persistence Deferred
      bullet; the `### Context compaction` memo requirement and the reason for choosing a memo;
      the sender index under `## Persistence model`; the `/computer` decision under
      `### Computer use and the terminal`.
    - `configuration.md`: the three snapshot constants in the limits table.
- **Key decisions:**
  - **Both caps.** Bytes is what fills the disk. Count bounds the many tiny snapshots of a quiet
    home. Neither alone covers both cases.
  - **The policy lives in TS, and the script only lists and deletes.** The fake exec can then
    test the policy. The bash was run for real separately.
  - **Prune after every snapshot.** The hourly pass alone let a burst of turns on a big home
    blow past the byte cap.
  - **Memo rather than a stored column.** A column would need upkeep in every
    append/delete/rewind/clear/compact/rename path, several of them bulk deletes in other modules.
    The fingerprint is correct by construction. Other agents' names are in the key because the
    transcript text carries them and a rename edits rows in place.
  - **Single-column `sender` index.** The hot queries (`queue.ts` own mark, `idle.ts`
    pre-check, owed requests, `agentChain`) filter on sender across all threads, not per thread.
  - **`/computer` is kept.** `smoke.sh` drives screenshot, click, drag, key, move, scroll and
    clipboard_read through it, and the API tests use it. The app does not call it.
- **Negative controls:** each was run and failed as expected:
  - no memo;
  - no names in the fingerprint;
  - no prune after the snapshot;
  - migration 0037 emptied.
- **Verification:**
  - `pnpm check` → 0, `node --test src/*.test.ts` → 0 (402 pass).
  - The script was run for real in `debian:stable-slim` (snapshot ×3 with a hard link, `sizes`
    ignoring `.new.list` and junk names, and `remove` refusing `../a.txt`). In the smoke image,
    `sizes`/`remove` were run as an agent.
  - `infra/smoke.sh` → 0 on the throwaway `smoke` project after a fresh build. Snapshots were
    written inside the sandboxes, and the log has no snapshot failures. The project was then
    taken down with `down -v`, `smoke-schermes` removed, and the build cache pruned.
- **Notes/leftovers:**
  - Per-file sharing between snapshots (`rsync --link-dest` style) was not cheap: it means a
    tree per snapshot and a different restore. The ponytail note stays.
  - The memo is per process, so the first poll after a restart projects every thread once.
  - Smoke does not assert pruning itself. The unit tests and the manual container runs cover it.
- **Runtime-unverified:** none (daemon only).


## Slice: 13 — message images as files, a resumable move, screenshot retention, expired placeholder
- **Shipped:**
  - `daemon/src/images.ts` (new):
    - `storeImage` writes a content-addressed file at `$DATA/images/<sha[0:2]>/<sha256>`
      (temp, `fsync`, rename, deduped) and returns the `image_ref` JSON;
    - `resolveImage` reads either column back to `Image`. A missing or bad file, or a bad sha,
      reads as `{mediaType, base64: '', expired: true}` and never throws;
    - `moveImageBatch`/`moveImagesToFiles`/`startImageMover` walk by id cursor, write the file,
      then run one `UPDATE … SET image_ref, image = NULL`;
    - `pruneImages(db, now, days)` expires non-owner rows past the window, bumps `imageEpoch`,
      then `sweepImageFiles` unlinks every file no `image_ref` names;
    - `startImagePruner` runs at boot and hourly.

    The directory sits beside the db file. For `:memory:` dbs it is a per-Db temp dir, removed
    on exit.
  - `schema.ts` `messages.imageRef` and migration `0038_image_files` (only the `ADD COLUMN`;
    renamed from the generated tag, journal updated).
  - `conversations.ts`:
    - `appendMessage` stores through `storeImage`;
    - `toMessage(db, row)` resolves;
    - `listMessagesWithoutImages` marks `{}` or `{"expired":true}`;
    - `threadFingerprint` includes `imageEpoch`. Its docblock now names the in-place edits.
  - `loop.ts` `transcript`: an expired picture becomes a text line ("…has expired and was
    deleted. Take a new one…") and is left out of the `MAX_REPLAYED_IMAGES` window.
  - `provider.ts`: `Image.expired?`; an image with empty bytes is never sent as `image_url`.
  - `search.ts` OCR selects both columns, reads through `resolveImage`, and marks expired rows
    with empty text.
  - `settings.ts`: `readImageRetentionDays`/`validImageRetentionDays`/`readImageSettings`/
    `writeImageRetentionDays`, `DEFAULT_IMAGE_RETENTION_DAYS` 30, `MAX_IMAGE_RETENTION_DAYS`
    3650. `app.ts` `GET`/`PUT /api/settings` carries `imageRetentionDays`, and anything outside
    0..3650 integers is a 400. `main.ts` starts the mover and the pruner.
  - `shared`: `ImageAttachment.expired?`, `ImageSettings`, `ImageSettingsUpdate`.
  - Tests:
    - `images.test.ts` (new, 5): file store and dedupe; a move interrupted between the file
      and the row at row 53 of 60 (past a batch boundary), then resumed, with exact read-back
      and a malformed legacy row left alone; retention (owner kept, a shared file kept until
      its last row, legacy rows expired, 0 days, orphan sweep); missing file or bad sha read as
      expired; the transcript and the provider body (3 `image_url`s, no empty `data:`, the
      expired one frees its slot, and the lean listing measures the same text).
    - `api.test.ts`: the memo test gains "prune a screenshot, then poll" (alpha projects once,
      the other thread not at all, value unchanged); a new API test covers the wire shape
      (`expired` survives `images=0`) and the setting's validation. The settings round-trip
      expects `imageRetentionDays: 30`. An OCR test: an expired screenshot is marked in
      `screenshots_fts` without reaching tesseract, the older live one is still read, and a
      second pass does nothing.
  - `infra/smoke.sh`: a new step hashes the transcript's screenshot inside the container and
    asserts `images/<sha[0:2]>/<sha>` exists, that a row names it, and that no row holds inline
    base64.
  - Docs:
    - `architecture.md`: `## Persistence model` (requirement, column shape, move, retention,
      sync invariant, VACUUM), the `### Background work` row, `### Context compaction` memo
      key, `## Clients` (two Contract bullets, `images=0` wording), the messages table row and
      the Deferred bullet.
    - `configuration.md`: `## Screenshot retention`, the limits row, the OCR note.
    - `troubleshooting.md`: the db not shrinking (manual `VACUUM`), and "a screenshot shows as
      expired".
- **Key decisions:**
  - **A new `image_ref` column, not JSON variants in `image`.** A rolled-back daemon then sees
    `image` NULL and shows no picture. With variants it would emit `{mediaType, sha256}` with no
    `base64`, and the app's non-optional `Base64Image.base64` would fail the whole page's decode.
  - **Owner = `role 'user'` with no sender.** That includes the recording hand-over's picture
    (the agent's screen, posted as the owner's line), which is therefore kept forever. Forwards
    carry no image, and system rows have none.
  - **One sweep frees files.** It covers shared files, cleared or rewound threads and crash
    leftovers, so nothing counts references. It is race-free because store+insert and
    live-set+unlink each run in one synchronous tick (commented in `images.ts`).
  - **An in-memory `imageEpoch` per thread** rather than a column. The memo is per process
    anyway, and only the pruner expires pictures.
  - **0 days = keep forever.** Expired text read by OCR before the prune stays searchable.
  - **No automatic VACUUM.** It needs free disk the size of the db, and the Docker VM disk
    already fills up.
  - The API still serves base64 inline, read from the file, so the wire is unchanged apart from
    `expired`.
- **Negative controls:** each was run and failed as expected:
  - no epoch in the fingerprint;
  - an expired picture kept in the visible window;
  - the row updated before the interrupt point;
  - the owner exclusion dropped;
  - the sweep ignoring the live set;
  - the provider's empty-bytes guard removed;
  - OCR skipping an expired row without marking it.
- **Verification:**
  - `pnpm check` → 0, and `pnpm -r check` → 0.
  - `node --test src/*.test.ts` → 0 (409 pass).
  - `infra/smoke.sh` → 0 on the throwaway `smoke` project after a fresh build. The new step
    found `images/16fc…`, and the screenshot files survived the restart and rebuild steps.
    Afterwards: `down -v`, `docker rmi smoke-schermes`, build cache pruned (4.2 GB).
- **Notes/leftovers:**
  - **Before deploying slices 2-13 to the real server:** the pruner runs a pass at boot. The
    first boot of this build expires every agent screenshot older than 30 days, before the
    owner can change `imageRetentionDays` (no app UI yet). For legacy rows that drops the inline
    base64 for good. This is the spec's default. Setting the value with curl after boot is too
    late for that first pass, so back up `schermes.db` first if old screenshots matter.
  - Readers still read every picture file of a thread on each `listMessages` (the loop does it
    every round), at the same I/O cost as the old SQLite blobs. `pageMessages` with `images=0`
    reads the file and then drops the bytes. Both could resolve lazily if it ever shows up.
  - The move was proven by unit tests. Smoke runs on a fresh db, so no legacy rows were moved
    in a container.
  - The app draws nothing for an expired picture today (empty bytes decode to nil). The
    "screenshot expired" placeholder and the retention setting UI belong to the app slices.
- **Placeholder choices:**
  - the expired-line wording in the transcript;
  - 0 = keep forever, and the 3650-day max;
  - the setting key `images.retentionDays`;
  - the troubleshooting wording.
- **Runtime-unverified:** none on the daemon (smoke exercised the file store end to end). No
  app changes.

## Slice: 14 — app auth: setup code, TOTP login, single re-login, logout race, forget, tolerant enums
- **Shipped:**
  - Setup screen: a "setup code" field sent as `setupToken` (trimmed); the 403 text is shown.
  - Login: `totpRequired` shows a code field plus a "Use a recovery code" switch; it sends `totp` or
    `recoveryCode`. A wrong password now says "invalid password", not "the session expired". A 429
    shows the daemon's text and disables the button for `Retry-After`.
  - Share extension/notifications with TOTP: on iOS the cookie store is the app group's
    (`SchermesClient.cookieStore`, gated on `containerURL` being non-nil, old cookies copied over
    once). `StoredDaemon.run` throws `.signInInApp` ("Open Schermes and sign in again.") when the
    stored password can't sign in. Recorded in `## Clients` (Decision) and `apple/README.md`.
  - `Session`: single-flight re-login; epoch guard; `logOut()` and `forgetServer()` change the
    phase first, then unregister the device, call logout and clear the stored password (forget
    also drops the address). Fixed the stale DaemonPage footer and comment.
  - Tolerant enums: `TolerantEnum` (nonisolated protocol) on AgentState, MessageRole,
    FeedbackRating, EventType, TriggerState, McpServerSummary.Transport (`.unknown`) and
    ApprovalKind (unknown → `.action`). Switches updated (Readable, Thread, Theme, Markdown,
    Routines, Triggers, ChatView, Activity, AgentBloub, ThemeTests). An MCP draft with an unknown
    transport throws on encode.
  - `Base64Image.expired`; `ScreenshotView` draws "screenshot expired".
- **Key decisions:** share the session cookie instead of a code field in the share sheet (the
  session is a fixed 30 days). ComputerActionName, ScrollDirection and TriggerAction stay strict,
  since they are only ever sent and never decoded.
- **Notes/leftovers:**
  - Logout still clears the Keychain password, as before; only the copy was wrong.
  - With TOTP on, the app itself asks for a code when the 30-day session ends. The silent re-login
    fails and the gate shows the password field first, then the code field after the password.
  - The older-page retry is still open.
  - Build warnings in Triggers.swift:257 and Sidebar.swift:199 were there before this slice; they
    belong to the concurrency-warnings slice.
  - Live test recipe: fresh `SCHERMES_DATA_DIR`, `SCHERMES_PORT=<spare> node src/main.ts`, grep
    the `code` from the log, then `TEST_RUNNER_SCHERMES_LIVE_AUTH_ADDRESS=127.0.0.1:<port>
    TEST_RUNNER_SCHERMES_LIVE_AUTH_CODE=<code> xcodebuild test …`. It passed: claim with a wrong
    code then the right one, TOTP enrol via the routes, login with a code (next step) and with a
    recovery code.
  - Mutation check: dropping the single-flight join or the epoch check fails the matching tests.
- **Placeholder choices:** gate copy ("setup code", the TOTP/recovery prompts, "Use a recovery
  code"/"Use the authenticator code"); the monospaced code field, number pad and `.oneTimeCode`
  on iOS; the `clock.badge.xmark` symbol and the "screenshot expired" caption; the labels for
  unknown values ("Unknown state", "questionmark.circle", "Something this app does not know yet
  happened", "Feedback").
- **Runtime-unverified:**
  - The TOTP code field and the recovery switch on screen. idb input is broken; the flow is
    covered by tests and the live test. The setup gate itself was screenshotted on a private
    simulator and shows the setup code field.
  - The group cookie store on a real iPhone (simulator builds have no group).
  - The "screenshot expired" placeholder drawn in a chat.

## Slice: 15 — Settings: account security, time zone and retention, model capabilities
- **Shipped:**
  - Settings ▸ **Account** (new category, `lock.shield`, green): `apple/Schermes/Views/Account.swift`.
    - Password: current, new, repeat; shows the 403 text; "N other sessions were signed out".
    - Two-factor: status; set up with the password; QR (`CIQRCodeGenerator`) plus the secret with
      Copy (and "Open in authenticator" on iOS); confirm code; ten recovery codes shown once with
      Copy and Share; turn off with password plus code or recovery code.
    - Sessions: user agent, "This device", seen/signed-in times; Revoke, or Sign out (confirmed)
      for the current row.
    - Audit log: 25 per page, "Load older" with `before`, title/symbol per action, detail line,
      IP and user agent; refusals in the failed colour.
  - Daemon page: time zone (the daemon's, plus "Use this device's (X)") and screenshot retention
    in days, with their own Save. Address and Log out stay visible when settings can't be read.
  - Model editor: Context window (blank = unknown) and "Sees images".
  - Client/types: `SessionEntry`, `TotpStatus/Setup/Confirmed`, `PasswordChanged`, `AuditAction`
    (tolerant), `AuditEvent`, `GeneralSettings(Update)`; `DaemonSettingsUpdate` gains `general`
    with defaulted halves.
  - Tests: `AccountTests.swift` (16 tests, `typedWholeNumber` included: fixtures, exact requests incl. the DELETE-with-body
    and query strings, Session password/revoke paths, settings and model encodings, QR). The
    env-gated live test now also changes the password, revokes a second client, enrols and turns
    TOTP off through the client, and pages the audit log. `TypesTests` new-model expectation now
    includes `vision: true`.
  - Docs: `## Clients` (Account page rules, the time zone Decision, model fields),
    `apple/README.md`.
- **Key decisions:**
  - Time zone and retention live on the Daemon page (7 tabs, not 8). The Mac sheet's min width
    went from 700 to 760 for the extra tab.
  - The zone is never prefilled from the device (see the `## Clients` Decision).
  - Revoking the own session is `logOut()`, not a DELETE of the handle, so push unregisters first.
  - A new model sends `vision` explicitly; a window only when typed.
  - The number fields (context window, retention days) are bound through text parsed on every
    keystroke (`typedWholeNumber`), not `TextField(value:format:)`. That one commits only on
    Return or losing focus: a number pad has no Return, and a Mac Save click keeps the focus, so
    the typed value never reached Save. Garbage disables Save with a note.
- **Notes/leftovers:**
  - No daemon change was needed; no contract bug found.
  - Live run: fresh daemon on port 7863, `TEST_RUNNER_SCHERMES_LIVE_AUTH_*` → passed (claim,
    wrong and right password change, `Vault.saved == [old, new]`, revoke of a real uppercase
    handle, TOTP on, code login, recovery login, TOTP off with a recovery code, audit paging).
  - The audit list loads lazily per section `.task`; it does not refresh on its own after a
    change made on the same page (reopen the page).
- **Placeholder choices:** the Account symbol `lock.shield` and green tile; all copy on the new
  sections ("Two-factor sign-in", "I saved them", "Sign this device out?", the footers); the audit
  titles and symbols per action; QR at 180 pt on a white card; "Keep screenshots for … days";
  "Capabilities", "Sees images" and the context-window footer; the Daemon page's "Clock",
  "Screenshots" and "Connection" headers.
- **Runtime-unverified:** none of the new sections were seen on screen (Mac or iOS): QR
  legibility with a real authenticator (`[user-gated]`), layout of the Account form, the Mac
  tab strip at 760 pt, the number fields as typed on a real keyboard and number pad. Client paths are proven by unit tests and
  the live test.

## Slice: 16 — error/offline banner, no try? in the polls, poll back-off and one agent list
- **Shipped:**
  - **Reachability.** `Session.reachability` (`reachable` / `unreachable(since, message)`), set in
    `run` after the epoch check: a `URLError` other than cancelled, or a proxy's 502/503/504 →
    unreachable, keeping the first `since`; any answer, a 4xx included → reachable. It assigns only
    on change. `connect()` and `logOut()` reset it. Coming back wakes every napping poll.
  - **Banner.** `TroubleBanner` (`Views/Offline.swift`): "Can't reach the daemon", the message,
    "Since HH:mm" and Retry now (`session.retryNow()` wakes every poll); otherwise the
    console's failed action with Dismiss. Shown at the top of the console's detail column (chat,
    Home, goals) and, on compact width, of the agent list; also in the Mac menu bar panel.
  - **Action errors.** ConsoleView: `failure` (action errors, user-dismissed) split from `trouble`
    (refresh errors, cleared by the next good refresh, still the empty state's text). The inspector's
    Take control shows its refusal and no longer opens the screen after one. Account's own-session
    revoke and the menu bar's refresh after an action report instead of dropping.
  - **No `try?` on polls.** Agent list, goals, read marks, previews, thread catch-up, live reply,
    approvals, mark-read, triggers card, desktop control, routines/triggers/activity pages, Idle and
    Activity models, Settings devices and MCP agents, the console's retry pages, the VNC socket.
    Chat polls fill the strip only when it is empty (`pollFailed`), and a fetch after an action
    goes through `reporting`, so it never fails the action. The console's `load` runs each part
    even when one before it failed, so one broken route can't stop the previews and the
    announcements, and then throws the first failure.
    Grep: `grep -rn "try? await session\.\|try? session\.\|try? await client\.\|try? await .*\.run" apple/Schermes`
    → exactly `Session.swift:217`, `:218` and `:369`, the best-effort sign-out and logout after a
    stale re-login. A broader `grep -rn "try?" apple/Schermes | grep -v Task.sleep` finds only
    local work (JSON/plist decoding, file reads, URL building, the RFB write, `loadTransferable`).
  - Pause guard: `Session.poll` returns before its first tick when the phase is paused
    (`pausesInBackground` is threaded through for tests), so going to the background costs no
    request. The banner's third tier is `stale:`, the console's refresh `trouble` ("Could not
    refresh"), shown below unreachable and the action failure.
  - **Scheduler.** `PollSchedule.interval(base:phase:failures:pausesInBackground:)`: active = base,
    inactive = ×5, background = nil on iOS and ×5 on the Mac; each failure doubles the wait, capped
    at 60 s and never below the phase interval. `Session.poll` runs it, and the loops are keyed on
    `PollKey(value, phase)`. The chat's catch-up poll is a separate task from `open()`, so a phase
    change doesn't reload the thread. Mac phase = scene, app in front and window visible
    (`WindowVisibility`, `NSWindow.occlusionState`).
  - **Fan-out collapsed.** Before: three pollers of `/api/agents` (the console, `MenuBarFeed`,
    and each `DesktopWindow` every 2 s). Now: `AgentFeed` (app-level and in the environment)
    is the only one. The console calls `refresh(ifOlderThan: 1 s)`, the menu bar loop asks with
    0.75× its interval, and the desktop windows only read it. Concurrent callers share one request.
    `attending` is the console's, and false once it disappears.
  - Tests: `PollingTests.swift` (22, including the silent paused poll and the stale tier). They cover the intervals per phase, the pause, the
    doubling and cap, the Mac phase mapping, and failures reported without cancellations. The
    reachability tests cover a canned `URLError`, a second failure keeping `since`, a success
    clearing it, a 403, a 502, a cancelled request, and a failure landing after logout. The banner
    is rendered via `ImageRenderer`. Retry and cancellation each end a 60 s nap, as does
    recovery. The feed tests cover coalescing, freshness, the attending header, and offline
    keeping the list. `Canned` gained `failure: URLError.Code?` and `Recorded` gained `headers`.
    `MacRenders.swift` was updated for `AgentFeed`.
  - Docs: `apple/README.md` (menu bar, the new "Polling and errors" bullet with the grep),
    `## Clients` Requirement on polling intervals and the banner.
- **Key decisions:** reachability is reported centrally in `run`, not by each poll. A proxy 502/503/504 counts
  as unreachable (Caddy in front of a stopped daemon answers 502). The inactive rate stays at 10 s
  for the list because of the daemon's 30 s presence window. The Mac background is not paused.
  The banner goes on the detail column rather than over the whole window (it would collide with the
  traffic lights).
- **Notes/leftovers:**
  - Simulator proof, focus-free on a private sim (deleted afterwards). A local daemon on :7871 was
    claimed with curl, the app launched with `-schermes.serverAddress/-schermes.debugPassword`
    and the daemon killed. The list showed the banner ("Can't reach the daemon · Could not
    connect to the server. · Since 12:03" with Retry now) within 9 s, and it cleared on its own
    within 45 s of a restart. A double full stop seen there is fixed (`sentence`), but not
    re-screenshotted.
  - Trade-off: desktop windows no longer poll the list. With the console occluded or closed, the
    feed runs at the inactive 10 s rate, so a desktop toolbar's agent state can lag by up to 10 s
    (it was 2 s).
  - Desktop window: `DesktopLink`'s 5 s reconnect loop is a socket, not a poll, and stays as is.
  - Build warning at Triggers.swift:255 predates this slice (warnings slice).
- **Placeholder choices:** banner copy ("Can't reach the daemon", "Since …", "Retry now"), the
  `wifi.exclamationmark` symbol, the failed tint at 10% fill and 35% stroke, and the Inspector's
  caption for a refused Take control; "Could not load the activity"; "Could not list them: …" on
  the Notifications page.
- **Runtime-unverified:** the banner on the Mac (detail column) and iPad, and the menu bar panel's
  banner. Retry now was not tapped on screen (idb is broken); it is covered by tests. The
  occlusion slowdown was not observed live.

## Slice: 17 — clipboard bridge, Cmd→Ctrl shortcuts, older-page retry
- **Shipped:**
  - **ServerCutText → local clipboard.** `RfbClient.readCutText` parses padding, a U32 length and
    Latin-1 text and yields it on a new `cuts` stream (`.bufferingNewest(1)`, so frames on
    `events` can't evict it), only while `holds`. A length over `maxCutText` (256 KiB, Xvnc's
    `MaxCutText` default) is skipped as it arrives (`skip`), never buffered. `DesktopLink.run`
    has a fourth group child that puts each cut on the pasteboard through the `Clipboard` seam
    (`SystemClipboard` = NSPasteboard/UIPasteboard; tests use a fake).
  - **Local clipboard → ClientCutText.** `RfbClient.paste(text, keysym:)` writes ClientCutText,
    then Ctrl down / v down / v up / Ctrl up, all through the gated `input()`. A text over the cap
    sends nothing at all (no bare Ctrl+V, which would paste the agent's stale clipboard).
    `DesktopLink.paste`/`pasteClipboard` return a complaint for the view; no text (image or empty
    clipboard) sends the bare chord. Latin-1 encode: CRLF/CR → LF, NFC, one `?` per character
    outside Latin-1 (an emoji included).
  - **Cmd → Ctrl.** `Keysym.controlShortcut(character, shift:)`: c, v, x, a, z (capital with
    Shift, since Xvnc fits Shift to the keysym). Mac: `performKeyEquivalent` takes exactly those
    while the input view is first responder (⌘Q/W/, still reach the menu); Edit-menu
    copy/cut/paste/selectAll actions do the same. Command was removed from `modifierKeysyms`: it
    no longer goes down on its own, and any other ⌘ chord is sent as Super down/key/up/Super up.
    iOS: hardware ⌘C/X/A/Z map the same; ⌘V and the edit menu go through `paste(_:)` (first
    responder only, i.e. keyboard up); a `PasteButton` in the bar while holding is the dependable
    path.
  - **Older-page retry.** `OlderPages` (`Api/Thread.swift`): `more` + phase idle/loading/failed,
    `opened`/`begin`/`landed`/`failed(nil = cancelled)`/`retry`. ChatView replaced `more` and
    `loadingOlder` with it. A failure shows `OlderFailedRow` ("Couldn't load older messages ·
    Retry", reason on hover) instead of the spinner; Retry puts the spinner back and its `.task`
    runs again. The failure no longer goes to `trouble`, so it never blocks `pollFailed`.
  - Tests: `RfbTests` +10 (cut text surfaced while held and in step after it, oversize skipped
    with the next frame intact, a 4 GB length dropped, paste bytes, no bytes unheld, over-cap
    paste sends nothing, shortcut bytes, the mapping table, Latin-1 replacement, the `DesktopLink`
    complaint via a fake clipboard) and the no-hold gate test now asserts no cut surfaced. A
    focus-free AppKit test sends ⌘C, ⌘⇧Z, ⌘Q and ⌘⌃C through an offscreen `NSHostingView`'s
    `performKeyEquivalent`, proving SwiftUI forwards them to the input view (⌘Q and ⌘⌃C pass
    through). `ThreadTests` +4 for `OlderPages`.
  - ChatView's macOS paste monitor (images into the composer) now also requires the event's
    window to have a text field as first responder: `editing` stays true while the desktop window
    is key, so a desktop ⌘V with an image on the clipboard went into the chat.
  - Docs: `apple/README.md` "Agent desktop input" bullet (the mapped keys), `docs/architecture.md`
    `## Clients` view-only Requirement now covers ClientCutText/ServerCutText, plus a new
    Requirement on cut-text encoding and limits; the proxy ceiling now names types 4, 5 and 6.
- **Key decisions:**
  - Command became a chord modifier instead of a held Super, because a held Super would make
    the remapped ⌘C arrive as Ctrl+Super+C. Trade-off: no bare Super press and no Super+click
    (openbox binds neither by default; Super+key chords still work).
  - ⌘⇧V is also a paste (ClientCutText then Ctrl+Shift+V, the terminal paste).
  - The daemon's "Show how" recorder already frames type 6 (`recording.ts` `messageSize`), so
    no daemon change. A paste during a recording records as the Ctrl+V key step, not the text.
- **Notes/leftovers:**
  - Known limit: plain RFB cut text is Latin-1. UTF-8 needs the extended-clipboard
    pseudo-encoding (not advertised).
  - TigerVNC's `SendPrimary` defaults on (per its Xvnc man page; not checked in the image), so
    selecting text on the agent (no copy) likely also replaces the local clipboard while held. `-SendPrimary=0` in `start-desktop.sh` would stop that; not done
    (infra, out of scope). Owner call.
  - Verification: `xcodegen generate`; macOS build 0; iOS Simulator build 0; macOS test 0 (296);
    iOS test on a private sim 0 (287, sim deleted; build-for-testing 0 after the last test edit). `lsappinfo front` stayed `loginwindow`
    throughout (screen locked), so the test host never came forward.
- **Placeholder choices:** "Couldn't load older messages" / "Retry" copy, triangle icon in the
  failed colour; the over-cap paste message ("That is too much text to paste onto the desktop
  (256 KB at most)."); `PasteButton` icon-only, circle shape, placed before the keyboard button.
- **Runtime-unverified:** Cmd+V/Cmd+C on a real agent desktop (no harness up; the screen was
  locked, so nothing could be driven focus-free); the macOS 26 pasteboard-privacy behaviour of the
  read inside a key handler; the iOS `PasteButton` look and taps in the glass bar; iOS hardware ⌘V
  through `paste(_:)`; the retry row on screen.

## Slice: 18 — Swift 6 warnings to zero, and the Apple app cleanup list
- **Shipped:**
  - **Warnings.** The baseline clean build had exactly two Swift warnings (the known ones).
    `Triggers.swift`: `TriggerRow.onSwitch` is now `@MainActor (Bool) -> Void`, a Sendable type, so
    `Binding(set:)` takes it. `Sidebar.swift`: the `@Sendable` animation completion hops with
    `Task { @MainActor in self?.settled() }` instead of mutating `animating` itself. No
    `@preconcurrency` or `nonisolated(unsafe)` was added.
  - **Group threads gone.** `ChatThread.group` was never constructed outside a test. `ChatThread`
    is now `struct { let agent: Agent }` with `source`, `title` and `isWorker`; `members`, `only`,
    `speaker(of:among:)`, the two-agent branch of `speakerLabel`, `ToolRun.by`,
    `SlashCommand.sharedToo`, the multi-agent `compactionNotice` and `Approval.participants` are
    deleted. In ChatView every `if let agent = thread.only, agent.parentId == nil` became
    `!thread.isWorker`, the `only == nil` branches (the group pill, header, empty state, "agents
    stop writing to each other" note) went, `palette` is non-optional, and `stop()` stops one agent.
    `ConsoleView` builds `ChatThread(agent:)`. `ThreadSource.conversation` stays: `ConsoleView.retry`
    fetches a Needs you item's thread by conversation id.
  - **Web-UI comments** rewritten in `Thread.swift` (`viewOnly`), `SchermesClient.swift`,
    `DesktopView.swift` (2), `Routines.swift`, `ThreadTests.swift` and `apple/README.md`; the
    "shared thread" wording in ConsoleView, ChatView (a misplaced `clear()` doc comment moved back),
    `SchermesClient.ThreadSource`, `TypesTests` and the README's Deleting and commands sections.
  - **Accessibility.** Already met: every icon-only control is a titled `Button("…", systemImage:)`
    under `.iconOnly` (26 sites), and the two `Image`-only labels (console gear, chat image) carry
    `accessibilityLabel`; `PasteButton` is the system's. Dynamic Type: of the 24 `.system(size: ≤12)`
    sites, only two were text on iOS: Inspector "PAUSED" and the `ContextMeter` percent, now
    `Font.canvas` (fixed on the Mac, a text style on iOS). The rest are Mac-only blocks or the
    Activity/ChatView fonts that already split per platform.
  - **Stable temp names.** `imageFile` names its folder `images-<SHA-256 prefix>`
    (`imageFolderName`) instead of `abs(base64.hashValue)`, which is seeded per launch.
  - **Keychain.** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on save and on the group copy.
    On iOS only, `Keychain.read` runs `SecItemUpdate` on the matching items, so items saved by older
    builds (the app's and the group's) move class; the result never affects what `read` returns.
    A `swiftc` probe on this Mac (throwaway service `dev.schermes.probe`) added an item with the new
    class, read it back and deleted it, all `errSecSuccess`, so the Mac save path still works.
  - **Cleartext warning.** `Session.isCleartext(url)`: `http` and the host is not `127.*`,
    `localhost` or `::1`. `CleartextWarning` ("Plain HTTP: your password and session cross the
    network unencrypted. …") under the address on the connect screen (live as typed), on the
    sign-in screen, and in Settings ▸ Daemon › Connection.
  - **Share memory.** The extension clones the provider's temporary file to `tmp/shared-<name>`
    inside the handler, maps it (`mappedFile`, `.alwaysMapped`) and unlinks the name. The Mac
    Service maps too. `SchermesClient.upload` writes `{"name":…,"base64":"…"}` to
    `tmp/upload-<uuid>.json` (path taken unencoded) in 192 KiB slices (`writeUploadBody`, chunks a multiple of 3, name via
    `JSONEncoder`), sends it with `upload(for:fromFile:)`, and deletes it in a `defer` (a re-login
    retry rebuilds it). `send`'s status/401/429 handling moved into `decoded(_:_:auth:)`, shared by
    both.
  - **Resign-key observer.** `DesktopInputNSView.viewDidMoveToWindow` removes its
    `didResignKeyNotification` observer before adding one for the new window (it added one per move
    and never removed any).
  - **Take control.** Already met: `DesktopView.take` puts any non-cancellation failure (the
    daemon's 404/409 refusals included) in `trouble`, which the `complaint` overlay shows. No change.
  - Tests: `ShareTests` +5 (the upload body at sizes 0-13 with a 6-byte chunk vs
    `base64EncodedString`; an upload through the canned daemon sends the full body from the file and
    leaves no temp file; a mapped file outlives its name; `isCleartext` cases; `imageFolderName`),
    `RfbTests` +1 (a view moved to a second offscreen window ignores the first window's resign and
    lets go on the second's), `CommandsTests` updated (worker gets no commands, single-agent
    `compactionNotice`).
  - Docs: `apple/README.md` (App Transport Security: the warning; Session and password: the class;
    app group: share mapping and streamed upload; a new Accessibility bullet).
- **Verification:**
  - Warnings: `xcodebuild build` macOS and `generic/platform=iOS Simulator` (app + share extension)
    into fresh `-derivedDataPath`s → 0 and 0, and
    `grep -h "warning:" macF.log iosF.log | grep -v appintentsmetadataprocessor` → nothing. The test
    logs (test target compiled fresh) → 0 warnings too.
  - `xcodebuild test` macOS → 0 (302 tests); `lsappinfo front` stayed `loginwindow` throughout.
    On a private iOS 26.5 iPhone 17 Pro simulator → 0 (292), simulator deleted.
  - Greps, all empty: `grep -rn "thread\.only\|thread\.members\|sharedToo\|ChatThread\.group\|case group" apple/Schermes apple/SchermesTests`;
    `grep -rni "ui/src\|web ui" apple --exclude-dir=DerivedData --exclude-dir=Schermes.xcodeproj`;
    the icon-only scan (a Perl pass for `Button`/`Menu` labels that are only an `Image` with no
    `accessibilityLabel` within 14 lines) flagged 4 rows, all of which have text labels.
- **Key decisions:** removed group code outright rather than keeping an inert enum case; agent-
  written rows in the owner thread now always show the raw sender name (as before for a one-agent
  thread). Glyphs inside fixed-size badges (Goals 10 pt checkmarks, Idle 8/9/11 pt symbols) stay
  fixed, since a text style would outgrow the badge. The Keychain migration is iOS-only to avoid an
  ACL prompt on the owner's Mac.
- **Notes/leftovers:**
  - `DesktopView.follow` sets `trouble` from a failed poll but never clears it on a later success;
    small, left as is.
  - The upload body still base64-encodes the whole file on the device; peak memory is now one
    192 KiB slice plus mapped pages, but the 25 MB-on-a-real-iPhone check stays user-gated.
- **Placeholder choices:** the cleartext copy and the `lock.open.fill` symbol in `Theme.needsYou`.
- **Runtime-unverified:** the cleartext warning on screen (connect, sign-in, Settings), the share
  extension's memory use with a large file on a device, and the iOS Keychain class migration on a
  phone holding an older item.

## Slice: 19 — docs match the code, daemon test coverage, full harness run
- **Shipped:**
  - **Docs.** README: the native app is the only client, setup token in first run, APNs vars in
    the config table, `sandbox.sh`/`rename-`/`delete-agent-user.sh` in the layout, link to
    acceptance. `docs/configuration.md`: `SCHERMES_SETUP_TOKEN`, internal `SCHERMES_STATE_DIR`/
    `SCHERMES_HOME`, a first-run setup token section, `MAX_API_BODY_BYTES` 40 MB, `timezone` and
    `imageRetentionDays` now in Settings ▸ Daemon. `deployment.md`: the setup-code field exists.
    `architecture.md`: VNC proxy goes to the app; `## Privilege model` checked against
    `install.sh` sudoers, `asAgent()` (agents.ts:129) and `sandbox.sh enter`: accurate.
    `development.md`: test table lists every test file. New **`docs/acceptance.md`** (the
    `hermes-parity` steps redone for the app, plus real endpoint, real-device and Unraid checks),
    linked from `docs/README.md` and the root README.
  - **Tests (73 new, no source change):** `imap.test.ts` 14 (decodeWords B/Q + charsets; a
    scripted IMAP server via `OpenSocket`: baseline cursor, UIDs above cursor only, UIDVALIDITY
    reset, maxListed, LoginRefused, literals, timeouts), `triggers.test.ts` 13
    (checkCommandRefusal, parseTriggerProposal edges, cap per agent, listTriggers, actOnTrigger,
    fireWebhook incl. hourly window, prompt never leaks secrets, imap check skips/login refusal),
    `goals.test.ts` 14, `workers.test.ts` 5, `interview.test.ts` 6, `snapshots.test.ts` 11 (fake
    `Exec`: commands, stop signal, prune, fileChanges/restoreFiles), `models.test.ts` 10.
- **Verification:**
  - `pnpm check` → 0; `pnpm test` → 0 (daemon 482 pass, 0 fail).
  - Throwaway `smoke` project, fresh build: `docker compose up -d --build` → 0,
    `infra/smoke.sh` → 0, `docker compose exec -T schermes /opt/schermes/infra/desktop/check.sh`
    → 0 ("3 desktops, 3 chromium profiles, cookies persisted, only :7779 off loopback"). Then
    `down -v` (smoke volumes only), `docker rmi smoke-schermes`, `docker builder prune -f`.
  - Greps over `README.md docs/*.md`: `grep -rniE "web ui|ui/src|pnpm --filter ui"` → two
    legitimate hits (Unraid's own web UI, the architecture "Deferred" note on the UI's removal);
    `grep -rnE "localhost:7777/|127\.0\.0\.1:7777/"` → empty;
    `grep -rniE "not in the app yet|no field for|in a browser|browser login|open http"` → empty.
- **Key decisions:** acceptance lives in `docs/acceptance.md`; the archived hermes-parity list
  stays as history. Migration tests for models stay in `api.test.ts` (already thorough).
- **Notes/leftovers:** `goals.ts:249`: when a temporary helper's Linux user can't be removed,
  the agent row is deleted anyway, so nothing retries the user/home cleanup (app.ts delete keeps
  the row instead). Names never repeat, so no reuse risk; pinned by a test, not fixed.
  First `check.sh` attempt ran it on the Mac by mistake (exit 2 on `declare -A`); the documented
  in-container run passed.

