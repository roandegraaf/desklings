# Progress — redesign-and-agent-flows

## Current state
- **Design system lives in `apple/Schermes/Views/Theme.swift`:**
  - `Token` (light/dark pair, a `ShapeStyle`); `Theme` ground, window, ink, secondary, muted, hairline and the needsYou, failed, retrying, done state tokens.
  - `AgentPalette`: a literal port of the canvas Colour check script (integer channels, `t += 0.02`, the 0.03928 threshold, base `BloubColorId.rgb`). Goldens pin it.
  - `AgentState.presentation` + `StateLine` (icon plus word); `busyHalo`; `ContextFullness`, `ContextRing`, `ContextMeter`.
- **Context fullness:** daemon: `contextFullness(db, agent)` in `loop.ts`, own thread vs `MAX_TRANSCRIPT_CHARS`, clamped 0–100, only on `GET /api/agents` (`Agent.contextFullness?`). Reads with `existingConversation` and `listMessagesWithoutImages`. App: `ContextMeter` toolbar item where the inspector is offered; `ContextRing` around the iPhone More menu.
- **Chat colours:** background `palette.tint`, `.tint` is `accentText`, filled controls use `bubble`/`bubbleText`. Group threads fall back to the ground. **Mac sidebar stays on system glass.** The detail column and the iOS list use `Theme.ground`.
- **`waiting_for_user` is the resting state after every turn** and shows as "Ready". A waiting question is found from the transcript, not the state (see Needs you). **`Agent.tagline`** (the profile's first line of prose) stands in for a label field. **Every agent bloub has its name beside it.** SF Mono on tool names, file-card and artifact names, "Runs as".
- **Approvals (daemon, `approvals.ts`):** `ApprovalKind` is `agent | conversation | action`. Every row has a `category` (`APPROVAL_CATEGORIES` in `shared`: the 8 rule categories plus `passwords_security`); deletions are `delete_files` (column default, so old rows upgrade). `action` rows carry optional `amount` and `origin`; `target` may be empty. Tools: `request_approval` (`parseApprovalRequest`, `requestApprovalToolDef`) and `request_deletion`. Both go through `standingRequest` in `loop.ts` (cap, event, deliver), permanent agents only. `POST /api/approvals/:id` on an `action`: nothing is performed, the asker is told "approved … Go ahead." (or "said no"), and the mid-turn 409 is skipped for it.
- **Needs you (daemon, `needs.ts`):** `listNeedsYou(db)` behind `GET /api/needs-you`, derived on every read, so nothing needs clearing. `approval:<id>` items embed the `Approval`; actions approve and deny. `question:<msg id>`: the agent's newest `ask_owner` call in a thread (not refused) with no owner row (`user`, no sender) after it: the same rule as the chat's `pendingInterview`. Action answer. `failure:<msg id>`: a permanent agent in `failed`; its newest message (`lastMessageBy`) is the failure line. Actions retry and open. Items are sorted by `createdAt`; `NeedsYouKind` is open (hand-over, form, goal). **Actionable push (slice 29):** the `deliver` hook resolves the turn's item with `pushedItem(db, agent, conversation, kind)` (approval → the asker's newest in that thread; failure → its failure or `provider_auth` item; reply → an item whose `messageId` ≥ the agent's newest assistant row there, so a plain reply is about nothing) and the push carries top-level `needsYou: <id>` + `aps.category` = `pushCategory(item)` (`PushCategory` in shared: `needs.approval` Approve/Don't, `needs.delete` Keep it/Delete it, `needs.yours` passwords I'll do it/Don't, `needs.watch` hand-over, `needs.open` the rest). `POST /api/needs-you/:id/action` `{action}` (404 unknown/stale, 400 not offered or not approve/always/deny) runs the same `decide()` as `POST /api/approvals/:id`. `AppDeps.pushSend` is the test seam. App: `PushCategory` in `Notifier.swift` (ids, buttons, `answer(_:)`), registered in both delegates' launch; `NotificationRelay.didReceive` answers approve/deny with its own `SchermesClient` off `addressKey` (a background launch has no `Session`), re-login via Keychain on 401, a local "did not reach the daemon" post on failure; local Needs you posts carry the same category + `needsYou`/`agent` userInfo; `willPresent` hides only real pushes about an agent.
- **Needs you (app, `Views/NeedsYou.swift`):** `ConsoleView` polls `/api/needs-you` (not `/api/approvals`); `needs` feeds the sidebar badge, the iPhone strip, the page, the app badge and the local notifications (keyed by item id).
  - Selection is `SidebarPick` (`.needsYou` or `.thread(ThreadSource)`); `picked` is a computed view of it. Every `NavigationLink(value:)` passes a `SidebarPick`.
  - Actions: approve/deny → `decide`; answer/open → `open(item)` (own thread → `.agent`, shared → expand + `.conversation`); retry → `retryStart` (the chat's `ChatRows.retryFrom`, refused if the owner wrote since) + rewind with `retry: true`, else open.
  - `NeedsYouKind`/`NeedsYouAction` decode unknown values as `.other(String)`, so the count always matches the endpoint. `ApprovalRow` is gone; its wording lives on `Approval` (`asks`, `noWord`, `yesWord`).
- **Live Activity (slice 30):** daemon `liveactivity.ts`: `live_activity_tokens` (token PK, `kind` start|update, `agent`; migration 0025), `POST /api/live-activities` `{token, kind, agent?}` (hex 32–200, update needs a known agent). `createLiveActivities` in `createApp`: runner `turn(agent, 'start'|'end')` (permanent, non-idle, around `drain`) → start push to every push-to-start token (once until an update token arrives), end to the agent's update tokens (then deleted, `dismissal-date` +15 min); `progress` (after an ok `update_goal`) and `deliver` kind `approval` → throttled update (`activityThrottleMs`, default 5 s, trailing timer). Per-agent send chain, strictly increasing `timestamp`. An update token registered after the turn ended gets an end at once. `sendEach` in `push.ts` is the shared APNs loop. Wire keys: `LiveActivityAttributes {agent,label,look?}`, `LiveActivityState {title,stepsDone,stepsTotal,needsYou,state}` in `shared`, pinned as literal JSON in `push.test.ts` and `AgentActivityTests.swift`. App: `Schermes/AgentActivity.swift` (shared with the extension; `BloubIdentity` moved to `Skins.swift`), `SchermesWidgets` target (iOS app-extension, embedded with `destinationFilters: [iOS]`), `LiveActivityTokens.observe()` + `NotificationRelay.background` (session-less client) in `Notifier.swift`, DEBUG lever `-schermes.debugActivity YES`.
- **Menu bar (slice 31, macOS only, `Views/MenuBar.swift`):** `MenuBarExtra` (`.window` style) in `SchermesApp` sharing `session`/`looks`; `MenuBarFeed` (@Observable, own poll of agents + needs-you, 2 s while the panel shows, else 10 s; started idempotently from the label's `onAppear`) because the console window can be closed. Label = bell + Needs you count. Panel: quick field, Needs you (`NeedsYouCard` fed `item.answeredInPlace`: only approve/always/deny answered in place via `act(onNeedsYou:)`, everything else becomes Open → `openConsole(at:)` brings back or opens `WindowGroup(id: consoleWindowID)` and posts `.openAgent`), Working now (`BusyAgentRow`, shared with the page's Right now). `quickMessage(_:agents:)` (pure, outside `#if os(macOS)`) → `.empty/.plain/.to/.unknown`; plain goes to `@AppStorage("schermes.quickTarget")` or the picked agent (permanent agents only). ⌥Space = `PanelHotKey` (Carbon `RegisterEventHotKey`, no Accessibility; skipped when `XCTestConfigurationFilePath` is set) → `performClick` on the `NSButton` inside the `NSStatusBarWindow`.
- **Share (slice 32, `Schermes/Share.swift`, compiled by the app and `SchermesShare`):** `SharedItem` (link/text/file), `ShareTarget {recipient, goal?}` (a goal goes to its lead), pure `sharedMessage(_:instruction:goal:uploadedTo:)` (instruction or "Have a look at this.", "This is for the goal \"<title>\".", the URL / `> `-quoted text / "I put the file in your home: <daemon path>"), pure `uploadFilename` (fits `UPLOAD_NAME`, folds accents, keeps the extension), `deliverShare` (upload through `POST /api/agents/:name/uploads`, then `send(.agent)`; no daemon change), `StoredDaemon` (client off a defaults' `addressKey` + one Keychain re-login on 401; `NotificationRelay.background` now uses it), `SendToSheet` (open goals + permanent agents by title, `@name` when labelled, tagline; instruction; used by both). **iOS:** `SchermesShare` app-extension (`SchermesShare/ShareViewController.swift`, `com.apple.share-services`, 1 URL/text/file/image/movie, own ATS + local-network keys, `SCHERMES_EXTENSION` gates the app-only `registerDevice`), embedded with `destinationFilters: [iOS]`; sources are only `Share.swift`, `Session.swift`, `Api/SchermesClient.swift`, `Api/Types.swift` (so `plainPreview` moved into `Types.swift`, `rulesSummary` into `Rules.swift`). **Login hand-off:** app group `group.dev.schermes` (both entitlements, device builds only): `Session.storeAddress` mirrors the address into the group suite on every connect (iOS only; the Mac never touches a group container) and adds a grouped Keychain copy of the password (`Keychain.shareWithExtension`, add-only; `save` adds both; `clear` removes both). No entitlement (simulator) → the extension shows "Open Schermes and sign in first." **macOS:** `NSServices` "Send to Schermes…" (text, URL, file-url, `NSSendFileTypes public.item`) → `ShareService` (`NSApp.servicesProvider` in the Mac `AppDelegate`) opens `SendToSheet` in its own `NSWindow` with the standard-defaults `StoredDaemon`.
- **Rules (daemon, `rules.ts`):** two nullable JSON columns on `agents`: `rules` (`AgentRules`: `levels` per `ApprovalCategory` plus `preApproved`) and `grants` (one-shot passes). Null means `DEFAULT_LEVELS`; `passwords_security` is forced to `hand_to_you` on read and refused on write. - `GET`/`PUT /api/agents/:name/rules` (404 for workers; PUT merges, lowercases and dedupes the list). `rulesPrompt` is in `homeTail` (read once per turn, before memory). Workers get no rules text; they are guarded under their parent's rules. An approved action in a Hand to you category (always passwords) answers "will do it themselves. Do not do it.", never "Go ahead". `guardCommand` runs before every `run_command` (the only agent path that deletes or installs; there is no agent-facing file-delete tool). `classifyCommand` reads words in command position. Ask first and If pre-approved refuse unless a grant matches `category` + exact `target` (the refusal names both); Hand to you always refuses. Grants are spent only when the whole command may run. Approving an `action` in `delete_files`/`install_software` calls `grantOnce`. `always: true` on `POST /api/approvals/:id` (only for `alwaysAllowable`: an origin, or a send/share recipient; never delete, install or passwords) adds to `preApproved` and lifts Ask first to If pre-approved. Needs you items offer `always` then.
- **Rules (app, `Views/Rules.swift`):** `RulesView` is the `.rules` page of `AgentPages` (Mac inspector overview, the `RoutinesAndActivity` sheet from the agent's context menu "Rules…" and the iPhone More menu "Rules"). `RuleRow.editable(runsAs:)` holds the canvas words and order (8 rows, browse and run commands kept apart); `RuleRow.locked` is passwords, shown "Always yours". Each change PUTs at once; refusals show under the pre-approved field. `RuleLevel` (open enum), `AgentRules`, `AgentRulesUpdate` in `Types.swift`.
- **Models (daemon, `models.ts`):** `models` table (key encrypted with the master key); default and backup are settings keys `models.default`/`models.backup` holding an id; `agents.model_id` null means the default. `providerConfig(db, masterKey, agent?)` resolves assigned, else default; a worker uses its parent's. Every runner turn, the kickoff, the send gates, retry and compact go through it. `migrateProviderSettings` (boot, `main.ts`) makes `provider.*` the first default entry and deletes those rows. `GET`/`PUT /api/settings` provider fields read and write the default entry (created on first write).
  - Routes: `GET`/`POST /api/models`, `PUT`/`DELETE /api/models/:id`, `PUT /api/models/default` and `/backup` (`{id}`, backup takes `null`), `POST /api/models/:id/test`, `PUT /api/agents/:name/model` (`{id|null}`, 404 for workers). Delete is 409 while assigned, and for the default while other models exist. Wire: `ModelEntry`, `ModelUpdate`, `Agent.modelId`.
- **Models (app):** `ModelPage` in `Settings.swift` lists the registry (Default/Backup badges, Test, a More menu: Edit, Make default, Use as backup / No backup, Delete) and shows the daemon's refusal text under the list; `ModelSheet` + `ModelDraft.update(from:)` send only what changed and never a blank key. `AgentModelRow` (Overview of `AgentPages`, hidden for workers) picks by name with "Default (<name>)". The app no longer uses the provider fields of `/api/settings`. `modelPick(_:)` encodes `{"id":null}`.
- **Model recovery:** `openAiProvider` is one attempt (network errors and idle timeouts become retryable `ProviderError`s with `status`/`retryAfterMs`); `withRetries` does 5 attempts, backoff 2 s·2^n or `Retry-After`, a stop cuts the wait, `control.now()`/`useBackup()` act only while waiting. `agentProvider` in `app.ts` wires it per turn with `backupConfig`; the wait rides on `/live` as `retry`; `POST /api/agents/:name/retry` `{action: now|backup}`. - 401/403: no retry, no backup; settings row `models.authFailed.<id>` (cleared by a key change, delete, an answered call or a passing test) → one `provider-auth:<id>` Needs you item (action `settings`), hiding per-agent 401/403 failures. App: `RetryCard` in `LiveRow`; "Open model settings" via `SettingsRequest` (iOS sheet on Models) or the Mac tab `schermes.settingsTab`. Stub keys `status-NNN` answer that status.
- **Browser watchdog (`browser.ts`):** `reach` = connect + a `Runtime.evaluate 1` probe (5 s); a stall before the action or on navigate/read (`Hung`) → `stopBrowser` (pkill as the agent, waits till gone) + start, action redone once (`restarted: true` on the `tool_result` event); an `evaluate` timeout is never redone. A second stall: tool text `error: ${BROWSER_HUNG}…`, event `hung: true`, the turn ends `waiting_for_user`. Derived from that tool row (no owner row after it): Needs you `browser:<row id>` kind `browser_hung` (actions `screen`, `restart_desktop`, `restart_browser`) and the chat's `BrowserHungCard` (`ChatRows.browserHang`, `browserHungPrefix` in `Thread.swift` must match). `POST /api/agents/:name/browser/restart` `{what: browser|desktop}` (409 mid-turn) kills Chromium or `desktop.stop`/`ensure`, then writes an owner line and starts a turn in the hung thread. `LoopDeps.connect`/`browserTimings` are test seams.
- **Hand-over (`ask_for_hands`):** tool in `control.ts`, ends the turn `waiting_for_user`. `handOvers` in `needs.ts` (via `pendingCall`: newest call, result not `error:`, no owner row after) → `hands:<msg id>`, actions `open`, `take_screen`. `DELETE …/control` writes `HANDS_BACK` as an owner line and starts a turn only when `screenAsked` (a pending hand-over **or form**) exists; `GET …/control` `handOver` uses the same. App: `HandOverCard`, `ChatView.takeScreen`, `DesktopView` "Give it back".
- **Teach a skill (slice 33, `recording.ts`):** "Show the agent how" = `POST /api/agents/:name/recording` (404 workers, 409 twice; holds control, starts the recorder), `PUT …/recording {secret}`, ended by `DELETE …/control` (after `HANDS_BACK`). `GET`/`POST`/`PUT` control answers carry `recording: RecordingState` only while one runs. The recorder (`createRecorder`, in memory per display, returned by `createApp`) reads the viewer's client→server bytes through `attachVncProxy`'s 4th arg `tap` (`rfbInput`: skips the fixed 14-byte handshake, stops on an unknown type) and builds `Step`s (click/double/drag/scroll/type/key, model coordinates, xdotool key names) with daemon screenshots 700 ms after a step (one at start; `MAX_SHOTS` 12, `MAX_STEPS` 200, 30 min, `truncated`). **Secrets:** a typing run is secret when Secret is on or `focusedField` (CDP, `browser.ts`) says password / secret autocomplete (`SECRET_AUTOCOMPLETE`, now exported from forms.ts) / a frame it can't see into / error (fails closed); stored as `{secret: true}`, no text or length. A secret that is not a masked password taints the recording: no screenshot from then on, and one taken while it was typed is dropped. Toggling Secret starts a fresh run. **Hand-off:** `saveRecording` writes `~/recordings/<YYYYMMDD-HHMMSS>/steps.json` + `shot-NN.png` as the agent, a `magick montage` contact sheet (else the last shot) rides on one owner row `shownLine` (`SHOWN_PREFIX`, steps, the dir, the exact SKILL.md frontmatter, ask_owner → schedule_task) in the agent's own thread, then a turn. Zero steps: nothing. App: `DesktopView` "Show how" (not for workers), Secret toggle, "Stop and hand over" (iPhone: icon-only), red step count in the identity; `Message.isShownLine` (`shownLinePrefix` in Types.swift) → `ShownLine`, sidebar "Showed how it's done".
- **Forms (`request_form`, `forms.ts` + `browser.ts`):** the daemon reads the form over CDP (`readForm`: `FORM_SCRIPT` tags controls `data-schermes-field=<token>-n`, never reads `.value`; origin from `Page.getFrameTree`), `shapeForm` marks secrets (password, autocomplete current/new-password, one-time-code, cc-*) and moves them to `unfillable` `insecure` off HTTPS/loopback. Rows in `forms` (keyed conversation + call id); `formRequests` in `needs.ts` → `form:<form id>` with `form: FormRequest`, actions `fill`, `take_screen`. `POST /api/agents/:name/forms/:id` `{values, remember}` → `fillForm` (origin re-checked, each field focused and checked before `Input.insertText`), `filledLine` owner line ("… Password (hidden)"), a turn. `form_vault` (agent + origin, plain `keys`, encrypted `values`) fills fields the owner leaves out; never without the owner pressing Fill. `hideFromAgent`/`redactSecrets` (memory only) scrub typed secrets from every tool row. `AppDeps.connect`/`RunnerDeps.connect` are the CDP seam; `testpage.ts` `formPage` is the fake page. App (`Views/Forms.swift`): `FormSheet` (origin + lock, reason, one native field per `FormField` via `FieldContent`, "Saved for this site", Remember toggle, unfillable list with "Use the agent's screen", daemon errors at the top) opened from the Needs you card's "Fill in…" (`ConsoleView.filling`) and from the chat's `FormCard` (`ChatRows.form` = `pendingForm`, matched to the item by `messageId`; `ChatView.forms`). `FormFill(fields:draft:remember:)` sends only what the owner entered (blank text left out so saved values apply; checkboxes only once flipped). Only passwords are `SecureField`s (two secure fields make iOS offer a new password). Taking the screen from the sheet waits for its `onDismiss`.
- **Feedback (`feedback.ts`):** `feedback` table (`message_id` PK, FK to messages `ON DELETE CASCADE`, so thread delete, rewind and agent delete drop it; `created_at` refreshed on every change, for idle pre-checks). `PUT /api/messages/:id/feedback` `{rating: up|down|null, reason?}` (explicit null clears; missing is 400; reason ≤ 500, flattened to one line); only assistant rows whose sender is an agent (else 404). A down (new or changed reason) goes first through `remember(..., FEEDBACK_HEADING)` into the answering agent's `MEMORY.md` (a worker's → parent) under `## Feedback` (`APPEND_SCRIPT` writes the heading unless it is already the file's last `## `); a failed write stores nothing and answers 500. Answers `{feedback: MessageFeedback|null}`. `withFeedback` adds `Message.feedback` on both GET messages routes. App: `MessageRow.onFeedback` (assistant `.message` rows), "Good reply"/"Bad reply"/"Remove thumbs …" in the context menu and Mac hover actions, a filled thumb in `meta` outside the hover-hidden part, `FeedbackSheet` (optional reason, errors inside) for down; `ChatView.sendFeedback` patches `loaded`. `FeedbackUpdate` encodes `rating: null`.
- **Idle work (daemon, `idle.ts`):** settings in nullable JSON `agents.idle` (`IdleSettings`, null = `DEFAULT_IDLE`, off; `pausedReason` set by back-off, cleared when a PUT turns it on). `GET`/`PUT /api/agents/:name/idle` (404 for workers). `idlePreCheck` is database-only (`new_messages` excludes the agent's own rows and `IDLE_SENDER` = `"Idle work"`; `new_feedback`, `memory_size`, `stale_files` via one `IDLE_FACTS` exec). `runIdleChecks(db, exec, runner, now)` in the tick (`startIdleScheduler(db, exec, runner)` in `main.ts`): one `idle_passes` row per agent per window. No match → `skipped`. Match → `due`; if the day's tokens (sum of today's rows) reach `dailyTokens`, the agent is busy, not at rest (`idle`/`waiting_for_user`, re-read from the row) or the loop cap is hit, it stays `due` with `reason` and nothing starts; else (synchronously after the awaits) MEMORY.md is snapshotted, an idle note (`idleNote`, role user, sender `IDLE_SENDER`) is appended to the agent's own thread and `runner.start(agent, thread, IdleTurn)`. `since` = end of the last non-`due` pass (`ended_at ?? started_at`), so an unrun pass leaves its signals for the next. **Idle turn (`loop.ts`):** `IdleTurn {passId, modelId, turnCap, tokenLimit, end}` rides round 0 of the drain only; provider via `RunnerDeps.provider(agent, modelId)` (`agentProvider` override in `app.ts`); `deliver` off. Tools `idleToolDefs()`: run_command, remember (lasting only), schedule_task (→ `routine` suggestion, not live), list_schedules, request_deletion, request_approval (delete_files only), `leave_note`. `idleDispatch` refuses everything else; `idleCommandRefusal` refuses any `classifyCommand` hit and mail senders (`commandNames` in `rules.ts`) whatever the rules. Stops after `turnCap` model calls or when usage reaches `tokenLimit`. `end(tokens)` in `runAgent`'s finally (`undefined` = no model: row keeps `due` + reason): memory diff (skipped when MEMORY.md ≥ the read cap), then `ran` if any output else `wasted`, `tokens`, `ended_at`. **Outputs:** `idle_outputs` (pass FK cascade, `kind` memory|routine|note|cleanup, `body` JSON, `resolved` dismissed|undone|accepted). `GET /api/idle/passes?since=` (default last 24 h, all agents, with outputs). `POST /api/idle/outputs/:id {action}`: memory `undo` (409 if MEMORY.md changed since), routine `accept` (→ `insertSchedule`) or `dismiss`, note `dismiss`; cleanup is answered as its approval. Back-off: the newest dismissed-note streak reaching a multiple of 3 sets `enabled: false` + `pausedReason`.
- **Idle work (app, `Views/Idle.swift`):** wire types `IdleSettings` (conditions as open strings), `IdleSettingsUpdate` (`modelId: Int??`, `.some(nil)` encodes `null`), `IdlePass`, `IdlePassOutcome` (open), `IdleOutput` (flat JSON decoded by `kind`, unknown → `.other`), `IdleOutputAction`, `idleSender` (must match `IDLE_SENDER`) in `Types.swift`; client `idle`, `setIdle`, `idlePasses(since:)`, `resolveIdleOutput`. `LastNight` (inside the Needs you "Last night" panel; `NeedsYouPage` now takes `session`) polls `/api/idle/passes` for the last 24 h every 30 s, groups per agent (newest first, then name), shows `IdlePass.summary` ("Had nothing new, so it didn't run, 0 tokens.", "Didn't run: <reason>.", "Looked, found nothing.") and one row per output with only the daemon's allowed actions; a resolved output shows its word; the refusal text sits under the row. Cleanup rows point at their approval in `items`. `memoryDiff` (CollectionDifference over lines). `IdleSettingsView` is `AgentPages.Page.idle` ("When idle", raw value used by the `pages:<name>:When idle` lever): pause banner + Turn back on, on/off, conditions, hours, turn-cap stepper, budget field (saved on submit/blur), model picker ("Agent's own" + registry); per-field daemon errors. Reached from the inspector overview (hidden with Rules for workers), the context menu "When idle…" and the iPhone More menu. Chat: `Message.isIdleNote` rows render as `IdleNoteLine` ("Idle work · 01:12"); the sidebar preview shows "Idle work" for them.
- **Triggers (daemon, `triggers.ts`):** `triggers` table (agent FK cascade; `kind` webhook|folder|command = `TRIGGER_KINDS`, `config` JSON, `reason`, `state` proposed|on|off, `max_per_hour` + fixed hourly window `window_started_at`/`fired_in_window`, `dropped`, `cursor`, `checked_at`, `last_fired_at`; webhook `token` unique + `secret` encrypted). `propose_trigger` (permanent agents, not idle; `parseTriggerProposal`: folder path inside the home, never the home itself; a check command refused by `classifyCommand` or a mail sender; cap `MAX_TRIGGERS` 20) stores `proposed`. `GET /api/agents/:name/triggers` (404 workers; `Trigger.webhook {path, secret}` once minted), `POST /api/triggers/:id {action: on|off|delete}` (on = the owner's confirmation; a webhook mints token + secret once and keeps them; a folder starts watching from now; a command's next check is its baseline). **`POST /hooks/:token`** is outside `/api/*` (no session): secret in `X-Schermes-Secret`, sha256 + `timingSafeEqual`; 404 unknown/not on, 401, 413 over 64 KB (`bodyLimit`), 429 rate-limited (counted in `dropped`), 202. Folder/command are polled by `runTriggerChecks(db, exec, runner, now)` (`startTriggerScheduler`, own timer + `running` flag, every `everyMinutes`): folder = `find -newerct @<last check>` as the agent (ctime, so moved-in files count; dotfiles skipped); command = `commandArgv` with a 30 s `timeout` as the agent, sha256 of exit code + stdout, fires on a change, never on the first check. The row is re-read after the awaits. **`fire`** writes a user row with sender `TRIGGER_SENDER` = `"Trigger"` ("Trigger N fired: your … This is your trigger firing, not the owner writing … If the owner is testing it with you, tell them it fired."; outside text marked as data) and `runner.start`s the agent's own thread, whatever its state (like schedules). `agentChain` counts only senders matching `AGENT_NAME` (so trigger rows and idle notes never block `send_message`); idle `new_messages` excludes `TRIGGER_SENDER`.
- **IMAP triggers (`imap.ts` + `triggers.ts`):** kind `imap`, config `{host, port (993), mailbox (INBOX), everyMinutes}`; `mailboxConfig` refuses any other key (a user/pass-like key gets "never pass a login"), host is a plain hostname, mailbox printable ASCII. The login lives in `triggers.login` (encrypted JSON `{username,password}`); `Trigger.hasLogin` is all the listing shows. **Login via the form flow:** a `forms` row with `trigger_id` set (origin `imaps://host:port`, `secure` forced true, fields `username` + `password`), found-or-created by `loginRequests(db, agent)` (in `listNeedsYou`, not in `formRequests`, so `screenAsked` ignores it) → `form:<id>` item with `NeedsYouItem.triggerId`, action `fill` only. The fill route branches on it first: `saveLogin` reuses `fillSteps`/`rememberSteps`, stores the login, writes **no thread line and starts no turn**. Turn-on is 409 until a login exists; delete removes the form row (the FK has no cascade: SQLite ADD COLUMN). **Poll:** `runTriggerChecks(db, exec, runner, now, imap?: {masterKey, open?})` (`main.ts` passes `{masterKey}`; `open` is the plain-TCP test seam, default `tls.connect` with `servername`). `checkMailbox`: LOGIN (quoted, or a `{n}` literal for non-ASCII), EXAMINE, `UID SEARCH UID last+1:*` (filtered `> last`), `UID FETCH … BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)]` for the newest 20, RFC 2047 decoded; 30 s wall clock. Cursor JSON `{validity, last}`; baseline (no cursor or new UIDVALIDITY) = `UIDNEXT-1` and fires nothing. A tagged NO to LOGIN (not `[UNAVAILABLE]`/`[INUSE]`/`[LIMIT]`/`[SERVERBUG]`) clears exactly that login and rewrites the form's reason ("The mail server refused the login (…); enter it again."), so the Needs you item comes back and nothing retries. Client errors never quote a sent command.
- **Triggers, what the agent knows (slice 20):** `triggerPrompt(db, agent)` in `homeTail` (permanent agents, after the schedules): id, what it watches, state, for imap "login entered"/"not entered yet", "last check failed: …", reason; never a login, token or secret. Turning a trigger on (only a real change of state) writes a `TRIGGER_SENDER` row "Trigger N is on: … Offer to test it together: <how>" and `runner.start`s the agent's own thread. Not an owner row, so pending questions/hand-overs/forms survive. `actOnTrigger(db, masterKey, runner, id, action)`. `triggers.last_error` (migration 0022): set by a failed folder (stderr's first line), imap (the error, incl. a refused login) or thrown check, cleared by the next good check and by turn-on; `Trigger.lastError` on the wire.
- **Triggers (app, `Views/Triggers.swift`):** wire `Trigger`, `TriggerKind` (open), `TriggerState`, `TriggerAction`, `TriggerConfig`, `TriggerWebhook`, `triggerSender`, `NeedsYouItem.triggerId`; client `triggers(agent:)`, `actOnTrigger(id:action:)` (nil after delete), `hookURL(_:)`. `pendingTrigger(in:)` (`ChatRows.trigger`): the newest `propose_trigger` whose result says "Proposed as trigger N.", its newest "Trigger N is on:" line and the first "Trigger N fired:" after it; gone once the owner writes after the fire. `ChatView` polls `/triggers` every 3 s only while that exists and shows `TriggerCard` (not held back while busy; hidden when off or deleted): proposed → Delete + Turn on, or "Enter login…" (opens `FormSheet` for the `forms` item with that `triggerId`); on → webhook URL + secret (`CopyRow`), "Test it: …", "Waiting for it to fire…" → "Fired · time". `TriggerLine` renders both kinds of trigger row quietly ("Trigger fired/turned on · time"), also in the sidebar preview. Listing: `TriggersSection` inside `RoutinesView` (permanent agents); the page is `AgentPages.Page.routines` = "Routines and triggers" (lever `pages:<name>:Routines and triggers`), also in the iPhone More menu.
- **Goals (daemon, `goals.ts`, slice 21):** `goals` (lead FK cascade, `state` open|done, JSON `steps` [{text, owner, state todo|doing|done|blocked}], `results`, `next_from_you` + `next_at`, `helpers_made`) and `goal_helpers` (agent_id PK FK cascade, goal FK cascade, `kind` worker|agent, `reason`, `kept_at`); migration 0023. Tools (permanent agents, not idle, refused for unkept helpers): `update_goal` (no id = create; `steps` replaces, owner defaults to the lead and must be the lead or a helper; `addResults` appends; `nextFromYou` replaces; `finish`; the result echoes `describeGoal`) and `add_helper` {goal, kind, reason, brief} (≤ `MAX_HELPERS` 6 per goal). `goalPrompt` in `homeTail` (goals led + the one helped); a helper worker's `workerPrompt` carries its goal. Needs you `goal:<id>` (kind `goal`, action `open`, lead's own thread, `goalId`, `detail` = the list) while open with a non-empty list. **Helpers:** `worker` = `spawnWorker` (the `spawn_task_worker` path) with a real display from `nextDisplay`, `desktop.ensure(lead, display, workerName)` (start-desktop.sh's 3rd arg tags log/pidfile), `hasOwnScreen` (display ≤ 999) gives it `computer` and `toolTarget` its own display; the lead ends `waiting_for_task_worker`. `agent` = `insertAgent` `<lead>-g<goal>-<n>` with the lead's look, a helper profile (no interview), `desktop.ensure`, brief as a lead message in `conversationWith([lead, helper])`; the lead ends `waiting_for_agent`. `RunnerDeps.desktop`/`LoopDeps.desktop` (app passes it; absent → add_helper refused). `finishGoal`/`deleteGoal` (409 while an unkept helper runs): temp agent → `desktop.stop` + `deleteAgent`; worker → `desktop.stopDisplay` (pkill that Xvnc only), display back to a placeholder, helper row dropped, stays a finished worker. Routes: `GET /api/goals`, `GET /api/goals/:id`, `POST /api/goals/:id/finish`, `DELETE /api/goals/:id`, `POST /api/goals/:id/helpers/:name/keep` (agent kind only; sets `kept_at`). Wire: `Goal`, `GoalStep`, `GoalHelper`, `HelperKind`, `GOAL_STEP_STATES`, `NeedsYouItem.goalId`.
- **Goals (app, `Views/Goals.swift`, slice 22):** wire `Goal` (`state` a plain string, `isOpen`, `progress` = done steps / all, 0 without steps, `temporaryHelpers` = unkept helpers of an open goal, `involves`), `GoalStep`, `GoalStepState` and `HelperKind` (open enums), `GoalHelper.canBeKept` (agent kind, unkept), `NeedsYouKind.goal`, `NeedsYouItem.goalId`; client `goals`, `goal(id:)`, `finishGoal`, `deleteGoal`, `keepHelper(goal:name:)`. `ConsoleView` polls `/api/goals` in `refresh()`; `SidebarPick.goal(Int)` shows `GoalPage` in the detail (a push on iPhone; no inspector, `pickedPage`). Sidebar: Mac `Section("Goals")` of `GoalRow`s (open first) above `Section("Agents")`; iPhone a horizontal row of `GoalCard` buttons. Helpers of open goals (`helperLeads`) are taken out of the trees (workers included) and listed as `HelperRow` under the lead; `subtreeOwner` maps a helper to its lead. `HelperBloub` = helper's shape in the lead's colour inside a dashed ring of the lead's accent; `ForThisGoal` chip. `GoalRing` = `ContextRing` at the progress. Inspector: `AgentInspector(goal:titles:onOpenGoal:)` puts `GoalSummary` under the screen for the agent's open goal (led or helped). A Needs you item with `goalId` opens the goal page ("Open goal"). Debug lever `-schermes.debugOpen goal:<id>`.
- **Search (daemon, `search.ts`, slice 23):** migration 0024 (drizzle `--custom`, hand-filled SQL) adds FTS5 tables outside the drizzle schema (tokenizer `porter unicode61 remove_diacritics 2`): `messages_fts` external content over `messages` (insert/delete/update-of-content triggers; the delete trigger also drops `screenshots_fts` rowid = message id), `files_fts` (name, path, `agent_id`/`modified_at` UNINDEXED, epoch ms), `screenshots_fts` (rowid = message id, `text`; an empty text marks read-and-nothing). `startSearchIndexer(db, exec)` (`main.ts` only, every 10 min): `FILES_SCRIPT` `find` as each permanent agent in its home (dot entries pruned, depth 6, 5000 files) → `indexAgentFiles` replaces that agent's rows; rows of deleted agents purged. OCR: skipped entirely (nothing marked) unless `command -v tesseract`; else ≤10 image rows per pass, newest first, `base64 -d | tesseract stdin stdout` as a non-worker participant. `tesseract-ocr` is in `infra/install.sh`. **`POST /api/search` `{q}`** (1–300 chars) → `SearchAnswer {understoodAs, filters, byModel, hits}`; the default model (`providerConfig` + `withRetries`, 20 s `AbortSignal.timeout`) gets only the question, local today and agent names and replies JSON `{kinds, agent, from, to, words}` (`parseFilters` keeps only real agents/kinds, `YYYY-MM-DD` local days, `to` = end of day); no model, a throw or unreadable reply → `plainFilters` (the question's words). Words become an OR of quoted prefix terms; no words → newest by filters. ≤20 hits per kind, merged newest first. `SearchResult`: `kind`, `agent`, `conversationId` + `participants` + `messageId` (message/screenshot), `path` (file), `at`, `snippet`. `GET /api/search`, `searchMessages` and `SearchHit` are gone (slice 35). **Search (app, `Views/Search.swift`, slice 24):** wire `SearchAnswer`, `SearchFilters`, `SearchResult` (`thread`: one participant → `.agent`, else `.conversation`; `kindWord`), `SearchKind` (open, unknown → `.other`); client `ask(_:)` POSTs `{q}`. Asking is on Return only (each ask is a model call). Mac/iPad: a sidebar "Search ⌘K" button opens `SearchPanel` as a sheet (field, `UnderstoodAs` chips + "Plain text search" when `!byModel`, `ResultRow`s, footer line). iPhone: `.searchable` in the bottom bar only when compact (`PhoneSearch`), `.onSubmit(of: .search)` → a "Search" section in the list with the same views; errors in `searchTrouble`. `ConsoleView.open(_ hit:)`: message/screenshot → `focus = hit`, `picked = hit.thread`; file → the agent's thread plus Quick Look via `FileSource.fetch`. `ChatView(focus:)` pages back (≤10 pages) until the row is loaded, then scrolls it to the centre instead of the newest (`focusPending`); the chat's `.id` includes the focus. Lever `-schermes.debugOpen search:<question>`.
- **Snapshots and restore (daemon, `snapshots.ts`, slice 25):** no table. `runAgent` of a permanent agent (idle included) first runs `snapshotWorkspace(exec, agent, lastMessageId(db), now, signal)`: one bash script (argv marker `SNAPSHOTS`, modes snapshot|list|prune|diff|restore) as the agent writes `~/.schermes-snapshots/<mark>-<epoch ms>.{list,tgz}` (NUL manifest `size mtime path` of non-dot files, `node_modules` pruned; an unchanged manifest hard-links the previous tar; GNU find/sed/tar only). A failure is logged, the turn goes on. `pickSnapshot`: smallest mark ≥ from−1 and < 7 days old; `startSnapshotPruner` (`main.ts`, hourly) deletes older ones. `GET /api/agents/:name/rewind?from=` and `/api/conversations/:id/rewind?from=` → `RewindPreview {removed, files: FileChanges[], noSnapshot, cantUndo}`. `POST …/rewind` `files: true`: every permanent participant needs a snapshot (else 409, nothing touched), `restoreFiles` re-diffs, extracts and removes the added files, then the rows go and a `restoredLine` owner line is appended per agent before any retry turn; answers `{ok, files}`. `cantUndo(rewound, all)` (successful calls only): `send_message`, mail senders (`MAIL_SENDERS` from idle.ts), installs (`classifyCommand`), approved lines (`APPROVED`/`GO_AHEAD` in approvals.ts), `FILLED` form lines (forms.ts), `Trigger N fired:` rows. `rewoundRows` (conversations.ts) is the rewind's row set. **App (slice 26, `Views/Restore.swift`):** wire `FileChanges`, `CantUndoKind` (open), `CantUndo`, `RewindPreview`; client `rewindPreview(_:from:)`, `rewind(…, files:)`. Every Restore/Retry (menu, `/undo`, `/retry`) opens `RewindSheet` (loads the preview, toggle on only when `canPutFilesBack` = no `noSnapshot` and some change; errors inside). `Message.isRestoreLine` (prefix/middle constants in Types.swift mirror `restoredLine`) renders as `RestoreLine` and "Files put back" in the sidebar; `isOwner` excludes it.
- **Forward (slice 27):** `POST /api/agents/:name/forward` `{messageId?, file?: {agent, path}, note?}` (target via `desktopAgent`, 404 workers/unknown; 400 for neither, a bad id or a path outside the home; 404 unknown message/file agent/missing file; 413 too big). The file is read as its holder (a worker → its parent), named by `uploadName` and written to the target's `~/uploads` through `writeUpload` (shared with the uploads route). One owner row (`forwardedText`: note or "Forwarding this to you.", "Forwarded from <label|sender|something I wrote earlier>:" + `> ` quoted text, "I put the file in your home: <path>") in the target's own thread, then `runner.start`; capacity checked before the copy and again before the start. Wire `ForwardRequest`/`ForwardResult`. App (`Views/Forward.swift`): `Forwarding`, `Forwarder` (@Observable, one per `ChatView`, in the environment so equatable rows stay equal), `forwardTargets` (no workers, not the thread's own agent), `ForwardSheet` (agents by bloub + title + tagline, note, errors inside). "Send to…" on `MessageRow` (context menu + Mac hover) and on `FileCard` (card and image menus; `\.forwardedMessage` env carries the message id so a file goes with its message). Client `forward(to:_:)`.
- **New agent from a description (slice 28):** `POST /api/agents/suggest` `{description}` (1–2000 chars; nothing created) → `AgentSuggestion {name, label, tagline, look?, levels (all 9), routine?, byModel}` via `suggestAgent` (`suggest.ts`): default model (`providerConfig` + `withRetries`, 20 s timeout) gets only the description and replies JSON; label via `cleanLabel` (else plain fallback), `name` = `freeName` (TS port of the app's `agentName(for:taken:)`), look checked against `BLOUB_SHAPES`/`BLOUB_COLORS` (shared; mirror of the Swift enums), levels via `parseLevels(raw, lenient)` (rules.ts; also used strictly by `updateRules`; passwords never loosened), routine via `parseSchedule`. Fallback: label "Helper", tagline = clipped description, default levels, no look (the app draws `.standard(for: slug)`). **`POST /api/agents` with `description`** (plus optional `tagline`, `levels`, `routine`; these without a description, or with a profile, are 400; all checked before the insert): rules and schedule written, `describedKickoff` (quotes the description; asks the profile to start with the tagline line) + turn, then `desktop.ensure` in the background (failure logged, agent kept; boot/restart-desktop recover). Without a description the old synchronous path (rollback on a failed desktop) is unchanged. App: `Views/NewAgent.swift` (`NewAgentSheet` moved out of ConsoleView, `NewAgentPlan`), `AgentSuggestion`/`AgentCreate`/`Routine`/`rulesSummary` in Types.swift, client `createAgent(_ AgentCreate)` + `suggestAgent(description:)`.
- **Docs (slice 34):** `docs/architecture.md` (new sections Model registry and recovery, Agent tools, Needs you, Approvals and the rules ladder, Hand-over/forms/teaching, Feedback, Idle work, Triggers, Goals and helpers, Search, Snapshots, Forwarding and new agents, Background work; Persistence, Security, Clients updated), `docs/configuration.md` (Models registry + `provider.*` upgrade, actionable push, Live Activities, Search and OCR, Triggers and the webhook URL, per-agent settings, TLS for secrets), `docs/development.md` (test layout and seams, Swift tests, a daemon without Docker, the provider stub, DEBUG levers, migrations + boot check), `apple/README.md` (Targets, device-only entitlements, app group, APNs environment, actionable push, Live Activity, a file map). Keep them current when behaviour changes. **Migrations 0000–0025 are all drizzle-generated** (`pnpm migrations` says "No schema changes"); 0024 is the one `--custom`.
- **Smoke (`infra/smoke.sh`, slice 35):** before the harness gate: leftover `smoke-registry` models and the smoke agents' triggers are removed, then the model registry and rules sections run. Harness only: `POST /api/search`, the `guarded` stub script (delete refused → `request_approval` → `propose_trigger` webhook), the approval denied from Needs you, and the webhook turned on and fired. `settle` waits for a `turn` event past a per-agent mark (`$tmp/mark-<agent>`), because `waiting_for_user` is also the state before a turn starts. Run it in a throwaway compose project (see the memory note), twice in a row.
- **Tests:** Swift in `ThemeTests`/`TypesTests`/`ThreadTests`; daemon in `api.test.ts` (routes, flows, stubs), `loop.test.ts`, `tools.test.ts`, `browser.test.ts`, `forms.test.ts`, `provider.test.ts`. Per-feature detail is in each slice entry. The `api.test.ts` fixture exposes `exec`, `ran`, `stdin`, `requests` (every model request, serialized) and `intercept(handler)` (answers exec calls first; `fakeSnapshots` uses it). **Test running:** `xcodegen generate` after adding files. Full target on the iPhone 17 Pro simulator (focus-free), then macOS once, with `-derivedDataPath <scratchpad>/dd`. The Mac app is driven focus-free with the DEBUG launch levers `-schermes.debugPassword` and `-schermes.debugOpen <target>` (`needs-you`, `agent:<name>`, `pages:<name>:<Page>`, `settings` + `-schermes.settingsTab`), recipe in memory `project_apple_app_testing_levers`. Check Mac screens at runtime with it; "login gate" is no longer a reason to skip. **Simulator driving:** `idb` needs the shimmed `XShim.app/Contents` in the scratchpad (`DEVELOPER_DIR=<shim>/Developer idb_companion --udid <sim> --grpc-port <free>`, then `idb --companion localhost:<port>`). Taps are in points. **Scratch bed:** `SCHERMES_PORT=7795 SCHERMES_DATA_DIR=<scratchpad>/data node src/main.ts`; the simulator app points at it and is logged in. Seed with a node script (`openDb`, `insertAgent`, `appendMessage`); set states with sqlite. Boot DB-upgrade checks on a copy and a spare port, never on 7795.

## Slice: 1 — design-system foundation, chat and agent list
**Shipped**
- **`Theme.swift`:** tokens, `AgentPalette`, state presentation and `StateLine`.
- **`ThemeTests.swift`:** 36 test cases, all passing.
- **Chat:**
  - the agent's tint as the background;
  - a flat bubble, so `accent.gradient` no longer appears in `ChatView.swift`;
  - the header pill shows `StateLine`;
  - rounded fonts for the name, the empty-state title and the speaker names.
- **Agent list (`AgentRow`, `WorkerRow`):**
  - the bloub without a badge;
  - the rounded name;
  - the tagline, in muted colour;
  - the state line;
  - the last line, in secondary colour;
  - ground behind the list on iOS and behind the detail column.
- **Other views:** `Activity.swift` and `DesktopView.swift` use `StateLine` and `palette().accentText`.

**Key decisions**
- `waiting_for_user` shows as "Ready", not "Needs you": it is the resting state after every turn.
- The list rows are not tinted cards yet. The later iPhone home slice builds agent cards.
- `StateLine` uses an `HStack`, not a `Label`: an iOS list row puts a label's icon in a separate column, away from the word.

**Placeholder choices** (review):
- **Dark values for tokens the canvas only gives in light:**
  - secondary `#cfcbd6`;
  - needsYou `#f5a55a`;
  - failed `#ff8a80`;
  - retrying `#e8c35a`;
  - done `#5fd39a`.
  - Ground `#17161a`, window `#0f0e12`, ink `#f3f1ec` and muted `#a8a4b3` come from the canvas script.
- **State symbols and words:**

  | State | Symbol | Word |
  |---|---|---|
  | idle | `moon.zzz` | Idle |
  | thinking | `ellipsis.bubble` | Thinking |
  | using_computer | `cursorarrow.rays` | Using the computer |
  | using_terminal | `terminal` | Using the terminal |
  | waiting_for_user | `bubble.left` | Ready |
  | waiting_for_agent and waiting_for_task_worker | `hourglass` | Waiting for … |
  | failed | `exclamationmark.triangle` | Failed |
  | completed | `checkmark.circle` | Done |

  Completed uses the green done token, although the canvas shows Done text in muted.
- **The tagline comes from the profile's first line of prose.** A real label field should come with "new agent from a description".

**Verified**
- `xcodebuild test`: on the iPhone 17 Pro simulator, 144 tests passed (exit 0); on macOS, 145 passed (exit 0).
- Rebuild for the simulator after the `StateLine` tweak: exit 0.
- Focus-free simulator screenshots, taken against a scratch daemon with 5 seeded agents:
  - **Light list:** warm `#f6f4ef` ground and bold rounded names with taglines ("Mo Travel and errands.").
    - Ready in muted, Done in green with a check, Idle with a moon, Thinking in Juno's blue, Failed in red with a warning sign.
  - **Mo's chat:**
    - violet-tinted background (#efe9ef);
    - a flat violet bubble with white text;
    - the link in violet accent text;
    - the header pill shows "Mo" in rounded type with the Ready icon and word.
  - **Dark:** a deep violet tint in the chat, the same flat bubble, and the list on the dark ground.

**Runtime-unverified**
- The Mac chat was not screenshotted. The Mac app can't get past its login screen without the owner typing the password (see the memory notes). Mac is covered by the macOS build and tests only.
- On iPad, only the shared code path was exercised.

**Notes / leftovers**
- Not done in this slice:
  - SF Mono for paths and commands;
  - the busy halo ring;
  - names in pickers;
  - the context meter;
  - the sidebar sections;
  - the inspector;
  - the iPhone home.
- The dark iOS list shows the system's grouped cells over the ground. The home slice replaces them with cards.

## Slice: 2 — SF Mono, busy halo, names beside bloubs, context meter
**Shipped**
- **Daemon:**
  - `contextFullness` in `loop.ts`;
  - `existingConversation` and `listMessagesWithoutImages` in `conversations.ts`;
  - `GET /api/agents` carries `contextFullness`;
  - `Agent.contextFullness?` in `shared`;
  - an `api.test.ts` case covering: 0 with no thread and no thread created, 25%, clamping at 100, and a summary resetting it.
- **App:**
  - `busyHalo`, `ContextFullness`, `ContextRing` and `ContextMeter` in `Theme.swift`;
  - the halo on `AgentRow`, `WorkerRow`, the single-agent pill and each group-pill member;
  - the Mac meter as a toolbar item, and the iPhone ring around More;
  - SF Mono on the tool name, the file-card name and the artifact header;
  - `GroupRow`, the group pill and the group empty state now name every bloub;
  - `Agent.contextFullness`;
  - 6 new Swift test cases.

**Key decisions**
- **Fullness is measured against compaction, not the model's context window.** The daemon knows no context window. `MAX_TRANSCRIPT_CHARS` is the point where the thread gets summarised, so 100% means "compacts next turn".
- **It is computed on each poll, without screenshot bytes.** A `ponytail:` note in `contextFullness` names the O(agents × participant rows) ceiling.
- **The Mac meter shows wherever the inspector column is offered** (`inspector != nil`), and the ring shows wherever the More menu is. That follows width, not platform.
- **The idle mapping stays `idle → .idle` (open eyes).** Remapping to `.sleep` was tried and reverted: `.sleep` is a tiny eyeless ball, which reads as a dot at list size. `completed → .sleep` already shows that dot.

**Bloub call sites** (the evidence that no bloub-only row remains):

| Site | Verdict |
|---|---|
| `AgentRow`, `WorkerRow`, the single-agent pill, the `DesktopView` identity, the speaker row in `ChatView`, the approval row (named in its sentence) | Named already |
| `GroupRow`, the group pill, the group empty state | Fixed |
| `NewAgentSheet` and the `BloubPicker` preview | Name field under it |
| Picker shape chips, `About`, `Entry` | Not an agent |

**Placeholder choices** (review):
- The iPhone More button shows a plain `ellipsis` inside the ring, instead of `ellipsis.circle`, when fullness is known.
- The Mac meter has no background capsule of its own, because the toolbar puts it on glass.
- The ring track is ink at 12%.

**Verified**
- `pnpm check` → 0.
- `pnpm test` → 0.
- `xcodebuild test`:
  - iPhone 17 Pro simulator → 0, 146 passed, run again after the idle revert;
  - macOS → 0, 147 passed.
- **Focus-free simulator screenshots** against the scratch daemon, with Mo and Juno set to thinking and Mo holding a 248k-character tool result:
  - **List:** Mo and Juno show the halo ring in their own colours (violet, blue).
  - **Mo's chat:** the halo on the header bloub, and a violet ring around More at about 62%.
  - **Scout's chat:** only the ring's track, at 0%.

**Runtime-unverified**
- The Mac chat-header `ContextMeter` (login gate): build and tests only.
- The group pill and `GroupRow` with names: no group thread was seeded.

**Notes / leftovers**
- **Closed eyes for idle and done aren't met.** The canvas shows slit eyes on the agent's own shape. The engine has no shut-eye expression, and `.sleep` is a small eyeless ball.
  - It needs a `BloubExpressionId` with shut lids (or an `open: 0` pose), wired through `BloubView`. Bloub goldens pin that code, so it belongs in its own slice.
  - Until then, idle keeps open eyes and done keeps the dot.
- Still to build: the sidebar sections, the inspector, the iPhone home, and everything from Needs you onward.

## Slice: 3 — request_approval and GET /api/needs-you (daemon)
**Shipped**
- **`shared`:** `ApprovalKind` gains `action`; `APPROVAL_CATEGORIES`/`ApprovalCategory`; `Approval.category`, `amount?`, `origin?`; `NeedsYouKind`, `NeedsYouAction`, `NeedsYouItem`.
- **Migration `0013_aromatic_metal_master.sql`** (from `pnpm migrations`): `category` text NOT NULL default `delete_files`, `amount` and `origin` nullable.
- **`approvals.ts`:** `parseApprovalRequest`, `requestApprovalToolDef`, category words in `describeApproval` ("spend money: Acme (EUR 42.50) at pay.acme.test"); `insertApproval` defaults the category.
- **`loop.ts`:** `request_approval` offered to permanent agents next to `request_deletion`; both dispatch through `standingRequest`. An action's tool text says "Do not do it yet."
- **`needs.ts`** + `GET /api/needs-you` in `app.ts`; the approve route's `action` branch.
- **App:** `ApprovalKind.action`, `Approval.category/amount/origin`; `ApprovalRow` reads "Mo wants to spend money (EUR 42) at ns.nl" with Don't / Approve; the local notification says "Asks first" for an action.
- **Tests:** tools.test "an approval request carries a known category…", loop.test "request_approval and request_deletion both leave a standing request…", api.test "needs you lists approvals, waiting questions and failures, and each leaves once resolved", TypesTests "approvalsDecodeBothDeletionsAndActions".

**Key decisions**
- **Needs you is derived, not stored.** Every item comes from rows that already exist (approvals, the transcript, the agent state), so resolving from any route removes it with no extra bookkeeping.
- **A question is detected from the transcript, not from `waiting_for_user`,** because that state is also the resting state and is agent-wide while a question belongs to one thread. An owner row after the call resolves it (a `user` row with no sender, so an approval answer or a schedule delivery counts too); a worker report does not, matching `pendingInterview` in `Thread.swift`.
- **Failures are permanent agents only.** A worker's failure is reported to its parent, which decides.
- **An approved action performs nothing in the daemon.** The agent is told to go ahead and does the thing itself. The rules slice decides what the daemon hard-enforces.
- `passwords_security` is a category now, but nothing enforces "always the owner's" yet beyond the tool description; that is the rules slice.

**Placeholder choices** (review):
- Category words: browse, run a command, write files, delete files, send a message, spend money, install software, share something outside, change a password or security setting.
- Item titles: approvals "Asks to …", questions the first question text (detail "and N more questions"), failures "Could not finish its turn" with the error as detail.
- Action card buttons "Don't" and "Approve" (not destructive-styled).

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (229 passed), re-run after the final edits; the needs-you test looped 20 times with no failure.
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (147 passed); macOS → 0 (148 passed).
- A fresh database and a copy of the slice 2 scratch database (with an old approval row inserted first) both boot; the old row reads `delete_files`, and `GET /api/needs-you` answers `[]` on the fresh one after setup.

**Runtime-unverified**
- The action approval card and its buttons were not seen on screen; only decoding and the string logic are covered.

**Notes / leftovers**
- The needs-you read scans every thread of every agent per call (a `ponytail:` note in `needs.ts`).
- The app still polls `/api/approvals` and shows approvals as glass cards above the list; the next slice moves this to `/api/needs-you`.

## Slice: 4 — Needs you in the app (Mac page, iPhone strip)
**Shipped**
- **Client:** `NeedsYouKind`, `NeedsYouAction` (open enums with `.other`), `NeedsYouItem` in `Types.swift`; `needsYou()` replaces `approvals()` in `SchermesClient.swift`.
- **`Views/NeedsYou.swift`:** `Approval.asks/noWord/yesWord/yesRole` (the old `ApprovalRow` wording), `NeedsYouItem.presentation`, `retryStart`, `NeedsYouPage` (cards; on wide windows a side column with Right now and Last night, stacking via `ViewThatFits`), `NeedsYouCard`, `NeedsYouStrip`.
- **`ConsoleView`:** one poll of `/api/needs-you`; `SidebarPick` selection; a "Needs you" sidebar row with `.badge(count)` when roomy, the strip at the top of the list on compact (only when something waits); the page in the detail; the inspector closed while the page shows; `act`, `retry`, `open`; notifications and the app badge per item. The glass approval cards and `ApprovalRow` are deleted.
- **Theme:** `Theme.card` and `Theme.needsYouFill`.
- **Tests:** `needsYouKeepsKindsAndActionsItDoesNotKnow` (TypesTests), `aFailedTurnRetriesFromAfterItsPromptUnlessTheOwnerWroteSince` (ThreadTests).

**Key decisions**
- **Unknown kinds stay listed** (with an Open button) and unknown actions render nothing, so the badge always equals the endpoint's length.
- **Retry pages back** up to 5 × 200 rows (a failed turn can be 200 steps) to find the prompt, and falls back to opening the thread when the prompt isn't found, the owner wrote since, or the daemon refuses (busy, no provider).
- **Opening a shared thread** sets `expanded` and lets the conversations loop load it, rather than writing `conversations` (that loop clears it on restart).
- Buttons sort quiet-first (Don't, Keep it, Open) and go-ahead last, whatever order the daemon sends.
- "Right now" lists every busy agent, workers included, with `StateLine`; it shows only on the wide layout.

**Placeholder choices** (review):
- State words: "Needs you · asks first", "Needs you · delete", "Needs you · question", "Failed", with `bell` / `exclamationmark.triangle`.
- Card token `#ffffff` / dark `#232127`; strip fill `#fbd9b4` (canvas) / dark `#4a2c10`.
- Approve on an action uses the agent's bubble colour; Answer and Retry are ink; quiet buttons are ink-tinted bordered.
- Strip copy: "N things need you" plus the first item ("Mo wants to spend money: …"); page subtitle "N things are waiting on you. Everything else is running on its own."
- Last night empty state: "What your agents do while you're away will show here."
- No elapsed time on Right now rows (the canvas shows "12m"; the daemon has no state-since time).

**Verified**
- `pnpm check` → 0; `pnpm test` → 0.
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (149 passed), macOS → 0 (150 passed), both re-run after the final edits.
- Focus-free simulator run against the scratch daemon (7795) seeded with an action approval (Mo), a delete request (Ledger), a two-question `ask_owner` (Scout) and a failure (Pixel), Juno thinking:
  - the strip reads "4 things need you" with three bloubs; tapping it opens the page with all four cards, state icon plus word, and the right buttons;
  - Don't on Mo's card → `/api/needs-you` drops `approval:1` and the card leaves;
  - Retry on Pixel with no provider → refused, the thread opens, no rows deleted;
  - Answer on Scout → Scout's thread with the question form.
- Screenshots: `s4-list.png`, `s4-page.png`, `s4-retry.png`, `s4-answer.png` in the session scratchpad.

**Runtime-unverified**
- The Mac sidebar row, badge and the wide page with Right now (login gate): build and tests only.
- A successful retry (needs the provider stub), and answering a question removing the item (covered by the daemon's api.test).
- Dark mode of the page and strip.

**Notes / leftovers**
- Last night is a header and an empty state until idle work.
- The Needs you page shows `trouble` nowhere; a failed decide is only visible in the list overlay when the list is empty.
- The rest of the sidebar (Search ⌘K, Goals, Messages sections), the inspector redesign and the iPhone home cards are still to build.

## Slice: 5 — rules ladder in the daemon, Always allow
**Shipped**
- **Wire (`shared`):** `RULE_LEVELS`, `RuleLevel`, `AgentRules`, `AgentRulesUpdate`; `NeedsYouAction` gains `always`.
- **Storage:** `agents.rules` and `agents.grants` (JSON text), migration `0014_fluffy_rumiko_fujikawa.sql` from `pnpm migrations`.
- **`rules.ts`:** `DEFAULT_LEVELS`, `readRules`, `updateRules`, `rulesPrompt`, `classifyCommand`, `guardCommand`, `grantOnce`, `alwaysAllowable`, `alwaysAllow`. `CATEGORY_WORDS` and `MAX_TARGET_CHARS` are now exported from `approvals.ts`.
- **Routes (`app.ts`):** `GET`/`PUT /api/agents/:name/rules`; `always` on `POST /api/approvals/:id`; a plain approve of a delete/install action records a grant.
- **Loop:** rules text in the system prompt (`homeTail`); `guardCommand` before `run_command`. The `run_command` description says installs go "when your rules allow it".
- **App:** `NeedsYouAction.always`, `decide(approval:approve:always:)`, an "Always allow <origin>" button between Don't and "Approve once" (Approve keeps its word when there is no Always).
- **Tests:** api (rules routes including the refused `passwords_security`, Always allow, the needs-you actions), loop (prompt text, refusal under Ask first, one pass after approval, refused again), tools (classifier table, ladder, grant kept on refusal, worker text, update validation).

**Key decisions**
- **Always allow on an Ask first category lifts it to If pre-approved.** The canvas shows Always allow on an Ask-first spend, and the list is only read at If pre-approved, so without the lift the button would do nothing.
- **Always allow never covers delete, install or passwords:** there the target is the model's own path or package string, and a standing pass would be a blank check. The owner can still put a package on the list via `PUT`, and If pre-approved then lets exactly those installs through.
- **The ladder is enforced monotonically** for delete and install: On its own passes; If pre-approved passes when every target is on the list, else needs a grant; Ask first needs a grant; Hand to you refuses even with a grant.
- **Workers run under their parent's rules** (they run as its Linux user). Their refusal tells them to report back, since they have no `request_approval`.
- **Grants match exactly** on category and the target the refusal named (the joined targets, capped at 256), are kept at most 20 per agent, and don't expire.
- **Owner-driven commands** (`POST /api/agents/:name/command`, the smoke's `run_cmd`) are not guarded: the rules are about the agent.
- **Passwords and security are never delegated:**
  - The owner can't `PUT` another level for it.
  - Approving an action in a category at Hand to you (always so for passwords) tells the agent "the owner … will do it themselves. Do not do it." It records no grant and gives no "Go ahead".
  - The app's yes word there is "I'll do it".
  - The `request_approval` description says the same.

**Placeholder choices** (review):
- Defaults: browse, run commands, write files **On its own**; send messages **If pre-approved**; delete files, spend money, install software, share outside **Ask first**; passwords **Hand to you**. These follow the canvas where it shows them (write and share are guesses). Delete and install at Ask first means every agent `rm` and `apt-get install` now needs an approval.
- Prompt wording in `LEVEL_WORDS` and the refusal texts.
- The "Always allow" button uses the agent's accent text colour, bordered.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (236 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (149 passed); macOS → 0 (150 passed).
- A fresh database and a copy of the scratch bed (at 0013) booted on spare ports 7803/7802: 15 migrations, `rules` and `grants` columns present, and an upgraded agent reads the defaults.

**Runtime-unverified**
- The Always allow button on screen (build and decode test only); the scratch bed daemon on 7795 still runs the slice 4 code.

**Notes / leftovers**
- ponytail: the classifier sees words in command position only. It skips `sudo`/`env`/`xargs`/`nice` and similar, plus the shell keywords `do`, `then`, `else`, `if`, `{` and `!`, so loops and conditionals are covered. `bash -c "…"`, `eval`, scripts, the computer tool and MCP tools get past it; those stay prompt-level. The brief's "own file-delete paths": no agent-facing delete tool exists, so `run_command` is the only guarded path.
- Browse, spend, send and share are prompt-level only, as scoped.
- `infra/smoke.sh` does not cover the rules refusal yet (the DoD wants it in the final smoke). `infra/provider-stub.py` scripts no agent-side delete or install, so the new defaults don't break the smoke.

## Slice: 6 — rules in the app (Mac page, iPhone sheet)
**Shipped**
- **Client:** `RuleLevel` (open enum, unknown values kept as `.other`), `AgentRules`, `AgentRulesUpdate` (nil fields are left out of the PUT); `rules(agent:)` and `setRules(agent:_:)`.
- **`Views/Rules.swift`:** `RuleRow` (canvas names and hints, the locked passwords row), `RuleLevel.word`/`short`, `RulesView`: 8 level rows, the locked "Always yours" row, the pre-approved list with add and remove.
  - macOS: a segmented control with the canvas's short words when the row is wide enough (`ViewThatFits`), else the compact row.
  - iOS (and the narrow Mac inspector): the level word in colour with a menu of the four levels. Accent text for On its own and If pre-approved, `Theme.needsYou` for Ask first, ink for Hand to you.
- **Entry points:** `AgentPages.Page.rules` (so the Mac inspector overview lists it), "Rules…" in the agent's context menu (sheet opened on the page), "Rules" in the iPhone chat's More menu.
- **Tests (`TypesTests.swift`):** rules decode with an unknown level, the update encodes only what changed, rule rows follow the daemon's category order with passwords locked.

**Key decisions**
- **Browse and run commands stay two rows on both platforms.** The Mac canvas has them apart; the phone canvas's merged row would have to hide a split level.
- **A menu instead of a drill-in on the phone.** The pages live in the inspector column too, where a `NavigationLink` would push onto the chat's stack (the reason `AgentPages` keeps its own state). The menu shows the coloured level word, per the canvas.
- **Rules is a page of the existing `AgentPages`**, not a new settings screen: Profile, Routines, Activity and Memory are its siblings there, which covers the canvas's other settings rows for now.
- **Write-through, no Save button:** the daemon's answer replaces local state; a refused pre-approved entry keeps the typed text.

**Placeholder choices** (review):
- Row hints: "Its own files, mostly in ~/workspace" (canvas: "Anywhere under ~/workspace"), "As <name>, in its own home", the rest from the canvas.
- The page's footer copy explaining the ladder, and the pre-approved footer.
- `checkmark.shield` as the Rules icon; a minus-circle in the failed colour for Remove; field prompt "flytap.com or someone@example.com".

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (236 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (152 passed); macOS → 0 (153 passed).
- Simulator against the scratch bed (restarted on current code, so 0014 applied there): the sheet opens from More, Spend money set to If pre-approved landed in `agents.rules`; adding "FlyTap.com" stored `flytap.com`; "a b" showed the daemon's refusal under the field and kept the text; Remove emptied the list. Mo's rules were reset to NULL afterwards.

**Runtime-unverified**
- The Mac layout (segmented rows on the sheet, compact rows in the inspector): build and tests only, as the Mac app can't pass its login.

**Notes / leftovers**
- No routines count or "When idle" row on the rules page; those come with the triggers and idle slices. No `/rules` slash command.
- No `rules.ts` bug found.

## Slice: 7 — model registry in the daemon
**Shipped**
- **Storage:** `models` table and nullable `agents.model_id` (references `models.id`), migration `0015_flimsy_shen.sql` from `pnpm migrations`.
- **`models.ts`:** list/find/create/update/delete, `setDefaultModel`, `setBackupModel`, `assignModel`, `modelConfig`, `providerConfig` (moved here from `settings.ts`, now per agent), `parseExtraBody` (moved), `readProviderSettings`/`writeProviderSettings` over the default entry, `migrateProviderSettings`. The `provider.*` helpers are gone from `settings.ts`.
- **Routes (`app.ts`):** the model CRUD, default, backup, per-model test (shares `testProvider` with `POST /api/settings/test`), agent assignment.
- **Loop:** `RunnerDeps.provider` takes the agent; the runner resolves every turn's provider for that agent (workers through their parent). App-side gates (agent and thread sends, creation kickoff, retry) check each agent's own model; compaction builds one provider per agent.
- **Wire (`shared`):** `ModelEntry`, `ModelUpdate`, `Agent.modelId?`.
- **Tests (`api.test.ts`):** CRUD with validation and keys never in responses or in plain text at rest; default/backup and the delete refusals; assignment routes an agent's turn to its own endpoint while another agent uses the default, and a worker resolves to its parent's model; the `provider.*` migration (idempotent, rows removed, key usable) and a fresh database with none. The old settings round-trip test now checks the `models` row.

**Key decisions**
- **Default and backup are settings keys, not flags:** one of each by construction, with no uniqueness juggling.
- **The `provider.*` move is a boot step in code, not SQL:** migrations stay generated. It copies the key as ciphertext (no master key needed), runs only when the registry is empty, and deletes the old rows, so it is idempotent.
- **Delete:** refused (409) while any agent is assigned the model, and for the default while another model exists (pick a new default first). Deleting the last model is allowed and leaves none. Deleting the backup clears it.
- **The first model created becomes the default**, and so does the one `PUT /api/settings` creates, so the current app Settings screen keeps working unchanged.
- **An empty `apiKey` removes the key** (on `PUT /api/models/:id` and the legacy settings PUT). Before, the legacy PUT stored an encrypted empty string that read as "set".
- **A model without a key does not resolve**, as before: the loop needs base url, model id and key.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (239 passed).
- `xcodebuild test` on the iPhone 17 Pro simulator → 0 (152 passed); the app is unchanged, `modelId` is an extra key it ignores.
- Boot: a copy of the scratch bed with `provider.*` rows added booted on 7811: 16 migrations, one default model holding those values, the `provider.*` rows gone. A fresh database booted on 7812 with no models.

**Notes / leftovers**
- No Settings UI for models yet, and the app still edits the default through `/api/settings`. No backup-on-429 logic (recovery slice).
- Workers cannot be assigned; they follow their parent.
- `infra/smoke.sh` still uses `PUT /api/settings`, which now writes the default model; it does not cover `/api/models` yet (the final smoke should).

## Slice: 8 — model registry in the app
**Shipped**
- **Client:** `ModelEntry`, `ModelUpdate`, `Agent.modelId` in `Types.swift`; `SchermesClient` calls for list, create, update, delete, default, backup, test and agent assignment; `modelPick(_:)` so "no backup" and "back to default" send `{"id":null}`.
- **Settings (`Settings.swift`):** the single-provider page is replaced by `ModelPage` (list, badges, Test, More menu, swipe to delete on iOS, the daemon's 409 text under the list) and `ModelSheet` (name, base URL, model id in SF Mono, a write-only key showing "Set"/"Not set", extra body JSON). Same views in the Mac Settings window and the iOS sheet.
- **Assignment (`Activity.swift`):** `AgentModelRow` on the agent Overview, a menu of names plus "Default (<name>)", hidden for workers; reverts and shows the error when the PUT fails.
- **Tests (`TypesTests.swift`):** entry decoding, `modelId` absent and present, `{"id":null}` encoding, edits sending only what changed and never a blank key.

**Key decisions**
- The list is refetched after every change, since the daemon moves the badges itself.
- The app dropped its use of the provider fields of `/api/settings`; the daemon keeps them for the smoke test.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (239 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (156 passed); macOS → 0 (157 passed).
- Simulator against the scratch bed (restarted on current code): added "Sim Local" through the sheet (key stored encrypted, not in plain text), Test answered, Make default moved the badge (`models.default` = 3), deleting the default showed "make another model the default first", assigning it to Mo stored `model_id` 3 and the row read "Sim Local", then Default put it back to NULL.
- **Mac login screen: passed, focus-free.** `set_value` shows dots but leaves the SwiftUI binding empty; background `press_key` per character, then Return, logs in. Sidebar and data from a copied bed rendered in dark mode. Recipe in memory `project_apple_app_testing_levers`.

**Runtime-unverified**
- The Mac model settings, rules page, Needs you page and chat: background AX press and pixel clicks don't select sidebar rows, and opening Settings needs Cmd+, or a menu that may activate the app. No light-mode Mac screenshots.

**Notes / leftovers**
- iOS offers "Save Password?" after saving a model key (the key is a `SecureField`); the Web search and push key fields have the same pattern. A `.textContentType` tweak may silence it; not done.
- On iOS the borderless "Add model" button reacts only on its label, not the whole row.
- Mac dark-mode observations from the one screenshot: agent names in the sidebar render dim grey, and the "No thread picked" placeholder sits in a near-black box on the ground. Worth a look in a polish slice.
- The Mac login wrote `schermes.serverAddress` into the shared defaults domain; it was restored to the owner's value. A Keychain item for `http://127.0.0.1:7831` was added by the test login.
- No daemon bug found in slice 7's routes.

## Slice: 9 — model recovery (429/5xx retries, backup, refused key)
**Shipped**
- **Daemon:** `withRetries` in `provider.ts` (5 attempts, backoff or `Retry-After`, Retry now, Use backup model, stop cuts the wait); `openAiProvider` single-shot with status info; `agentProvider` in `app.ts`, the `retry` field on `/live`, `POST /api/agents/:name/retry`; `modelIdFor`, `backupConfig`, `recordAuthFailure`/`clearAuthFailure`/`listAuthFailures` in `models.ts`; the `provider_auth` Needs you item in `needs.ts`.
- **Wire:** `RetryState`, `LiveReply.retry`, `NeedsYouKind` `provider_auth`, `NeedsYouAction` `settings`.
- **App:** `RetryState`, `.providerAuth`, `.settings` in `Types.swift`; `retryModel` client call; `RetryCard`; "Open model settings" on the card; `SettingsSheet(start:)`, Mac tab selection.
- **Stub:** `status-NNN` keys.
- **Tests:** `provider.test.ts` (cap and waits, Retry-After, 401 not retried, plain errors not retried, Retry now, Use backup, stop in the wait; the old one-retry tests now run through `withRetries`); `api.test.ts` 4 tests on a real `node:http` stub (503 ×5 with Retry now each wait and the failure in Needs you; 429 with Retry-After 30 then backup; 401 on two agents = one item, no retries, backup untouched, gone after a key change with both failures back; cleared by an answered call); `TypesTests.swift` 3 tests.

**Key decisions**
- **Retries moved above `makeProvider`**, and only retryable `ProviderError`s are retried, so scripted test providers' plain errors still fail at once.
- **Attempts count across a switch to the backup** (5 calls per model step in all). The backup is offered only while waiting, never picked on its own, never for a 401.
- **Refused-key state is a settings row per model**, not a table: one item by construction, the first refusal kept.
- **Per-agent 401/403 failures are hidden while a refused-key item exists**, matched on `HTTP 40[13]` in the failure line; once the key is fixed they come back with Retry.
- **The compaction route retries like a turn; the settings and model test routes do not** (the owner is waiting on them).

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (250 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (159 passed); macOS → 0 (160 passed).
- Simulator against the bed (restarted on this code, stub on 7821 with `status-NNN`): Mo on "Limited" (429) showed the Retrying card with the countdown and both buttons; Retry now moved it to attempt 3; Use backup model finished the turn on the Stub model. Mo and Juno on "Refused" (401) made one `provider-auth:5` item; its card showed "Needs you · key refused" and "Open model settings", which opened the sheet on Models. A key change removed it and brought back both failures.

**Placeholder choices**
- Copy: "<model> is busy. Trying again in N s, attempt X of 5", "<model> refused its key" (reads oddly for a model named "Refused"), "Needs you · key refused", the `key` and `arrow.clockwise` symbols; the card on `Theme.card`.

**Runtime-unverified**
- The Mac: the retry card, the refused-key card and opening the Settings window on the Models tab (sidebar rows can't be selected in the background).

**Notes / leftovers**
- The bed keeps models "Limited" (id 4, `status-429`) and "Refused" (id 5, key now `fixed-key`); Stub (id 1) is the backup; Mo and Juno are back on the default. A session row `slice9-probe-session` lets `scratchpad/api.sh` call the bed.
- `GET /api/agents` rows include `rules` and `grants` (seen in a PUT response); not touched.
- The retry wait is process state: a daemon restart mid-wait drops it, as the turn itself is dropped.

## Slice: 10 — browser watchdog (the last Recovery item)
**Shipped**
- **Daemon:** watchdog in `browse` (`reach` probe, `Hung` timeouts, `stopBrowser`, one automatic restart with the action redone, `BROWSER_HUNG` on the second stall, injectable `BrowserTimings`); `loop.ts` ends the turn `waiting_for_user` on `hung` and records `restarted`/`hung` on the `tool_result` event; `hungBrowsers` in `needs.ts`; `POST /api/agents/:name/browser/restart`.
- **Wire:** `NeedsYouKind` `browser_hung`; `NeedsYouAction` `restart_browser`, `restart_desktop`, `screen`.
- **App:** the new cases in `Types.swift`; `restartBrowser(agent:desktop:)`; `BrowserHungCard` above the composer (Restart browser, Restart desktop and retry, Look at the screen → the `.screen` command's `showScreen()`); Needs you card buttons (stacked through `ViewThatFits` when narrow), `screen` quiet and first; `ConsoleView.act` restarts, or opens the thread plus the inspector when roomy.
- **Tests:** `browser.test.ts` (hang once → stop, start, action redone; keeps hanging → one stop only, `hung`; a refusal is not a hang; navigate now probes first); `loop.test.ts` (hung twice → one model call, `waiting_for_user`, event flags, the Needs you item, cleared by an owner line); `api.test.ts` (item shape, 400/404, browser restart kills as the agent and starts a turn, desktop restart stops and ensures); `ThreadTests`, `TypesTests`.

**Key decisions**
- **Derived from the transcript, not stored:** the hung tool row is both the Needs you item and the chat card, like `ask_owner` questions. The restart route's owner line clears both.
- **"Restart desktop and retry" does not rewind.** It restarts the desktop and tells the agent to try again in a new turn: the item hangs off a tool row `retryFrom` doesn't map, and a rewind would drop the turn's progress.
- **A hang is a stall, not a refusal:** probe timeouts, a start that never answers, and navigate/read timeouts. Page errors and exec failures are plain errors. An `evaluate` timeout is never redone, since it may already have clicked.
- **Owner restart doesn't start Chromium;** the agent's next browse does. The automatic restart is on the `tool_result` event, not a new `EventType`, because Swift's `EventType` is a closed enum.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (255 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (161 passed); macOS → 0 (162 passed).
- Simulator against the bed (restarted on this code, a hung row seeded in Scout's thread): the chat card and the Needs you card rendered with all three buttons and the count went to 5.

**Placeholder choices**
- Copy: "Needs you · browser stuck", "<Agent>'s browser stopped answering", "It was restarted once on its own and still does not answer.", "I restarted your browser. Try again.", "I restarted your desktop, browser included. Try again."; the `exclamationmark.triangle` symbol; probe 5 s.

**Runtime-unverified**
- A real Chromium hang, and the kill command (`pkill -x chromium`, `pgrep` wait) on the Debian image.
- Pressing the buttons live: the bed runs the real `sudo` and a real `DesktopOps`, so they weren't tapped. The routes are covered by `api.test.ts`.
- The Mac card and "Look at the screen" opening the inspector.

**Notes / leftovers**
- Scout's row in the list shows the tool error as its last line (the turn ends on a tool row, as `ask_owner` turns do).
- On iPhone, "Look at the screen" in Needs you opens the thread, not the desktop cover; the chat card's button opens it.
- The bed: Scout (conversation 3) keeps the seeded hung row; the daemon on 7795 now runs slice 10's code (log `scratchpad/daemon-s10.log`).

## Slice: 11 — ask for hands
**Shipped**
- **Daemon:** `ask_for_hands` tool (`control.ts`: `askForHandsToolDef`, `parseHandsReason`, `HANDS_BACK`), dispatch and the `hands` end-of-turn branch in `loop.ts` (delivers "Asks you to take the screen: <reason>"); `handOvers` in `needs.ts`; `GET …/control` adds `handOver`; `DELETE …/control` tells the asker and starts a turn when one is pending.
- **Wire:** `NeedsYouKind` `hand_over`, `NeedsYouAction` `take_screen`, `ControlState` in `shared`.
- **App:** `.handOver`/`.takeScreen` in `Types.swift`; `ControlState.handOver` (optional); `pendingHandOver` + `ChatRows.handOver`; `HandOverCard` above the composer; Needs you card "Take the screen" and presentation "Needs you · hands"; `ConsoleView` takes control then opens the desktop; `DesktopView` "Give it back".
- **Tests:** `loop.test.ts` (empty reason refused and the turn goes on; accepted call ends the turn, item shape, cleared by the owner line); `api.test.ts` (item, `handOver` on GET, take holds and refuses input, give back posts the line, starts a turn, clears the item; the plain take-over test now asserts no line is written); `TypesTests` (kind/action, `ControlState` with and without `handOver`); `ThreadTests` (`pendingHandOver`).

**Key decisions**
- **Give back reuses `DELETE …/control`**; the line is written only when `handOvers` finds a pending request, so an ordinary take-over is unchanged.
- **The line is an owner (`user`) row**, like the browser-restart lines, so it clears the card and the item by the existing rule.
- **"Give it back" is the existing return button relabelled**, driven by `handOver` on the control poll (and on the take response), so every place that shows `DesktopView` gets it.
- **Taking from Needs you opens the desktop directly** (Mac window, iOS full-screen cover), so the owner never holds a screen they can't see.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (257 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (164 passed); macOS → 0 (165 passed).
- Simulator against the bed (restarted on this code, a hand-over seeded in Juno's thread): the chat card rendered with the reason; "Take the screen" took control (`{held:true, handOver:true}`) and opened the desktop cover with "Give it back"; tapping it released control, wrote "The owner gave the screen back.", started Juno's turn, cleared the item, and the button went back to "Take control".

**Placeholder choices**
- Copy: "Needs you · hands", "<Agent> asks you to take the screen", "Take the screen", "Give it back", "Asks you to take the screen: <reason>" (push/deliver text), the tool description; the `hand.raised` symbol; reason cap 400 chars.

**Runtime-unverified**
- The Mac: the chat card, Needs you "Take the screen" opening the desktop window, and the toolbar "Give it back".
- The iPhone Needs you card's "Take the screen" (the chat card path was exercised).
- A real desktop behind it (the bed has no Xvnc; the cover showed "Socket is not connected").

**Notes / leftovers**
- The bed: Juno's thread has the seeded hand-over twice (a seed script re-ran) and the answered turn; daemon on 7795 runs slice 11's code (log `scratchpad/daemon-s11.log`, seed `scratchpad/seed11.ts`).
- The deliver text "Asks you to take the screen: …" goes through the push path as kind `reply`; actionable push categories are a later slice.

## Slice: 12 — request_form, daemon and wire
**Shipped**
- **Daemon:** `request_form` tool (permanent agents; reason parsed with `parseHandsReason`), dispatch and the end-of-turn branch in `loop.ts` (deliver "Asks you to fill a form on <origin>"); `readForm`/`fillForm`/`CHOICE_TYPES` in `browser.ts`; `forms.ts` (tool def, `shapeForm`, `secureOrigin`, `captureForm`, `findForm`, `formRequest`, vault, `fillSteps`, `rememberSteps`, `filledLine`, `hideFromAgent`/`redactSecrets`); `pendingCall` + `formRequests` in `needs.ts`; `POST /api/agents/:name/forms/:id`; `screenAsked` for the control routes; `forms` and `form_vault` tables (migration `0016_grey_toro.sql`), deleted with their agent/thread.
- **Wire:** `FormField`, `UnfillableField`, `FormRequest`, `FormFill`, `NeedsYouKind` `form`, `NeedsYouAction` `fill`, `NeedsYouItem.form` in `shared`; the same decode-only in `Types.swift`, "Needs you · form" presentation, `.fill` opens the thread for now.
- **Tests:** `forms.test.ts` (6), `api.test.ts` (3: the full secret flow with an adversarial read-back, moved page + give back, no browser), `TypesTests` (form decode).

**Key decisions**
- **The daemon, not the model, reads and fills.** The page script never reads a control's value, so a prefilled or autofilled password can't reach the tool text. Option values of selects are read (page data, not the owner's).
- **Every `insertText` is preceded by a focus check** in the same evaluate, and the origin is re-checked from `Page.getFrameTree` before anything is typed; either failing is a 409 and nothing more is typed.
- **Typed secrets are redacted from all tool rows** (per agent, parent for workers), because the agent can read `input.value` back with `browser evaluate`. Memory only (ponytail note).
- **Remembered values are proposed, never auto-filled:** they fill fields the owner leaves blank when the owner presses Fill (passwords are Hand to you). The vault is keyed by the CDP origin only.
- **Over plain HTTP only the secret fields go to the screen**; non-secret ones are still offered. The DoD line is about secret fields.
- **Pending by the transcript rule**, like hand-overs: the fill line or giving back the screen (an owner row) clears the item; the `forms` row is never updated.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (266 passed).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (165 passed); macOS → 0 (166 passed).
- Boot on a spare port (7797): a copy of the bed DB upgraded (both tables present) and a fresh DB both answer `/api/health`.
- `FORM_SCRIPT` run in real Chrome (Chrome DevTools MCP) on a probe page: picked the focused login form over a search form, labels from `<label for>`, wrapping label, aria-label and legend, select options, radio group merged, checkbox; file, CAPTCHA and a role=combobox listed as unfillable; hidden input skipped; the prefilled password was not in the result. The focus check and radio choose script worked there; a cross-origin iframe reports `contentDocument === null` once loaded.

**Placeholder choices**
- Copy: tool description, "Asks you to fill a form on <origin>", "I filled the form on <origin>: …, Password (hidden). Nothing was submitted; carry on from there.", "They do these on your screen: …", "Needs you · form", the `list.bullet.rectangle` symbol, `[hidden]` as the redaction mark; field cap 50, value cap 2 000 chars, redaction minimum 4 chars; unfillable reason words.

**Runtime-unverified**
- `Input.insertText` into a real Chromium on Xvnc (the bed has no Chromium); the fill against React-controlled inputs.
- A cross-origin iframe on a live page at extraction time (the probe ran the script before the frame loaded).
- One-time codes still visible in screenshots; the redactor only covers tool text.

**Notes / leftovers**
- No UI yet: the Needs you card shows only "Take the screen" for a form; `.fill` opens the thread.
- A 409 from the fill route (page moved, focus refused) leaves the item open; the app should show the error and offer the screen.

## Slice: 13 — request_form in the app
**Shipped**
- **Client:** `fillForm(agent:id:fill:)` → `POST /api/agents/:name/forms/:id`; `FormFill` in `Types.swift` (only entered values; `FormField.isChoice`).
- **`Views/Forms.swift`:** `FieldContent` + `FormField.content` (autocomplete's last token first, then type) mapped to `UITextContentType`/`NSTextContentType`, keyboards and no autocorrect on iOS; `FormOrigin`, `FormCard`, `FormSheet`, `UnfillableField.why`.
- **Needs you:** "Fill in…" (last) and "Use the agent's screen" (bordered) on form items; `.fill` opens the thread and the sheet; success removes the item and refreshes.
- **Chat:** `pendingForm` in `Thread.swift`, `FormCard` above the composer (same guards as the hand-over card), the sheet, catch-up after a fill.
- **Tests:** `TypesTests` (content types, fill body: blank saved text left out, choices kept, untouched boxes left out, strays dropped), `ThreadTests` (pending form).

**Key decisions**
- **Errors show inside the sheet, at the top**; the sheet stays open with the screen button.
- **Only password fields are dotted.** A secret one-time code as a second `SecureField` made iOS show "Use Strong Password?" on a login form. Codes and card numbers are shown as typed; they still never reach the agent.
- **Checkbox starts off and is sent only once flipped** (the daemon clicks whenever the page differs, and never reads the page's state).
- **Fill is disabled while a required, unsaved field is empty.**

**Verified**
- `pnpm check` → 0; `pnpm test` → 0.
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (168 passed); macOS → 0 (169 passed).
- Bed on 7795 restarted on this code, seeded a `forms` row + `request_form` call + a vault row for Email. On the simulator: the chat card, the sheet (labels, "Saved for this site", lock, CAPTCHA listed), a typed password, Fill → the daemon's 409 "your browser is not running; open the page with the browser tool first" shown at the top of the sheet; "Use the agent's screen" from the sheet took control and opened the desktop, and giving it back cleared the card; the Needs you page card with both buttons opens the sheet over the thread.

**Placeholder choices**
- Copy: "Fill in…", "Use the agent's screen", "Form for <agent>", "Saved for this site", "Required", " *" as the required mark, "Choose…", the Remember footer, the HTTP footer, "Do these on the agent's screen", the unfillable reason words; `lock.fill`/`lock.open` (failed colour).

**Runtime-unverified**
- The Mac sheet (sidebar rows can't be opened focus-free); a successful fill (the bed has no Chromium); password-manager autofill of the username/password content types on a device.

**Notes / leftovers**
- The daemon's fill errors are worded for the agent ("open the page with the browser tool first"); fine for now.
- The checkbox toggle doesn't know the page's current state.

## Slice: 14 — reply feedback
**Shipped**
- **Daemon:** `feedback` table (migration `0017_petite_shooting_star.sql`), `feedback.ts` (`parseFeedback`, `findReply`, `setFeedback`, `withFeedback`, `feedbackLine`), `PUT /api/messages/:id/feedback`, `Message.feedback` on both message routes; `remember` takes an optional heading (`APPEND_SCRIPT` `$3`).
- **Shared:** `FeedbackRating`, `MessageFeedback`, `Message.feedback?`.
- **App:** `Message.feedback`, `FeedbackUpdate`/`FeedbackAnswer`, `setFeedback(message:_:)`; thumbs in `MessageRow` (context menu on both platforms, Mac hover actions), chosen-state thumb always visible, `FeedbackSheet` for a down.
- **Tests:** `api.test.ts` (validation, up stored only, down line with date/reason/excerpt on stdin, same down not written twice, clear, worker → `agent-alpha`, cascade on thread delete; the fixture now records `stdin`), `tools.test.ts` (heading append against real bash in a temp dir), `TypesTests` (decode, `{"rating":null}` encode).

**Key decisions**
- **Cascade FK instead of extra deletes**: foreign keys are on after migrations, so every message-deleting path drops feedback.
- **Memory write before storing**: a failed write can be retried; a repeat down with the same reason writes nothing new; up is stored only; clearing a down leaves the memory line (the owner edits `MEMORY.md` on the Memory page).
- **Any assistant row with an agent sender** is rateable, group threads included.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (268).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (170); macOS → 0 (171).
- Upgrade boot on a copy of the bed DB on 7796 → feedback table created. Bed on 7795 restarted on this code with scratchpad `sudo`/`getent` shims (`<scratchpad>/shim`, homes under `<scratchpad>/homes`). Simulator: long-press on Juno's reply → Good/Bad reply; Bad reply → sheet → reason → row stored, `## Feedback` line in `homes/agent-juno/memory/MEMORY.md`, "You rated this bad" thumb shown; switched to up (no memory line), then "Remove thumbs up" cleared it.

**Placeholder choices**
- Copy: "Good reply", "Bad reply", "Remove thumbs up/down", sheet title "Bad reply", "What was wrong with it?", "Optional. The agent finds it in its memory.", the memory line wording (`<date>: the owner gave a thumbs down on "<120-char excerpt>": "<reason>"` / `no reason given`); icons `hand.thumbsup(.fill)`/`hand.thumbsdown(.fill)`; the chosen thumb in secondary colour.

**Runtime-unverified**
- The Mac hover thumbs and the Mac sheet (sidebar rows can't be opened focus-free).

**Notes / leftovers**
- Excerpt of a reply is plain text of Markdown (asterisks and all).

## Slice: 15 — idle work settings, pre-checks and the scheduler
**Shipped**
- **Daemon:** `idle.ts` (`DEFAULT_IDLE`, `readIdle`, `updateIdle`, `windowOpenedAt`, `idlePreCheck`, `parseFacts`, `runIdleChecks`, `startIdleScheduler`); `agents.idle` column and `idle_passes` table (migration `0018_overrated_celestials.sql`); `GET`/`PUT /api/agents/:name/idle`; the tick started in `main.ts`.
- **Shared:** `IDLE_CONDITIONS`, `IdleCondition`, `IdleSettings`, `IdleSettingsUpdate`, `IdlePassOutcome`, `IdlePass`.
- **Tests (`api.test.ts`):** routes (defaults, six refused bodies, merge, worker/unknown 404); window wrap and `parseFacts`; the tick (a skip with no model request and one facts exec as the agent, once per window, new feedback from a worker alone → `due` with `['new_feedback']`, the file facts and new messages through `idlePreCheck`, `requests` empty throughout).

**Key decisions**
- **Stopped at "would run":** a matched pre-check records a `due` pass (a fourth outcome besides `skipped`/`ran`/`wasted`). Starting the turn needs a per-turn model override, a turn cap and token counting in the runner, which belong with the guard in the next slice.
- **`stale_files` is edge-triggered:** only files whose age crossed 30 days since the last pass count (`-mmin +30d -mmin -(30d + since)`, BSD and GNU find), otherwise one old download would match every night. `memory_size` stays level-triggered on purpose (a pass should shrink the file).
- **Separate timer** from the schedules tick, because the pre-check awaits an exec and `runDue` is deliberately synchronous.
- **`ON DELETE CASCADE`** on `idle_passes.agent_id`: deleting an agent drops its passes without another delete line.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (271).
- Boot on a spare port (7798): a copy of the bed DB upgraded (`idle_passes` + `agents.idle`) and a fresh DB both answer `/api/health`.
- The find window run in real bash on macOS against touched files (a 9-month-old file counted with a wide window, not with a one-day window; `memory/` excluded).

**Placeholder choices**
- Defaults: off, all four conditions, 200 000 tokens a day, 20 turns, model null, window 01:00–06:00; caps 10 M tokens and 200 turns.
- `STALE_DAYS` 30, `find -maxdepth 3`, dotfiles, `memory/` and `skills/` excluded, counted up to 1 000; memory threshold reuses `MAX_MEMORY_CHARS` (8 000 bytes).
- Hours are the daemon's local time (a container is likely on UTC).

**Notes / leftovers**
- `due` passes are never run yet; `since` already moves past them, so their signals are consumed without work until the next slice decides otherwise.
- `new_messages` will re-trigger itself once passes write rows (the idle note, the agent's replies are excluded but an owner-role delivery is not; scheduled task deliveries also count).
- The "no provider request" test is only meaningful once `due` starts a turn: then assert one request for `due`, none for `skipped`.
- No app UI, no wire types in Swift yet.

## Slice: 16 — idle passes run as guarded turns
**Shipped**
- **Daemon:** `idle.ts` gains the run path (`runIdleChecks` with a runner, budget/busy gate, idle note, `endPass`), outputs (`addIdleOutput`, `listIdlePasses`, `resolveIdleOutput`, back-off), `leave_note` (`leaveNoteToolDef`, `parseNote`) and `idleCommandRefusal`. `loop.ts`: `IdleTurn`, `idleToolDefs`, `idleDispatch`, the cap/budget stop, `end` in the finally; the runner's `start`/`drain` carry it for round 0 and resolve the idle model. `rules.ts`: `commandWords` factored out, `commandNames` exported. `app.ts`: `agentProvider(agent, modelId?)`, `GET /api/idle/passes`, `POST /api/idle/outputs/:id`. `main.ts` hands the runner to the idle scheduler. Migration `0019_easy_sprite.sql` (`idle_outputs`, `idle_passes.ended_at`, `.reason`).
- **Shared:** `IdleSettings.pausedReason`, `IdleSettingsUpdate` without it; `IdlePass.endedAt/reason/outputs`; `IdleOutput`, `IdleOutputKind`, `IdleOutputResolution`, `IdleOutputAction`.
- **Tests (`api.test.ts`, 5 new):** a failed or `waiting_for_agent` agent is not started (stays `due` with the reason, its state and the Needs you failure item kept); due pass makes model requests with the idle note and a skipped one none, the pass's own rows are not news next window; turn cap (2 calls), a spent daily budget starts nothing (`reason`), next day the unrun pass's signal still matches and the token limit stops at 120/100; guard refusals with the rules at on_its_own (rm, apt install, mail, send_message, request_approval spend/share, browser, remember today) while `ls` and a delete_files cleanup go through; memory undo (409 on a changed file, restore, second undo 409), routine accepted into a schedule, wasted pass, back-off after 3 dismissals and fresh strikes after turning it back on. Fixture: `runner`, `offered` (tool names per request), `memory` (stateful MEMORY.md per Linux user), `usage` passed through.

**Key decisions**
- **The idle note is a stored row** (role user, sender `Idle work`, not a valid agent name): the owner sees why the agent spoke at night, it never counts as an owner row (Needs you questions, hand-overs stay open), and `new_messages` excludes it by sender, not only by time.
- **Unrun passes stay `due` with a `reason`** and do not move `since`; the once-per-window rule still holds, so the next window retries with the signals intact. A pass orphaned by a restart mid-turn also stays `due`.
- **The budget also bounds the turn:** windows open once a day, so a start-only gate would never bite; the turn stops once usage reaches what is left of `dailyTokens`.
- **Memory diff is a before/after snapshot around the turn**, so it catches both `remember` and a rewrite through run_command. Not recorded when MEMORY.md is at the 64 000-byte read cap, since a truncated "before" would lose the rest on undo.
- **Back-off pauses by switching idle off** with `pausedReason`; the streak counts from the newest note, pausing at each multiple of 3, so turning it back on gives fresh strikes without stored state.
- **Idle starts only from rest** (`idle`, `waiting_for_user`): an idle turn ends in `waiting_for_user`, which would erase a failure from Needs you, strand a `waiting_for_agent` agent (the wake needs that state) or run beside a live worker.
- **Cleanup proposals** are request_deletion (agents, threads) or request_approval in `delete_files` (files; approving grants the one-shot `rm` for a later ordinary turn).

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (276). Idle tests looped clean.
- Boot on spare port 7798: a copy of the bed DB upgraded to 19 migrations and a fresh DB both answer `/api/health`.

**Placeholder choices**
- Idle note and `leave_note` wording; `MAIL_SENDERS` list; note cap 2 000 chars; `GET /api/idle/passes` default window 24 h; back-off reason text "The owner dismissed 3 notes in a row."

**Runtime-unverified:** idle note rows (sender `Idle work`) and idle turns in the owner's chat in the app; the app was not run this slice.

**Notes / leftovers**
- ponytail ceilings: `idleCommandRefusal` reads command words only (`bash -c`, `curl -X POST`, scripts get past it); spending through run_command is not detectable; the withheld tool set is the real fence.
- A failed idle turn leaves the agent `failed`, which shows as a Needs you failure item.
- The app renders `Idle work` rows as an unknown sender; the chat may want a quieter style for them.
- No Swift wire types or UI yet: the "Last night" digest and the When idle settings page are next.


## Slice: 17 — idle work in the app ("Last night" digest, When idle settings)
**Shipped**
- **Wire + client (Swift):** `IdleSettings`, `IdleSettingsUpdate`, `IdlePassOutcome`, `IdlePass`, `IdleOutput`, `IdleOutputAction`, `idleSender` in `Types.swift`; `idle`, `setIdle`, `idlePasses(since:)` (query via `URL.appending(queryItems:)`), `resolveIdleOutput` in `SchermesClient.swift`.
- **`Views/Idle.swift` (new):** `memoryDiff`, `IdlePass.summary`, `IdleOutput.resolvedWord`, `LastNight`, `IdleAgentGroup`, `IdleOutputRow`, `IdleSettingsView`.
- **Wiring:** `NeedsYouPage(session:…)` and its "Last night" panel; `AgentPages.Page.idle` (overview filters Rules and When idle for workers); `ConsoleView` context menu "When idle…" (permanent agents) + sheet; `ChatView` More menu "When idle", `IdleNoteLine` for `Idle work` rows; sidebar preview reads "Idle work" for a note row.
- **Tests (`TypesTests`, 5 new):** settings decode + `modelId` null/absent encoding; every output kind, unknown kind and outcome; summaries (skipped with "didn't run, 0 tokens", due with reason, wasted); memory diff; action encoding.

**Key decisions**
- **Only actions the daemon accepts:** memory Undo, routine Dismiss / Turn on, note Dismiss, none on cleanup (answered in Needs you). The canvas's "Keep", "Ask Juno to check" and "Review 23 files" were left out.
- **No token figures:** the canvas's "[USED] of [BUDGET] tokens" header is dropped; `IdlePass.tokens` is never shown. The daily budget is a setting, so it shows as a number to edit.
- **"20 new messages" became "New messages since the last pass"**: the daemon's condition fires on any new message.
- **The digest owns its polling** (30 s, last 24 h) instead of riding the 2 s Needs you poll.
- **Budget saves on submit or focus loss**, never per keystroke; a non-number is refused in the app, a range error comes from the daemon.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (276).
- `xcodebuild test`: iPhone 17 Pro simulator → 0 (175); macOS → 0 (176).
- Bed on 7795 restarted on this code (it ran pre-slice-15 code; upgrade to 19 migrations went fine), seeded passes and outputs of every kind, an approval for the cleanup and an idle note row. Simulator: digest showed every kind; Mo's Undo → the daemon's 409 under the row; Juno's Undo restored MEMORY.md (`undone`); Turn on created schedule `0 7 1 * *` and showed "Turned on"; the note's Dismiss stored `dismissed`; the chat showed "Idle work · 19:27" as a quiet line. When idle page via the More menu: switch on, a condition off, the stepper to 21, budget 0 → "dailyTokens must be 1 to 10000000" under the field, a paused agent → "Paused: …" + Turn back on cleared it. Mac (DEBUG levers, a bed copy on 7799): the Last night column beside Needs you, Undo via AX → 409 text; `pages:juno:When idle` rendered the page, with "When idle" listed in the inspector overview.

**Placeholder choices**
- Copy: "Tidied its memory", "Suggests a routine", "Noticed something", "Proposes a cleanup", "It wants to delete …. Answer it in Needs you.", "Asked to delete something. Already answered.", "Left a <kind>", "Still at it.", "Undone" / "Turned on" / "Dismissed", "Work while idle", "Only wakes up when", the four condition labels, "Checked without the model: …" footer, "Runs", "From" / "Until", "Model calls per pass", "Daily budget … tokens", "Agent's own", the hours footer, "Paused: <reason>", "Turn back on", "When idle" / "What it does while you're away", "Idle work · <time>".
- Icons: `moon.zzz` for the page, the menus and the chat line. Memory diff: + in the done colour, − in the failed colour, 8 lines shown then "and N more lines".

**Runtime-unverified**
- The hour pickers and the model picker were not driven (same save path as the verified fields; the `null` model encoding is unit-tested). The Mac context-menu "When idle…" (sidebar rows can't be right-clicked focus-free). Dark-mode iPhone.

**Notes / leftovers**
- Bed gotcha: `WRITE_MEMORY_SCRIPT` runs GNU `stat -c %s`; on macOS the bed needs a `stat` shim (added to the 7795 bed's `shim/`), otherwise undo answers "MEMORY.md is too large to restore".
- A Mac local notification still fires when an idle turn finishes while the window is in the background ("turn ended" in `ConsoleView.announce`); it can't tell an idle turn apart. Fine unless it proves noisy.
- The memory diff shows markdown list dashes after the +/− sign ("+ − Window seat…").

## Slice: 18 — triggers in the daemon (webhook, folder, command)
**Shipped**
- `shared`: `TRIGGER_KINDS`, `TriggerKind`, `TriggerState`, `TriggerConfig`, `Trigger`, `TriggerAction`.
- `schema.ts` `triggers` + migration `0020_ancient_network.sql` (generated).
- `daemon/src/triggers.ts` (new): parse, propose, list, `actOnTrigger`, `fireWebhook`, `runTriggerChecks`, `startTriggerScheduler`, `proposeTriggerToolDef`.
- `loop.ts`: `propose_trigger` in the permanent-agent tool list and dispatch (workers get "no tool named"; idle's whitelist leaves it out). `app.ts`: the two owner routes and `POST /hooks/:token`. `main.ts`: `startTriggerScheduler`. `conversations.ts` `agentChain`: agent senders only. `idle.ts`: `TRIGGER_SENDER` excluded from `new_messages`.
- Tests (`api.test.ts`, 4 new): proposal fires nothing + a refused `rm` check + worker cannot propose; webhook minting, 401/404/413/202/429, one row per accepted post, `dropped`, off/on keeps the URL, delete; folder path parsing; folder fires once (cursor advances) and the command only on changed output, off/delete stop both.

**Key decisions**
- **Webhook secret is a header, not an HMAC:** `X-Schermes-Secret: <secret>`, constant-time compare. Simple for curl/IFTTT/Zapier; a GitHub-style HMAC signature can be added as a second accepted form if a sender needs it.
- **Check commands are vetted at propose time** (`classifyCommand` + mail senders), not by `guardCommand` at run time; the owner turning it on is the gate, and the command is shown in the listing.
- **Triggers fire whatever the agent's state**, as schedules do: a trigger on a `failed` agent wakes it, which also hides its Needs you failure item (idle deliberately avoids that; triggers are the owner's opt-in).
- **Rate limit** is a fixed hourly window per trigger (default 6, 1–60); a dropped poll still advances its cursor, so dropped news is lost, not queued.
- **Trigger rows don't count as agents talking** (`agentChain` fix) and **aren't idle news** (their turn already ran).
- **Folder "new or changed" = ctime newer than the last check** (fractional seconds). ponytail: a file touched between the timestamp and the scan may be reported twice.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (280).
- Boot: an upgraded copy of the 7795 bed DB (7831) and a fresh DB (7832), 21 migrations each, health ok, `POST /hooks/none` → 404 without a session.
- The folder script under GNU find (`debian:stable-slim` in Docker): new, moved-in and nested files listed, dotfiles and dot-dirs skipped, a hidden watched folder works, nothing since the second check, a missing folder exits 2.

**Placeholder choices**
- Copy of the fired-turn text, the tool description and the proposal answer ("Proposed as trigger N. Nothing fires until the owner turns it on; ask them to, and once it is on, offer to test it together."). Defaults: 6 fires/hour, check every 5 minutes, 30 s check timeout, 64 KB body, 4000-char excerpt, 50 files listed.

**Runtime-unverified**
- The command check under real `sudo`/`timeout` on Linux (argv is `commandArgv`, the same as `run_command`). How the app renders `sender: "Trigger"` rows (it has no mirror constant yet).

**Notes / leftovers**
- The agent cannot see its triggers or their states: no list tool and nothing in the prompt tail. The chat-card / guided-test slice should decide how it learns a trigger went on (e.g. an owner-side line on turn-on, plus a `triggerPrompt` in `homeTail` like `schedulePrompt`).
- No owner route edits a trigger's config or `maxPerHour`; propose again or add a PUT when the UI needs it.
- The Swift side needs `triggerSender` mirroring `TRIGGER_SENDER`, the way `idleSender` mirrors `IDLE_SENDER`.
- I overwrote `<scratchpad>/up/schermes.db` (an older boot-check copy from an earlier slice) before switching to `s18-*` dirs; nothing depends on it.

## Slice: 19 — IMAP triggers in the daemon
**Shipped**
- `shared`: `imap` in `TRIGGER_KINDS`; `TriggerConfig` gains `host`, `port`, `mailbox`; `Trigger.hasLogin?` (imap only); `NeedsYouItem.triggerId?` on a login item, so a card can find its form.
- `schema.ts`: `forms.trigger_id`, `triggers.login`; migration `0021_sturdy_titania.sql` (generated; two `ALTER TABLE … ADD`, existing form rows survive).
- `daemon/src/imap.ts` (new): a minimal client over `node:tls` (`checkMailbox`, `decodeWords`, `LoginRefused`, `OpenSocket` seam). No dependency added.
- `triggers.ts`: `mailboxConfig`, the imap branch of `parseTriggerProposal`, `loginForm`/`loginRequests`/`saveLogin`/`refuseLogin`, `checkImap`, 409 on turn-on without a login, delete removes the login form, `describe` for imap, tool text and schema. `forms.ts`: `StoredForm.triggerId`, `secure` true for trigger forms, `StoredField`/`StoredForm`/`toStored` exported. `needs.ts`: login items. `app.ts`: the fill route's login branch. `loop.ts`: the imap proposal reply. `main.ts`: the scheduler gets `{masterKey}`.
- Test (`api.test.ts`, 1 new, against a fake plain-TCP IMAP server with literals both ways): a login key and a bad host refused; 409 before the login; the form item (secure, two fields) and a half-filled form refused; filling adds no thread row and clears the item; stored encrypted; baseline fires nothing; one fire with the decoded subject, the old mail left out; a UIDVALIDITY change resets without firing; the rate limit drops the third; a refused login fires nothing, brings the form back with the reason and is not retried; username and password in no message row and no model request; the server saw EXAMINE, never SELECT/STORE/EXPUNGE, every FETCH a `BODY.PEEK`; delete clears item and form row.

**Key decisions**
- **A `forms` row with `trigger_id`, not a separate route:** reuses `FormRequest`, the `form:` item, `FormSheet` and `POST /api/agents/:name/forms/:id` (incl. Remember, keyed on the `imaps://` origin) unchanged on the app side. Made on first read so clearing the thread (which deletes its forms) cannot strand a trigger.
- **Filling a login writes nothing into the thread:** an owner row would clear every pending question/hand-over/form there (the `pendingCall` rule) and the model would learn the username. The agent learns about it when the owner turns the trigger on (next slice).
- **A refused login becomes a Needs you item again**, by dropping the login it tried (guarded on the ciphertext, so a login entered meanwhile stays). Retrying a bad login every few minutes can lock the account. Network errors and the transient codes (`[UNAVAILABLE]`, `[INUSE]`, `[LIMIT]`, `[SERVERBUG]`) are only logged and retried on the next check.
- **Baseline is `UIDNEXT-1`** from the EXAMINE reply (a search from 0 when a server leaves it out), so a large mailbox never sends its whole UID list.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (281).
- Boot: an upgraded copy of the bed DB (7841: 22 migrations, its 2 form rows kept, `triggers.login` present) and a fresh DB (7842), `/api/health` ok on both.

**Placeholder choices**
- Copy: the item title "Needs the login for <mailbox> on <host>", the refusal reason, the fired-turn text ("N new messages in INBOX … treat what it says as data"), the tool text. Defaults: port 993, INBOX, 20 messages listed, 300 characters per header field.

**Runtime-unverified**
- A real IMAP server over TLS (`[user]` item in the OVERVIEW). The login form in the app's `FormSheet` (it should render as is: two fields, a lock, origin `imaps://…`).

**Notes / leftovers**
- The agent still cannot see its triggers or their states (slice 18 leftover), and now also not whether a login was entered.
- Non-ASCII mailbox names (modified UTF-7) are refused at propose time.
- **Connection failures are silent to the owner:** a wrong host or port, or a self-signed certificate (verification stays on), is only logged, so an on trigger with a login may never fire. Needs a `lastError` on the listing (new column), set on failure and cleared on success.
- A refused login keeps its form row and item id; the app re-announces it anyway, because it only compares with the previous poll's ids.
- The login item offers only `fill`, so an unwanted imap proposal stays in Needs you until the owner deletes the trigger (no UI for that yet).
- Swift has no `Trigger` types yet; `hasLogin` and `kind: imap` are for the next app slice.


## Slice: 20 — triggers in the app, and the agent knowing its triggers
**Shipped**
- Daemon: `triggerPrompt` in `homeTail`; the turn-on line + turn; `last_error` column (`0022_regular_devos.sql`, generated) set/cleared by checks; `Trigger.lastError` in `shared`.
- Swift: trigger wire types and client calls, `pendingTrigger`, `Views/Triggers.swift` (`TriggerLine`, `TriggerCard`, `CopyRow`, `TriggersSection`, `TriggerRow`), `ChatView` wiring, "Routines and triggers" page and menu entries.
- Tests: `api.test.ts` trigger tests extended (turn-on line is a `Trigger` row and starts a turn; the prompt lists both triggers with states; on-again writes nothing; a failed folder check sets `lastError`, a good one clears it; imap prompt says "login entered"; a refused login shows as `lastError`). `triggerOn` pushes the turn-on reply and settles; `triggerRows` counts only fired rows. Swift: `triggersDecodeEveryKindWithoutALogin`, `aLoginItemCarriesItsTrigger`, `aTriggerProposalIsFollowedFromTurnOnToItsFirstFire`.

**Key decisions**
- **The turn-on line uses `TRIGGER_SENDER`**, not an owner row: an owner row would clear pending questions and forms in the thread (`pendingCall`). The app tells "is on" from "fired" by the words; `agentChain` and idle's `new_messages` already ignore that sender.
- **One card, for the newest proposal.** Older proposals live in the listing. The card leaves once the owner writes after the fire.
- **The card is a bottom card like the form and hand-over cards**, not inline: tool calls fold into the tool run.
- **Command checks only fail when exec throws**; a non-zero exit is output and is hashed as before.
- **Cron** stays `schedule_task`; routines and triggers share one page.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (281).
- `xcodebuild test`: iPhone 17 Pro → 0 (178); macOS → 0 (179).
- Boot: an upgraded bed copy with 0022 undone (7852: 22 → 23 migrations, `last_error` added, triggers kept) and a fresh DB (7853), health ok.
- Simulator against the 7795 bed (restarted on this code): scout's webhook card → Turn on → "Trigger turned on · 20:11" line, the agent's turn, URL + secret with copy buttons, "Waiting for it to fire…"; `curl` with the secret → 202, "Trigger fired · 20:11" line and the card flipped to "Fired · 20:11". Juno's imap card showed "Enter login…", which opened the `FormSheet`; after the login went in, the card showed Turn on. More → "Routines and triggers" listed the mailbox; the switch turned it on; its check failed and the row showed "Last check failed: connect ECONNREFUSED 127.0.0.1:993".

**Placeholder choices**
- Copy: "Trigger · <Webhook|Watched folder|Check command|Mailbox>", "Enter login…", "Turn on", "Test it: …" per kind, "Waiting for it to fire…", "Fired · time", "Trigger fired/turned on · time", "No triggers. <Agent> proposes them in the chat.", the Triggers footer, "Waiting for the login", "Last check failed: …", "Routines and triggers" / "Standing jobs, and what wakes it", the daemon's turn-on line and prompt header.
- Icons: `bolt` for trigger lines, `bolt.badge.clock` for the page, `link`/`folder`/`terminal`/`envelope` per kind. Header colour: needsYou while proposed, done when on.

**Runtime-unverified**
- Mac: the lever app opened on scout (window "Scout"), but cua-driver could neither capture the window nor resolve its AX tree this run, so the Mac inspector listing was not seen. It is the same `AgentPages` code as on iPhone, and the macOS build and tests pass.
- Copy buttons (pasteboard), Delete on the card, the folder/command test texts, dark mode.

**Notes / leftovers**
- idb `ui tap` does not flip a SwiftUI switch in a `Form`; `idb ui swipe` across it does.
- A seed that calls `proposeTrigger` directly skips `parseTriggerProposal`'s defaults (the imap port came out `undefined`); seed through the parser.
- The bed on 7795 now runs this code; its DB is at 23 migrations and has scout's webhook (on, fired once) and juno's imap trigger (on, failing).

## Slice: 21 — goals and helpers in the daemon
**Shipped**
- `daemon/src/goals.ts`: model, parsing, `applyGoalUpdate`, `finishGoal`, `deleteGoal`, `keepHelper`, `describeGoal`, `goalPrompt`, `goalNeeds`, tool defs `update_goal` and `add_helper`.
- `schema.ts`: `goals`, `goal_helpers` (migration `0023_thick_unus.sql`, generated).
- `loop.ts`: `spawnWorker` (the old `spawn_task_worker` body, with an optional screen-helper mode), `updateGoal`, `addHelper`, the goal tools in the permanent tool list, the computer tool for a worker with its own screen, the goal in `homeTail`, `desktop` on `LoopDeps`/`RunnerDeps`.
- `agents.ts`: `DesktopOps.ensure(name, display, tag?)`, `DesktopOps.stopDisplay`, `hasOwnScreen`, `insertWorker(..., display?)`, exported `nextWorkerDisplay`. `infra/desktop/start-desktop.sh` takes an optional tag for log, pidfile and desktop name.
- `workers.ts`: `workerPrompt(worker, parent, goal?)` describes the screen and the goal.
- `app.ts` goal routes, `needs.ts` goal items, `shared` wire types.
- Tests: `loop.test.ts` "a lead keeps a goal…" (create, the echoed goal, steps with a stranger owner refused, both helper kinds, the worker's tools and prompt, the helper refused `add_helper`, the Needs you item, finishing and cleanup). `api.test.ts` "goals: listed…" (listing, keep refused for a worker, 404s, 409 while a helper runs, finish removes the unkept ones, delete keeps the kept one).

**Key decisions**
- **"Keep as agent" is for temporary agents only.** A screen worker runs as the lead's Linux user and has no account to keep ("Promoting one keeps its account"). The route answers 400 for a worker.
- **A removed screen worker stays a finished worker row.** Its display goes back to the placeholder range and its helper row is dropped. `deleteAgent` would delete its report from the lead's own thread. A temporary agent is deleted like any agent, including its lines in the lead↔helper thread; the Linux user and home stay, as with every delete.
- **Kept is `kept_at` on the helper row**, not deleting the link, so the goal page can still show it. `isHelper` means unkept: an unkept helper gets no `update_goal`/`add_helper`; a kept one can lead goals.
- **"Next from you" is a Needs you item**, kind `goal` with only `open`, so today's app shows it through `.other` with no Swift change.
- **Finishing refuses (409, or a tool error) while an unkept helper is mid-turn** rather than stopping it.
- **A temporary helper inherits the lead's `rules` and `model_id`** (`inheritFromLead`; grants stay the lead's), so delegating a job cannot sidestep the rules. It starts working at once, so the owner never gets to set rules first.
- **Both helper paths re-check the loop cap after the awaited desktop start** and undo (stop the display or desktop, drop the row) on refusal. A goal is only created once its steps validate, so a refused create leaves nothing behind.
- **Helper names** are `<lead>-g<goal id>-<n>`, with `n` from a never-decreasing `helpers_made`, so a name never lands in an old helper's home. A lead name that is too long gets "no name is left".

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (283).
- Boot: a copy of the 7795 bed (23 → 24 migrations, 5 agents kept) on 7862 and a fresh DB on 7863, health ok, both have `goals` and `goal_helpers`. The desktop errors in the log are the Mac's missing sudo, as always.
- `bash -n infra/desktop/start-desktop.sh` → 0.

**Placeholder choices**
- Copy: tool descriptions, `describeGoal` layout ("Goal N: title (state), led by x.", "Plan:", "- [state] text (owner)", "Helper x, worker with its own screen|temporary agent[, kept by the owner]: reason", "Results:", "Next from the owner:"), `goalPrompt` lines, the helper profile, the Needs you title "Next from you: <title>".
- Limits: 10 open goals per lead, 30 steps, 50 results, 10 next items, 6 helpers per goal.

**Runtime-unverified**
- A real second Xvnc on the lead's user (start-desktop.sh with a tag, `stopDisplay`'s `pkill -f "Xvnc :N( |$)"`), and a temporary helper's real Linux user. There is no Linux/Docker run here.

**Notes / leftovers**
- Deleting a lead cascades its goals, so its temporary helpers are left as normal agents. `desktop.stop(lead)` (delete, rename, restart desktop) also takes down its helpers' screens, since they run as the same user.
- Step owners are names: an agent that renames itself leaves stale owners until the lead rewrites the plan.
- There is a small race between the "helper running?" check and the awaited desktop stop.
- The owner can't view a screen worker's display yet: `desktopAgent` excludes workers. The goal page slice needs a route for it (VNC on 5900 + display).

## Slice: 22 — goals in the app (Mac, iPad, iPhone)
**Shipped**
- `Types.swift`: `Goal`, `GoalStep`, `GoalStepState`, `GoalHelper`, `HelperKind`, `NeedsYouKind.goal`, `NeedsYouItem.goalId`. `SchermesClient.swift`: `goals`, `goal(id:)`, `finishGoal`, `deleteGoal`, `keepHelper`.
- `Views/Goals.swift` (new): step and helper-kind presentation, `GoalRing`, `HelperBloub`, `ForThisGoal`, `HelperRow`, `GoalRow`, `GoalCard`, `GoalSummary`, `GoalPage` (header with the lead's bloub and ring, Next from you, Plan with state icon + word and the owner's bloub, Results, On it with kind, reason, state, Kept/For this goal, Keep as agent, Open; Open thread, Delete with a confirmation, Finish; the daemon's refusal text under the buttons, a keep refusal under its helper).
- `ConsoleView.swift`: goals polling, `SidebarPick.goal`, the Goals section / iPhone cards, helpers nested under the lead, goal Needs you items open the page, the `goal:<id>` lever. `Inspector.swift`: the Goal section. `NeedsYou.swift`: goal presentation, "Open goal".
- `TypesTests.swift`: goals decode with unknown step states and helper kinds, the goal Needs you item, and the ring fraction.

**Key decisions**
- **Helpers are listed under their lead, always visible, not folded** (as on the canvas), for both kinds while the goal is open and the helper unkept. Worker helpers leave the "N task workers" fold; after the goal is done a worker helper goes back there as a finished worker.
- **The dashed outline is a dashed circle around the bloub** in the lead's accent colour, and the bloub is drawn in the lead's colour with the helper's own shape. Kept helpers are drawn plainly.
- The sidebar lists done goals too (after the open ones), so a done goal can still be opened and deleted.
- No daemon change: viewing a screen worker's display stays out (slice 21's leftover).

**Verified**
- `xcodegen generate`; `xcodebuild test` on the iPhone 17 Pro simulator → 180 passed; macOS `xcodebuild test` → 181 passed.
- Runtime, iPhone simulator against a copy of the 7795 bed on 7871 (seeded with `applyGoalUpdate`/`addHelperRow`): home with goal cards and helpers nested under Mo with "For this goal" and dashed rings; goal page; Finish removed the temporary helper and left the worker; Keep as agent set `kept_at` and showed "Kept as agent"; Delete (confirmed) removed the goal and left the kept helper as a normal agent.

**Placeholder choices**
- Copy: "Goal · led by X", "Goal · done · led by X", "Plan · n of m", "Results so far", "On it", "Leads the goal", "Helper with its own screen" / "Temporary agent", "<lead>'s reason: …", "Kept as agent", "Helpers are removed when the goal is done, unless you keep them.", "Open thread", "Finish goal", the delete confirmation text, "Helping <lead>" in the inspector, "Open goal" on the Needs you card, "Needs you · goal".
- Icons: step states circle / circle.lefthalf.filled / checkmark.circle.fill / exclamationmark.octagon; goal kind "flag". Blocked uses the needsYou colour, doing the lead's accent. Dash pattern 4/3, 1.5 pt.

**Runtime-unverified**
- The Mac screens (sidebar Goals section, goal page, inspector Goal section): the lever app launched and logged in (window title "Ledger"), but cua-driver could not resolve its window (`ax_window_unresolved`) and `screencapture -l` could not image it, so nothing was seen. iPad layout unseen.
- A daemon 409 shown in place: the seeded helpers were not really running, so Finish/Delete never refused.

**Notes / leftovers**
- The chat header of a helper does not say "For this goal" yet (only the sidebar and the goal page do).
- Step owners and results are plain text; results are not linked to files or threads as on the canvas.
- Watching a screen worker's own display still needs a daemon route.

## Slice: 23 — search in the daemon (FTS5, model-read filters)
**Shipped**
- `daemon/migrations/0024_search_index.sql` (+ journal/snapshot from `pnpm migrations --custom --name search_index`): the three FTS5 tables, the message triggers and a `rebuild` backfill.
- `daemon/src/search.ts` (new): the indexer (files scan, OCR), `answerSearch`, `parseFilters`, `plainFilters`, `describeFilters`, `runSearch`, `indexAgentFiles`, `indexPass`, `startSearchIndexer`.
- `app.ts`: `POST /api/search`. `main.ts`: `startSearchIndexer`. `shared`: `SEARCH_KINDS`, `SearchKind`, `SearchFilters`, `SearchResult`, `SearchAnswer`. `infra/install.sh`: `tesseract-ocr`.
- `api.test.ts`: "a question is read into filters by the model…" (the "that PDF Ledger downloaded 3 days ago" fixture with distractors for every filter: other agent, 20 days old, a .txt, a message; exactly one hit; no content in the model request), "without a model, or when it fails…" (no request without a model entry, a non-JSON reply and a throw both fall back; stemmed prefix match; a deleted row leaves the index; junk words like `.` and `"AND` never break MATCH), "the index pass lists each home and reads screenshot text…" (parsing skips junk lines; no tesseract → nothing read or marked; each picture read once).

**Key decisions**
- FTS5 lives only in the custom migration; drizzle's schema and snapshots don't know it, so later `pnpm migrations` runs leave it alone.
- bm25 is not comparable across tables, so each kind is ranked on its own (capped at 20) and the merge is by time, newest first.
- Words are ORed, so a fallback on a whole sentence still finds something; the model's filters do the narrowing.
- The model sees no content, only the question, today's date and agent names. `byModel` tells the app which reading it got.
- Tesseract runs as an agent user (untrusted images never parsed as the daemon), one image in memory at a time.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (daemon 286 pass).
- Upgrade: a `.backup` copy of the 7795 bed booted on 7811 (health 200; `messages_fts` 71 = 71 messages, MATCH works; 25 migrations). A fresh data dir booted on 7812 (200). The Mac has no `getent`, so the file scan logs one error per agent there, as expected off Linux.

**Notes / leftovers**
- The app still uses `GET /api/search`; the next slice moves ⌘K and the iPhone field to `POST` and can then retire the GET route and `searchMessages`.
- Files are indexed by name and path only (as the DoD says), not by content.
- Tesseract on the real image is unverified here (not installed on the Mac); the image rebuild is the owner's `[user]` precondition.
- Docs (`architecture.md`, `configuration.md`) don't mention the route or the indexer yet; the docs slice should.

## Slice: 24 — search in the app (⌘K panel, iPhone field)
**Shipped**
- `Types.swift`: `SearchKind`, `SearchFilters`, `SearchResult`, `SearchAnswer` replace `SearchHit`. `SchermesClient.ask(_:)` replaces `search(_:)`.
- `Views/Search.swift` (new): `SearchResult.thread`/`kindWord`, `UnderstoodAs`, `ResultRow` (kind icon + word, bloub + name or "You", time; "in <participants>" or the path in SF Mono; snippet), `SearchPanel`.
- `ConsoleView.swift`: sidebar Search row (⌘K) and sheet, iPhone field + Search section, `open(_ hit:)`, `focus`, Quick Look for files, lever `search:<question>`. `HitRow` and `source(of:)` are gone; `.searchable` no longer filters agents where there is room.
- `ChatView.swift`: `focus: Int?` opens the thread at that row.
- `TypesTests`: `searchAnswerDecodesUnknownKindsAndMissingFields`.

**Key decisions**
- `GET /api/search`, `searchMessages`, shared `SearchHit` and their test stay: `infra/smoke.sh` calls the GET route and smoke is outside this slice. Retire them when smoke moves to POST.
- Ask on Return, not as you type: a debounce would spend a model call per pause.
- A file hit opens in Quick Look (not the artifact pane): switching threads clears `artifacts.open`, so the pane would close under it.

**Verified**
- `xcodebuild test` iPhone 17 Pro sim → 0 (181 tests), macOS → 0 (182). `pnpm check` → 0, `pnpm test` → 0 (no daemon changes).
- Runtime on a copy of the 7795 bed on 7830 (files_fts seeded with `indexAgentFiles`): iPhone lever showed "Understood as" chips, "Plain text search", two message hits and the Ledger PDF hit; tapping "Book the TAP one" opened Mo's thread scrolled to it. Mac lever app showed the same in the ⌘K sheet.

**Notes / leftovers**
- Runtime-unverified: opening a hit from the Mac sheet (cua-driver could not resolve the sheet window for a background click; same `open(_:)` as the verified iPhone path); a file hit's Quick Look (the Mac bed has no `getent`/`stat` shims, so the file fetch fails there); a model-read answer (the bed's model replied empty, so it fell back).
- The simulator app ignored the `schermes.serverAddress` default written with `simctl spawn defaults write` this time; pass `-schermes.serverAddress` as a launch argument instead.
- Placeholder choices: chips use `Theme.retrying` on a 14% fill of it (the canvas's amber); kind symbols `bubble.left` (Message), `camera` (Screenshot), `fileKind` for files, `magnifyingglass` for unknown; the empty answer reads "Nothing found."; the iPhone field prompt is "Search or ask".

## Slice: 25 — workspace snapshots and restoring files (daemon)
**Shipped**
- `daemon/src/snapshots.ts` (new): the snapshot script, `snapshotWorkspace`, `pruneSnapshots`/`startSnapshotPruner`, `pickSnapshot`, `diffManifests`, `fileChanges`, `restoreFiles`, `restoredLine`, `cantUndo`.
- `loop.ts`: snapshot at the start of every permanent-agent turn. `main.ts`: the hourly pruner.
- `app.ts`: `GET …/rewind?from=` preview (agent and conversation), `files: true` on `POST …/rewind`; the approval line now uses `APPROVED`/`GO_AHEAD`.
- `conversations.ts`: `rewoundRows` split out of `rewindConversation`. `forms.ts`: `FILLED`. `idle.ts`: `MAIL_SENDERS` exported.
- `shared`: `FileChanges`, `CantUndo`, `CANT_UNDO_KINDS`/`CantUndoKind`, `RewindPreview`.
- Tests: `api.test.ts` "a turn snapshots the files first; a rewind previews and puts them back", "a rewind with files and no snapshot from before that point changes nothing" (incl. the 7-day cutoff and prune), "a manifest diff compares whole seconds…"; `loop.test.ts` `tooling` ignores the snapshot call.

**Key decisions**
- Files on disk in the agent's home, no table and no migration: the name carries the mark and the time.
- Tar, not hard-linked copies: a hard link shares the inode, so an in-place edit would change the snapshot too. Only whole archives are hard-linked, for unchanged homes.
- Mark = the global newest message id at turn start. The snapshot for `from` is the first with mark ≥ from−1 = before any turn that started once `from−1` existed. Both app paths hit it: Restore (`from` = the owner's message) and Retry (`from` = prompt+1).
- Mtimes compare in whole seconds (tar restores integer mtimes). Paths that are absolute or contain `..` are dropped before anything reaches `rm`.
- The restore line is an owner row (no sender), like `HANDS_BACK`; a group thread gets one per agent.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (289).
- The script for real in `debian:stable-slim` (GNU tools): snapshot, hard-linked unchanged snapshot, diff, restore (the added file removed, the deleted one back, content back), a clean diff afterwards, prune. `bash -n` clean.
- A copy of the 7795 bed booted on 7841 (health ok; only the known Mac `getent` errors).

**Notes / leftovers**
- A turn cut in the middle by `from` keeps what it did before the cut (the next snapshot is after it).
- Between the busy check and the row rewind, a restore awaits the shell; a message arriving then could start a turn during the restore. Rare, not guarded.
- Files that vanish between `find` and `tar` show as "removed" in a later diff but cannot come back.
- Every changed turn costs a full tar of the home (`ponytail:` note in the file).
- Placeholder choices: the store is `~/.schermes-snapshots`; restore line wording "The owner put <name>'s files back to how they were at this point in the thread: 1 changed file put back, …"; can't-undo texts ("<agent> sent mail: <command>", "You approved: …", "You filled a form on <origin>.").


## Slice: 26 — Restore and Retry preview sheet (app)
**Shipped**
- `Types.swift`: `FileChanges` (+`count`), `CantUndoKind` (open enum), `CantUndo`, `RewindPreview`; `restoredLineStart`/`restoredLineMiddle`.
- `SchermesClient`: `rewindPreview(_:from:)` (`GET …/rewind?from=`), `rewind(_:from:retry:files:)` (`files` defaults false; Needs-you retry and `/new` unchanged).
- `Views/Restore.swift` (new): `RewindPreview.hasFileChanges`/`canPutFilesBack`/`fileLines(limit:)`, `RestoreLine`, `RewindSheet` (title, "N later messages will be removed", "Put the files back too" toggle with per-agent "<title> changed N files after this message", SF Mono list capped at 6 + "and N more", red "Can't be taken back" box, Cancel + destructive Restore/Retry pinned below the scroll view, errors inside).
- `ChatView`: `confirmationDialog` replaced by `.sheet(item: $confirming)`; `rewind(_:files:)` now throws into the sheet. `isOwner` excludes restore lines; `isRestoreLine` renders `RestoreLine`. `ConsoleView` sidebar preview says "Files put back".
- Tests: `TypesTests` decode with an unknown kind, `fileLines` cap, `canPutFilesBack` with noSnapshot/no changes; `ThreadTests` the restore-line classifier (incl. `retryStart`).

**Key decisions**
- The sheet now always shows (before, only when later owner messages would go): the files choice and the can't-undo list need it every time.
- For Restore, "later" = `removed − 1` (the owner's own message goes back into the composer); for Retry it is `removed`. `removed` counts tool rows too.
- Files are sent only when the toggle is on and `canPutFilesBack`; with any `noSnapshot` agent the toggle is off, disabled and says why (the daemon would 409).
- `isOwner` excludes the restore line, so `/undo`, Restore, `retryStart` and Thread.swift's "owner wrote since" rules skip it.

**Verified**
- `xcodebuild test` iPhone 17 Pro sim → 0 (184); macOS → 0 (185); `pnpm check` → 0; `pnpm test` → 0.
- Live on the simulator against the 7795 bed (restarted with slice 25's daemon code, same data dir and shim PATH): long-press → "Restore to this message" → the sheet loaded the real preview ("1 later message will be removed"), toggle off/disabled with the no-snapshot line (Mac bed has no GNU tar). Cancelled; nothing rewound.

**Notes / leftovers**
- Needs-you Retry (`ConsoleView.retry`) still rewinds without the sheet and without `files`.
- The file-list and can't-undo states with real snapshots were not seen live (tests only); Mac sheet not seen live.
- Placeholder choices: "Files put back" + `arrow.uturn.backward` for the restore line; list cap 6 and "and N more"; `added/changed/removed` column labels; "your message goes back into the box" / "and the agent answers again"; "No files changed after this message."; the no-snapshot sentence; the 0.12 red fill; bordered Cancel.
- Runtime-unverified: the sheet on macOS and iPad; the populated file list and can't-undo box.

## Slice: 27 — Forward / "Send to…"
**Shipped**
- Daemon: `POST /api/agents/:name/forward` in `app.ts` (+ `parseForward`, `forwardedText`, `uploadName`, `writeUpload`), `findMessage` in `conversations.ts`, shared `ForwardRequest`/`ForwardResult`. Test in `api.test.ts` (message + file with note, message alone, every refusal, worker target).
- App: `Views/Forward.swift` (new), `ForwardFile`/`ForwardRequest`/`ForwardResult` in `Types.swift`, `SchermesClient.forward(to:_:)`, "Send to…" in `MessageRow` and `FileCard`, the sheet in `ChatView`. Tests in `TypesTests` (encoding omits nils and trims the note, result decode, `forwardTargets`). `xcodegen generate` run.

**Key decisions**
- A file forwarded from a card also carries the message it sits in (canvas: "Ledger also gets Mo's message, so it knows what this is").
- The forwarded row is a plain owner row (no sender), so pending questions/hand-overs in the target reset like any owner message; the source text is quoted, not marked as outside data (it comes from the owner's own agents).
- Only the text of a message travels; its picture does not.
- Presenting through an @Observable `Forwarder` in the environment instead of a closure, so `MessageRow`'s `.equatable()` still holds.

**Verified**
- `pnpm check` → 0, `pnpm test` → 0; `xcodebuild test` iPhone 17 Pro sim → 0 (186), macOS → 0 (187).
- Live on the 7795 bed (restarted with this code; added a `base64` shim for `-w0` in `<scratchpad>/shim2` ahead of the old shim PATH): curl forward of a message and of a file (copied into ledger's `~/uploads`); on the simulator long-press → "Send to…" → sheet listed Ledger/Scout/Juno/Pixel with labels (Mo excluded), note typed, Send dismissed it and the row landed in Ledger's thread.

**Notes / leftovers**
- Placeholder choices: "Send to…" + `arrowshape.turn.up.right`; sheet title and first section both "Send to"; "Forwarding this to you." when no note; "Forwarded from something I wrote earlier" for owner rows; "I put the file in your home: …"; footer "<Agent> also gets the message, so it knows what this is."; "There is no other agent to send this to."
- The target's reply is not surfaced in the source chat; the owner opens the target to see it.
- Runtime-unverified: the file-card "Send to…" (no file card in the bed thread), the Mac hover action and the sheet on macOS/iPad.

## Slice: 28 — new agent from a description
**Shipped**
- Daemon: `suggest.ts` (new: `suggestAgent`, `freeName`, `MAX_DESCRIPTION_CHARS`), `POST /api/agents/suggest`, described creation on `POST /api/agents` (`describedStart` in app.ts), `describedKickoff` in interview.ts, `parseLevels` factored out of `updateRules`. Shared: `BLOUB_SHAPES`, `BLOUB_COLORS`, `AgentSuggestRequest`, `AgentSuggestion`, `AgentCreateRequest`. Tests in `api.test.ts`: a clean + dirty model reply (taken name → `-2`, bad look, passwords/made-up levels, cron with no next run, unusable reply), no model, a described create whose desktop fails in the background (201, interview ran, rules + schedule stored, kickoff quotes the description and tagline), refusals create nothing.
- App: `Views/NewAgent.swift` (new; `xcodegen generate` run): description field → Suggest → editable name, tagline, look, a Rules disclosure (summary + a menu picker per row), First routine (cadence, cron, prompt, Leave out) → "Create <Name>". Tests in `TypesTests` (suggestion decode with/without model, `NewAgentPlan.request` encoding, `rulesSummary`).

**Key decisions**
- `label` stays the title ("Scout"); the one-line label ("Support inbox") is the `tagline`, which only exists once the profile is written. So the tagline rides in the kickoff ("start your profile with this line"), no new column; a seeded profile would have skipped the interview.
- The model is asked for the label, not the name; the name is always the free slug of the label (daemon for the suggestion, app re-derives as the owner edits).
- Background desktop only when a description is sent, so the plain create keeps its rollback-on-failure contract and test.
- A model reply is read leniently (bad fields fall back one by one); the owner's create body strictly (400).

**Verified**
- `pnpm check` → 0, `pnpm test` → 0; `xcodebuild test` iPhone 17 Pro sim → 0 (189), macOS → 0 (190).
- Live on the 7795 bed (restarted with this code, PATH shim2:shim as before): curl suggest (stub → plain fallback), curl described create answered 201 in 9 ms with the interview started and the routine stored while the (shimmed) desktop failed in the background; on the simulator: + → description typed → Suggest → fields filled, Rules expanded with 8 named pickers → "Create Helper" opened the new agent's chat with the kickoff. Test agents and the session row removed afterwards.

**Notes / leftovers**
- Placeholder choices: fallback label "Helper"; "What should it help you with?" with the canvas sample as placeholder; "Suggest" / "Suggest again" / "Suggesting…"; tagline placeholder "What it's for, in a few words"; "Rules" with "3 on its own · 1 if pre-approved · 4 ask first"; "First routine" + "Leave out"; footer "Its desktop starts in the background while <Name> asks you a few questions."; button "Create <Name>".
- The system prompt's no-profile text still says "First one open question … what they want you for"; the described kickoff says not to re-ask. Tightening `profilePrompt` is optional.
- Pre-existing, not touched: `toAgent` leaks the raw `rules`/`grants`/`idle` JSON columns into every Agent response (seen on the create answer).
- Runtime-unverified: a real model's suggestion (the stub only yields the fallback), the look/routine rows filled from a suggestion, and the sheet on macOS/iPad.

## Slice: 29 — actionable push
**Shipped**
- Daemon: `pushCategory` + `PushNotification.needsYou`/`category` (push.ts), `pushedItem` (needs.ts), `decide()` factored out of the approvals route, `POST /api/needs-you/:id/action`, `AppDeps.pushSend`. Shared: `PushCategory`, `NeedsYouActionRequest`. Test in `api.test.ts`: approval and deletion pushes carry id + category, the closing reply none; the route 404s unknown and stale ids, 400s an unoffered or non-string action, approves through a `%3A`-escaped id (asker told like the app button), denies a deletion (agent kept); a question push is `needs.open` and `answer` is 400; `pushCategory` for passwords/conversation/hand-over/form.
- App: `PushCategory` + delegate handling in `Notifier.swift`, registration in `SchermesApp.swift` delegates, `SchermesClient.act(onNeedsYou:_:)`, `addressKey` no longer private (Session.swift), local posts in `ConsoleView.announce` get category + userInfo. Swift tests in `TypesTests` (item → category, buttons/ids/options, `answer`).

**Key decisions**
- The item is resolved in the push hook from the rows (no `deliver` signature change); a plain reply never borrows an older open item.
- Button ids are the `NeedsYouAction` wire words; only approve/deny call the route, `open` and a body tap open the agent as before. `always` is never on a notification (changes standing rules from a lock screen).
- Approve (approval) and Delete it need an unlocked device (`.authenticationRequired`); saying no never does. Words mirror `Approval.yesWord`/`noWord`.
- A background launch has no `Session`, so the relay builds its own client; the shared cookie store carries the login.

**Verified**
- `pnpm check` → 0, `pnpm test` → 0; `xcodebuild test` iPhone 17 Pro sim → 0 (191), macOS → 0 (192).

**Notes / leftovers**
- Placeholder choices: button words "Approve"/"Don't", "Keep it"/"Delete it", "I'll do it"/"Don't", "Watch", "Open"; failure post "Your answer did not reach the daemon: …" titled like the original notification.
- Runtime-unverified: real APNs delivery, the buttons on a lock screen, a background-launch answer (all `[user-gated]` device checks); the 7795 bed was not restarted with this code (the route is covered by the api test only).
- `pushedItem` calls `listNeedsYou` once per push (only when push is configured).

## Slice: 30 — Live Activity
**Shipped**
- Daemon: `liveactivity.ts` (`activityPayload` pure, `activityState`, `activityAttributes`, `createLiveActivities`), `live_activity_tokens` + migration `0025_glamorous_toad.sql`, `POST /api/live-activities`, runner hooks `RunnerDeps.turn` and `LoopDeps.progress`, `AppDeps.activityThrottleMs`, `sendEach` factored out of `sendPush`. Shared: `LiveActivityAttributes`, `LiveActivityState`, `LiveActivityTokenRequest`.
- App: `AgentActivityAttributes` (+ `ActivityAttributes` conformance under `#if os(iOS)`), `SchermesWidgets/AgentActivityWidget.swift` (lock screen, Dynamic Island expanded/compact/minimal, bloub colour, state icon + word, steps bar, "Needs you"), `NSSupportsLiveActivities`, token registration from `AppDelegate` (iOS), `SchermesClient.registerLiveActivity`.
- Tests: `push.test.ts` payload pin; `api.test.ts` "a turn starts, updates and ends its Live Activity…" (validation, start headers/topic/priority, update token, goal update at priority 5, end with dismissal and a later timestamp, spent token, late token ended); `AgentActivityTests.swift` (2).

**Key decisions**
- Title = the open goal the agent leads (else the one it helps), else the owner's newest line in its own thread (first line, 80 chars). `state` is the raw `AgentState`; the widget repeats the app's words (`ActivityStateWord`) because it does not compile the app's views.
- One activity per turn (drain), not per round. Start carries `alert` (Apple requires it) and `input-push-token: 1` (iOS 18+). Priority 10 for start/end/updates with needs-you, else 5.
- Colour: the daemon sends `look` as-is; the widget resolves `BloubIdentity(token:) ?? .standard(for:)` so there is one hash implementation.
- Registration runs from `didFinishLaunching`, since push-to-start wakes the app in the background with no `Session`.

**Verified**
- `pnpm check` → 0, `pnpm test` → 0 (296 daemon); `xcodebuild test` iPhone 17 Pro sim → 0 (193), macOS → 0 (194); Mac app bundle has no PlugIns widget. Lock-screen view seen on the simulator via `-schermes.debugActivity YES` + `idb ui button LOCK`.

**Notes / leftovers**
- Placeholder choices: dismissal 15 min after the turn; throttle 5 s; start alert body = title or "Started working."; "Needs you" orange (`.orange`, not `Theme.needsYou`, which the extension lacks); lock-screen background black 55 %; compact trailing shows needs-you hand, else steps "n/m", else the state icon.
- Runtime-unverified: Dynamic Island (simulator screenshots do not show it), any real liveactivity push, push-to-start and the background token hand-off (`[user-gated]` device check). The first device build must add the Live Activity capability via `-allowProvisioningUpdates`.
- An activity started but whose update token never arrives stays until iOS drops it (up to 8 h); a daemon restart forgets which starts were sent. An agent renamed at the end of a turn keeps its old name on its token rows.

## Slice: 31 — macOS menu bar extra
**Shipped**
- App: `Views/MenuBar.swift` (new: `quickMessage` parser + `QuickMessage`, `MenuBarFeed`, `NeedsYouItem.answeredInPlace`, `MenuBarLabel`, `MenuBarPanel`, `PanelHotKey`, `consoleWindowID`); `SchermesApp.swift`: `MenuBarExtra` scene (macOS), main `WindowGroup(id: consoleWindowID)`, `PanelHotKey.register()` in the Mac `AppDelegate`; `NeedsYou.swift`: `BusyAgentRow` factored out of Right now. `xcodegen generate` run.
- Test: `SchermesTests/QuickMessageTests.swift` (names with `-`, `@Name,`/`@name:` forms, unknown and prefix-only names, empty/whitespace, bare `@scout`, `bob@x.com` stays plain, `@ hi`).

**Key decisions**
- The panel answers only yes/no in place (same `decide()` through `POST /api/needs-you/:id/action`); retry, fill, restart and the rest show as Open and go to the console, rather than showing buttons that secretly just open it.
- Own poll instead of reading the console's state: the Mac console window can be closed while the menu bar extra lives on.
- Hotkey: Carbon `RegisterEventHotKey` (no Accessibility permission); SwiftUI has no API to open a `MenuBarExtra`, so the hotkey clicks its status button found by walking the `NSStatusBarWindow`'s views (no private KVC key). Not registered under XCTest so test runs never take the owner's ⌥Space.
- Names match case-insensitively, token charset `[A-Za-z0-9-]` like `AGENT_NAME`; only a leading `@` counts.

**Verified**
- `pnpm check` → 0, `pnpm test` → 0; `xcodebuild test` iPhone 17 Pro sim → 0 (196), macOS → 0 (197, the 3 new tests seen passing).

**Notes / leftovers**
- Placeholder choices: icon `bell` / `bell.badge.fill` + count; panel 380 pt wide, max 480 pt list; "To <Agent>" / "Pick an agent" menu; field placeholder "Message, or @name message"; "⌥Space" hint; "There is no agent called <name>."; "Pick who gets it, or start with @name."; "Sent to <Agent>."; "Nothing is waiting on you."; "Nothing is running."; "Open Schermes to sign in.".
- `.openAgent` posted while no console exists (window just opened) is lost, so Open then lands on the default pick; same gap as push taps.
- A macOS test run shows the status item in the owner's menu bar while it runs. ⌥Space may collide with Alfred/Raycast; a failed registration is silently a no-op.
- Runtime-unverified: the panel opening (click and ⌥Space), the text field taking focus in a non-active app, the label count, Open bringing back the console, the send. Not exercised live because opening the panel may activate the app (focus-free rule); owner check.

## Slice: 32 — share extension and macOS Services
**Shipped**
- Shared: `Schermes/Share.swift` (new: `appGroup`, `maxShareBytes`, `SharedItem`, `ShareTarget`, `ShareError`, `sharedMessage`, `uploadFilename`, `deliverShare`, `StoredDaemon`, `SendToSheet`, macOS `ShareService`).
- iOS: `SchermesShare` target (`SchermesShare/ShareViewController.swift`, `SchermesShare.entitlements`, generated `Info.plist`), embedded in the iOS app only. App group added to `Schermes.entitlements`.
- App: `Session.storeAddress` + `Keychain.shareWithExtension` + grouped copy in `Keychain.save` (iOS); `NotificationRelay.background` → `StoredDaemon`; `NSApp.servicesProvider` in the Mac `AppDelegate`; `NSServices` in `project.yml`; `registerDevice` under `#if !SCHERMES_EXTENSION`; `plainPreview` moved ConsoleView → Types, `rulesSummary` Types → Rules (pure moves). `xcodegen generate` run.
- Test: `SchermesTests/ShareTests.swift` (URL with and without instruction, text quoted per line, file named by the daemon's path with a goal, goal → lead, filenames against the route regex incl. accents, leading dot/underscore, `..`, CJK, empty, over-length keeping the extension).

**Key decisions**
- No daemon change: a file is the existing uploads route, then one ordinary owner message, so the recipient's turn starts through `POST /api/agents/:name/messages`. A goal share goes to the lead with the goal named in the text.
- The extension gets the address from the app-group defaults and logs in with a grouped Keychain copy of the password (its own cookie store after that). A copy is added beside the app's item rather than moving it, so a concurrent re-login never finds nothing. Refreshed on every connect, so upgraded installs catch up.
- Services run in the app process, so they use the standard defaults and no group container (a group container without entitlement can raise a privacy panel on macOS).
- The extension compiles four app files, not `Api/` whole: `Thread.swift` reaches into `ChatView`.

**Verified**
- `pnpm check` → 0, `pnpm test` → 0; `xcodebuild test` iPhone 17 Pro sim → 0 (201, the 5 new tests seen passing), macOS → 0 (202). iOS app has `PlugIns/SchermesShare.appex` with the activation rule; the Mac app has no share plugin and carries `NSServices`.

**Notes / leftovers**
- Placeholder choices: "Send to Schermes" title, "Open goals" / "Agents" sections, "Led by <lead>", "What should happen with it?" field, "Instruction for <agent>", default instruction "Have a look at this.", "This is for the goal \"…\".", fallback filename "shared", "Open Schermes and sign in first.", "There is nothing here to send.", Services item "Send to Schermes…"; no bloub in the picker (the extension does not compile the bloub renderer); red for errors (no `Theme` in the extension).
- An upload that succeeds before a failed send leaves the file in `~/uploads` unmentioned; a retry uploads it again.
- `[user]` The first device build with `-allowProvisioningUpdates` must register the App Group `group.dev.schermes` and the `dev.schermes.Schermes.Share` App ID.
- Memory: a file near 25 MB is held as Data + base64 + JSON (~90 MB) inside an extension killed at ~120 MB without a message; a long Photos video is the likely silent failure on the device check.
- Runtime-unverified: the share sheet entry, item loading (Safari link, Notes text, Files file, Photos image), the login hand-off and the send (`[user-gated]` device check: the simulator build has no app group). The Mac Service (menu entry may need `/System/Library/CoreServices/pbs -update` or a relaunch; the window activating the app) was not exercised under the focus-free rule.

## Slice: 33 — teach a skill ("Show the agent how")
**Shipped**
- Daemon: `recording.ts` (new: `rfbInput`, `createRecorder`, `secrecy`, `shownLine`, `SHOWN_PREFIX`, `saveRecording`), `focusedField` in `browser.ts`, `SECRET_AUTOCOMPLETE` exported from `forms.ts`, `tap` on `attachVncProxy` (`vnc.ts`), routes + `handOver` in `app.ts` (`createApp` returns `recorder`), `main.ts` wires the tap. Shared: `RecordingState`, `ControlState.recording`.
- App: `SchermesClient.RecordingState`, `startRecording`, `setRecordingSecret`; `DesktopView` teach controls; `ShownLine`; `Message.isShownLine`; sidebar preview.
- Tests: `recording.test.ts` (parser split/joined/unknown type, steps incl. double/drag/scroll/backspace/chords, other display, step/shot/time caps, secrecy table, masked password keeps shots, owner Secret and OTP stop shots, slow/failed check stays secret, hand-off text); `api.test.ts` (routes, 404/409/400, held screen refuses the puppet route, hand-off row + image + turn, steps.json written, secret absent from messages, events, model requests, files and control answers; zero steps hands nothing); `vnc.test.ts` tap; Swift `controlStateCarriesARecordingOnlyWhileOneRuns`, `theRecordingHandOffIsNotTheOwnerSpeaking`.

**Key decisions**
- Recorded in the daemon off the VNC proxy, not in the app: both platforms for free, and only the owner's input passes there (the agent's xdotool does not).
- No table: the session is stored in the agent's home (`~/recordings/…`), and the hand-off row is in the transcript. A daemon restart drops a recording in progress, like the control hold.
- Screenshot rule for secrets as above (strict: after a visible secret, no more shots). Password fields are masked on screen, so they don't stop shots.
- The routine offer is the agent's `ask_owner` card, which the hand-off text asks for; no new app card.
- Hand-off is an owner row (like the restore and filled lines), shown quietly by prefix.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (307). `xcodebuild test` iPhone 17 Pro sim → 0 (203); macOS → 0 (204).
- Bed (7795, restarted on this code) + a fake Xvnc (`scratchpad/fake-xvnc.mjs`, RFB 3.8, one raw frame) on Juno's display: the simulator showed the frame, "Show how" started a recording, a tap, typed text, Secret-typed text and Return went through the proxy; "Stop and hand over" wrote `~/recordings/20260930-205725/steps.json` and the hand-off row ("4 steps in 28 s", step 3 "Type something secret"), the secret was in no message, log or file; Juno's turn ran; the chat shows "Showed how · 4 steps in 28 s". A relaunched app picked up the running recording from `GET …/control`; an empty recording handed nothing over. The bar was fixed after the check (name no longer wraps; the stop button is icon-only while recording).

**Placeholder choices**
- Copy: "Show how", "Secret" / "Secret on", "Stop and hand over" (iPhone "Hand over"), "N steps" red label, "Showed how · …", sidebar "Showed how it's done", help texts, the hand-off wording; symbols `record.circle`, `lock.open`/`lock.fill`, `stop.circle.fill`; limits 12 shots, 200 steps, 30 min, 700 ms shot delay, 500 ms double click, 8 px drag threshold, contact sheet 3 columns at 640×400.

**Runtime-unverified**
- Screenshots and the contact sheet (no scrot/ImageMagick on the Mac bed: shots failed and were logged, the recording went on), the CDP password check against a real Chromium, a real Xvnc, the Mac window's toolbar controls, and a model actually writing the SKILL.md and offering the routine (the stub answers with a fixed line).

**Notes / leftovers**
- `cdpConnect` checks the first page target only; typing into a second tab reads as "elsewhere" (not secret) unless Secret is on (ponytail comment in `browser.ts`).
- A secret typed into a terminal (sudo prompt) can't be detected; the owner turns Secret on.
- The bed now runs slice 33's code; the fake Xvnc process on 5904 was stopped after the check.

## Slice: 34 — docs and the migration boot check

**Shipped**
- `docs/architecture.md`: new sections Model registry and recovery, Agent tools (who gets which tool, incl. idle and helper sets), Needs you, Approvals and the rules ladder, Hand-over/forms/teaching (secret rules, vault, recording redaction), Feedback, Idle work, Triggers (incl. `/hooks/:token`, IMAP), Goals and helpers, Search, Snapshots and putting files back, Forwarding and new agents, Background work (the five timers in `main.ts`); Persistence, Security and Clients updated.
- `docs/configuration.md`: "Provider settings" became "Models" (registry fields, `models.default`/`models.backup`/`agents.model_id`/`models.authFailed.<id>`, the `provider.*` upgrade, `/api/settings` still writing the default entry), actionable push categories, Live Activities, new constants, Search and OCR (tesseract), Triggers and the webhook URL, per-agent settings, what needs TLS in front.
- `docs/development.md`: daemon test table and seams (`fixture()`, `AppDeps`, `LoopDeps`), Swift tests (suiteless, so run the whole target), a daemon without Docker (seeding, the sudo/getent/timeout/GNU shims), `provider-stub.py` scripts and `status-NNN` keys, DEBUG launch arguments, migrations (`--custom`) and the boot check recipe.
- `apple/README.md`: Targets table (app, SchermesWidgets, SchermesShare, SchermesTests; menu bar extra and Services in the app), device-only entitlements, the app group, the APNs environment, actionable push, Live Activity, a file map of the new screens. The earlier uncommitted edits kept.
- Written by four parallel subagents (one file each), reviewed and spot-checked against the code here (routes, `insertAgent` signature, stub keys, DEBUG keys, rule and idle defaults, trigger limits). One fix: architecture called the FTS5 migration "hand-written"; now "`--custom`".

**Migration check (method)**
- `pnpm migrations` → "No schema changes, nothing to migrate": schema and snapshots agree. 0013–0025 start with drizzle's generated SQL; 0024 is the documented `--custom` (FTS5).
- Old DB: a scratch `old-migrations/` holding 0000–0012 + their snapshots and `_journal.json` filtered to `idx <= 12`; a node script (run from `daemon/` for `node_modules`) applied them with drizzle's `migrate` (foreign keys off, as `openDb` does) and inserted a permanent agent, a worker, a conversation with two messages, an `agent` approval, a schedule and `provider.baseUrl`/`provider.model` settings.
- Booted `SCHERMES_PORT=7841 SCHERMES_DATA_DIR=<scratch>/fresh` and `7842 … <scratch>/upgraded` with `node src/main.ts`: both logged "daemon listening" and answered 401 on `/api/needs-you`; the only errors were macOS lacking `getent`/passwordless `sudo`. Afterwards (via better-sqlite3; the system `sqlite3` has no FTS5): 26 migrations in both; upgraded kept its rows, the approval got `category = delete_files`, `messages_fts` found the old "Hello" message, `provider.*` became model 1 and `models.default = 1`.

**Verified**
- `pnpm check` → 0; `pnpm test` → 0 (307). No Swift or UI change.

**Notes / leftovers**
- `docs/README.md`, `deployment.md` and `troubleshooting.md` were out of scope and not reviewed.
- `GET /api/search` still exists only for `infra/smoke.sh`; the smoke slice can move to `POST /api/search` and then drop it.

## Slice: 35 — the smoke covers the new flows

**Shipped**
- `infra/smoke.sh`: model registry and rules sections before the harness gate, since neither needs a turn. Leftover cleanup: `smoke-registry` models are removed before the settings round-trip (the default is moved off a leftover first), and so are the smoke agents' triggers. The `GET /api/search` section became `POST /api/search`: it checks `understoodAs`, `byModel` and a message hit in `smoke-one`'s thread; the plain fallback answers, because the stub replies with no filters. A new harness section:
  - **Rules refusal:** a file created with `run_cmd`, an `rm -f` refused with "Nothing was run", and the file still there.
  - **Approvals and Needs you:** the approval shows in `/api/approvals` and in `GET /api/needs-you` as `approval:<id>`. It is denied through `POST /api/needs-you/:id/action`, is gone from both lists, and a second answer gets a 404.
  - **Webhook:** the proposed webhook is turned on (`/api/triggers/:id`), then `/hooks/<token>` is called with plain curl: no secret 401, wrong secret 401, right secret 202. The `Trigger N fired:` row carries the body, and the hook answers 404 after the trigger is deleted.
  - The gate and final OK messages were updated.
- `infra/provider-stub.py`: a new script, `guarded`. The SENDER runs COMMAND, then `request_approval` for delete_files with target NONCE, then `propose_trigger` for a webhook, then reports. `heard` now also reads "`<name>` said here, to the owner:". The daemon has used that label for another agent's reply since 0f1bd75, and the talk section was failing on it.
- Stale smoke expectations fixed:
  - The expected `tools=` list (22 tools now), in two places.
  - `settle` now waits for a `turn` event newer than a per-agent mark, seeded before the first turn, and ignores a `failed` state left by an earlier turn. Without this, a re-run's settle returned before the turn started: the snapshot before the turn leaves the state at `waiting_for_user`.
- Daemon: `GET /api/search` removed, along with `searchMessages`, `MAX_SEARCH_CHARS`, `SearchHit` (shared) and its api test. Its lines were dropped from `docs/architecture.md` and `docs/configuration.md`; `docs/development.md` now names what the smoke covers.

**Key decisions**
- The approval is denied, not approved. Approving grants a one-shot pass (and Always moves the level), so the next run's delete would go through.
- Leftover approvals are denied under a report-only stub (a denial starts a turn), before the guarded stub starts counting its calls.
- No daemon change for the gap before a turn. Moving `transition('thinking')` above `snapshotWorkspace` would leave an agent stuck in `thinking` if the pre-turn work throws. It is listed under leftovers.

**Verified**
- Docker harness in a throwaway compose project (`COMPOSE_PROJECT_NAME=smoke`, `container_name: schermes-smoke`, port 7779, fresh volumes). Runs 4 and 5 both exited 0, back to back, on a database that still held leftovers from three earlier failed runs. The project was torn down with `down -v --rmi local`.
- `pnpm check` → 0.
- `pnpm test` → 0 (306, one fewer: the `GET /api/search` test is gone).
- `xcodebuild test` on the iPhone 17 Pro simulator → 0 (203).
- `xcodebuild build` for macOS → 0. The macOS test host was not run, to keep focus; it last passed in slice 33 (204), and no Swift file changed in this slice.

**Notes / leftovers**
- The smoke's no-harness path fails against a daemon that runs in Docker but is not detected as the harness: the upload section calls `in_container` unconditionally. This is pre-existing, and a real bed without Docker was not exercised.
- UX gap in the daemon: between a posted message and the first model call (snapshot, compaction, MCP connect), the app still shows the agent as `waiting_for_user` ("Ready").
