Completed (pending acceptance: 82 items, see ACCEPTANCE.md)

# Redesign and agent flows

## Goal
The app is grey and its features sit side by side instead of flowing into each other. Rebuild the
look around the agents' own bloub colours, and add the flows that make persistent agents feel like
coworkers. That covers per-action rules, one place for everything that needs the owner, forms and
logins handled from the chat, goals with helpers, triggers the agents set up themselves, idle work on
a budget, recovery, search, and native integrations. The target design is the Claude Design canvas
https://claude.ai/artifact/Ns9Ynh8yTKkCmoPrQESQir, benchmarked against OpenAI Dots and xAI Grok Bot.

## Scope
**Look (Mac, iPad, iPhone)**
- Warm paper ground instead of grey. Each agent's bloub colour tints its thread and supplies its accents; the owner's bubble is a flat colour with no gradient.
- SF Rounded for titles and agent names, SF Mono for paths and commands.
- State is always an icon plus a word, never colour alone.
- A name (and its one-line label) next to every bloub in every list and picker.
- A context-fullness meter; no cost or token tiles anywhere.
- Mac layout:
  - Sidebar: Search, Needs you with its count, Goals with progress rings, Agents with their helpers nested, Messages.
  - Chat: tinted, with an inspector column holding Screen, Goal, and Routines and triggers.
- iPhone:
  - Agents home: a Needs you strip, goal cards, and agent cards showing label, state and last line.
  - Floating search and a New agent button.

**Owner-facing surfaces**
- Needs you (Mac and iPhone) lists:
  - payment and other approvals
  - delete requests
  - questions
  - hand-over requests
  - form requests
  - failures that need a person
  - a "Last night" digest of idle work
  - a "Right now" list (Mac)
- Per-agent settings (Mac page, iPhone sheet): rules, routines and triggers, when idle, memory.
- Actionable push, and a Live Activity with a Dynamic Island view for the running work.
- A macOS menu bar extra: Needs you with inline actions, what is working, and a quick message field on ⌥Space.
- An iOS share extension and macOS Services: send a URL, file or text to an agent or a goal, with an instruction.

**Agent capabilities (daemon and app)**
- **Rules ladder.** Per agent and per action category, one of four levels: on its own, if pre-approved, ask first, hand to you.
  - Categories: browse, run commands, write files, delete files, send messages, spend money, install software, share outside.
  - Passwords and security settings are always handed to the owner.
  - A pre-approved list holds domains and recipients.
- **Ask for hands.** A tool that asks the owner to take the screen for a stated reason. "Give it back" resumes the agent and leaves a line in the chat.
- **Forms from the chat.** A tool that makes the daemon read a form's fields from the live page. The app shows them as native fields; the daemon types the values into the page.
  - Secret values never reach the model or the transcript.
  - Values can be remembered per origin, encrypted.
  - Fields it can't fill go to the screen: CAPTCHAs, cross-origin payment frames, unknown widgets.
  - Plain HTTP also sends the fields to the screen.
- **Teach a skill.** Record the owner's takeover session; the agent drafts a reusable skill and can turn it into a routine.
- **Reply feedback.** Thumbs up or down with a reason. It feeds memory.
- **Idle work.**
  - Free pre-checks in the daemon decide whether a pass runs at all.
  - Limits per agent: a token budget, a turn cap, a model choice and a time window.
  - Allowed outputs: memory tidy-ups with undo, routine suggestions, read-only notes, and cleanup proposals that go through delete requests.
  - It backs off after dismissals.
- **Triggers set up by agents.** The agent proposes a trigger in the chat, the owner turns it on, and they test it together. Kinds:
  - webhook
  - watched folder
  - IMAP mailbox poll
  - a check command the agent writes, which fires when its output changes
  - existing cron routines
- **Goals.** A lead agent keeps a plan up to date. Each goal has results and a "next from you".
  - Helpers come in two kinds, and the lead agent decides per helper: a worker on the lead's account with its own screen, or a temporary agent with its own Linux user and desktop.
  - Helpers are removed when the goal is done; "Keep as agent" promotes one.
- **New agent from a description.** The agent suggests its name, label, look, starting rules and first routine. Its desktop is built in the background while its interview runs.
- **Restore with files.** Workspace snapshots per turn. "Restore to this message" and "Retry" offer "Put the files back too" and list anything that can't be taken back.
- **Forward.** Send a message or file to another agent, with a note and the source message as context.
- **Recovery.**
  - A browser that hangs restarts once automatically, then the chat offers Restart browser, Restart desktop and retry, or Look at the screen.
  - Model 429 and 5xx errors retry automatically with visible attempts, and offer "Use backup model".
  - A 401 shows once, for all agents, with a link to provider settings.
- **Search or ask.** ⌘K on the Mac and the search field on iPhone.
  - The model turns the question into filters.
  - SQLite FTS5 covers messages, workspace files and screenshot text read by tesseract.
  - Results show how the question was understood and where each hit came from.
- **Model registry.** Any number of models, each with its own endpoint, key and model id, and optional extra fields.
  - Per-agent assignment, one default and one designated backup.
  - Idle work picks its own model.
  - The single provider setting migrates into the registry.

## Non-goals
- Voice calls, Slack, Teams or SMS channels.
- Siri, App Intents and home-screen widgets.
- Turn replay.
- Cloning or exporting agents.
- A web UI.
- An inbound SMTP server (email comes in through IMAP polling).
- Embeddings and vector search.
- Cost or token tiles in the UI.
- Changing how the owner password or session works.
- Multi-user accounts.

## Key decisions & constraints
- **The canvas is the visual spec.** Its Foundations page holds the cast, state, type and components. Its Colour check page holds the colour rule: tint = ground mixed with the colour at 7% (about 12% in dark mode).
  - Bubble: the colour darkened until white text passes 4.5:1, when that takes at most 26% darkening; otherwise the colour with dark text.
  - When the bubble can't be told apart from its tint (below 1.25:1), use the ink bubble (cream in light mode, ink in dark mode).
  - Accent text: darkened (lightened in dark mode) until it passes 4.5:1 on the tint.
  - The rule is one function, unit-tested over all 12 colours in both modes.
- **SwiftUI, native.** Liquid Glass only where the system puts it: sidebar, toolbar, composer, floating buttons. Keep the one shared target for iOS 26 and macOS 26. New targets (share extension, widget/Live Activity extension, menu bar) go into `apple/project.yml`; the Xcode project stays generated.
- **Daemon conventions.** Hono, drizzle, SQLite, `node --test`, strict TypeScript. Migrations are generated with `pnpm migrations`, never hand-written. New wire shapes live in `shared/src/index.ts`.
- **Secrets.** Form values, IMAP credentials and model keys are encrypted with the existing AES-GCM master key (`secrets.ts`).
  - Secret form values are typed into the page through Chrome DevTools Protocol `Input.insertText`, never placed in a prompt, and the transcript stores a redacted line.
  - The page origin shown to the owner comes from CDP, not from the model.
- **Rules enforcement.** The rules go into the agent's system prompt. The generic approval tool (generalising `request_deletion`) creates Needs you items. The daemon also hard-enforces what it can observe itself: its own file-delete paths, and package-install and delete commands through `exec`. The password/security category is never delegated.
- **Idle work.** Pre-checks run in code with no model call, and a failed pre-check spends 0 tokens. Idle passes may never send, delete, spend or install.
- **Helpers.** Workers today run as the parent's Linux user with no display of their own. The "helper with its own screen" kind needs a per-worker Xvnc display on the parent's account; the "temporary agent" kind reuses normal agent creation. Promoting one keeps its account.
- **Triggers.** Always proposed by an agent and confirmed by the owner, with a rate limit per trigger. A webhook gets an unguessable URL and a secret. IMAP credentials come in through the secure form flow.
- **Search.** tesseract is added to `infra/install.sh` and therefore to the Docker image. OCR runs in the background on stored screenshots.
- **Models.** Existing `provider.*` settings migrate into a first registry entry, which becomes the default. An agent with no assignment uses the default. The backup is used only on rate limits and 5xx errors, or when the owner picks it.
- **Working tree.** Other agents edit this checkout concurrently, and `apple/` has uncommitted changes. Never overwrite in-progress edits: check `git status` and coordinate before touching a file someone else is changing.
- **Verification.** `pnpm check`, `pnpm test`, `xcodebuild test` (macOS, and the iPhone 17 simulator), `infra/smoke.sh`. UI is checked focus-free on the simulator and with `cua-driver`, following `~/.claude/skills/native-app-testing/SKILL.md`.
- **Ponytail rules apply.** Reuse existing pieces: `ask_owner`, approvals, routines, `workers.ts`, `control.ts`, `browser.ts`, the interview, `Rewind`, `AgentLooks`.

## Preconditions & external dependencies
- The Apple team already in `project.yml` must register the App Group, the share extension, Live Activities and push capabilities. The first device build with `-allowProvisioningUpdates` does it. `[user]`
- A physical iPhone for Live Activity, actionable push and share-extension checks. `[user]`
- HTTPS in front of the daemon (the Caddyfile, or Coolify) for secret form fields in real use. `[user]`
- A real OpenAI-compatible endpoint plus a second model for live checks of recovery and the backup model. Automated tests use `infra/provider-stub.py`. `[user]`
- An IMAP mailbox for a live email-trigger check. `[user]`
- Rebuild and redeploy the Docker image (Unraid now, Coolify later) once tesseract is added. `[user]`

## Building blocks
- **App design system:** theme tokens, the agent palette rule, state icon and word, bloub with name, context meter.
- **App surfaces:** sidebar, chat and inspector, Needs you, goal page, agent settings, search, new agent, restore sheet, forward, iPhone home and sheets.
- **App extensions:** share extension, Live Activity and widget extension, macOS menu bar extra, notification categories.
- **Daemon:**
  - model registry with per-agent assignment
  - rules and pre-approvals, plus the generic approval tool
  - Needs you aggregation
  - ask-for-hands and form-fill tools (CDP extraction and fill, redaction, per-origin vault)
  - teach-a-skill recording
  - feedback
  - idle scheduler (pre-checks, budget, digest)
  - trigger kinds and the tool to create them
  - goals, and helpers with their own display
  - workspace snapshots and restore
  - forwarding
  - recovery (browser watchdog, retry and backup, the one-time 401)
  - search index (FTS5, file index, OCR)
  - Live Activity push
  - context fullness
- **Shared:** wire types for everything above.
- **Infra:** tesseract in the install and the image, the smoke test extended.
- **Docs:** architecture, configuration, development, `apple/README.md`.

## Definition of Done
### Look and design system
- [x] One `AgentPalette` function computes tint, bubble, bubble text and accent text for all 12 bloub colours in light and dark mode. A Swift test asserts bubble text and accent text are at least 4.5:1 for all 24 cases, and that cream (light) and ink (dark) fall back to the ink bubble.
- [x] Main surfaces use the warm ground token, not the system grey. The chat background is the agent's tint. The owner's bubble is flat: `accent.gradient` no longer appears in `ChatView.swift`. — note: the Mac sidebar deliberately stays on system glass; the detail column and iOS list use `Theme.ground` (PROGRESS, Current state).
- [x] Titles and agent names use SF Rounded; paths and commands use SF Mono.
- [x] Every `AgentState` maps to an icon plus a word, covered by a test. Sidebar rows, iPhone agent cards and chat headers show it. Busy shows the halo ring and idle shows closed eyes.
- [x] Every agent list and picker shows the name, plus the label where there's room. No bloub-only picker remains (share, forward, new agent, pickers).
- [x] The chat header (Mac) and the More button (iPhone) show context fullness as a percentage, from a daemon field. No cost or token tile exists in the UI.
- [x] Mac sidebar has Search (⌘K), Needs you with a count, Goals with progress rings, Agents with nested helpers and workers, and Messages. The inspector has Screen with Take control, the current goal with its helpers, and Routines and triggers.
- [x] iPhone Agents home has the Needs you strip, goal cards, and agent cards with label, state and last line, plus floating search and New agent.
- [ ] `[user-gated]` Both platforms, light and dark, compared against the canvas, read as the design, and not grey.

### Needs you, push, Live Activity, menu bar, share
- [x] `GET /api/needs-you` returns open approvals, questions, hand-over requests, form requests and failures that need a person, covered in `api.test.ts`. Resolving an item from any client removes it everywhere.
- [x] Needs you exists on Mac and iPhone with inline actions, a "Last night" section, and a "Right now" list on the Mac. The sidebar and home count matches the endpoint.
- [x] Push notifications carry categories with actions (Approve / Don't, Keep / Delete, Watch). Answering from the notification resolves the item without opening the app, covered by a daemon test on the action route.
- [x] A Live Activity shows the agent, the goal or turn, the step progress and "needs you". The daemon updates it through APNs Live Activity pushes.
- [ ] `[user-gated]` Checked on a device, including the Dynamic Island.
- [x] A macOS menu bar extra shows Needs you with inline actions, what is working, and a quick message field on ⌥Space that routes `@name` to that agent.
- [x] The iOS share extension and macOS Services send a URL, file or text, with an instruction, to a chosen agent or goal. The file lands in the agent's `~/uploads`.
- [ ] `[user-gated]` The share extension works on a device.

### Rules
- [x] Rules are stored per agent: 8 categories, each at one of 4 levels, plus a pre-approved list. The owner edits them on the Mac settings page and in the iPhone settings sheet.
- [x] The rules text is in the agent's system prompt.
- [x] A generic `request_approval` tool, with `request_deletion` folded in or kept as a thin case of it, creates Needs you items. "Always allow" adds to the pre-approved list.
- [x] The daemon refuses an unapproved delete or install through its own tools or `exec` when the rule says Ask first, covered by tests.
- [x] The passwords and security category can't be delegated.

### Hands, forms, skills, feedback
- [x] An `ask_for_hands` tool posts a card with the reason. "Take the screen" holds control through `control.ts`; giving it back posts a system line and resumes the agent. Covered by tests.
- [x] A `request_form` tool makes the daemon extract the fields over CDP: label, type, autocomplete, required, options, and the origin from the page.
- [x] The app renders native fields with the right content types (username, password, one-time code). The daemon fills them with `Input.insertText`.
- [x] A test asserts that a secret value never appears in the stored transcript or in any provider request.
- [x] "Remember for this site" stores values encrypted per origin, and they are reused per the rules.
- [x] Fields it can't fill are listed and routed to "Use the agent's screen": cross-origin frames, CAPTCHAs, unknown widgets.
- [x] Secret fields are offered only over HTTPS or loopback; otherwise the flow falls back to the screen. Covered by tests.
- [x] "Show the agent how" records a takeover session (input events and screenshots). The agent turns it into a skill file under its home, and the skill can become a routine.
- [x] Thumbs up or down with an optional reason is stored per message. Down-feedback reaches `MEMORY.md`, directly or through idle work. Covered by a test.

### Idle work
- [x] Per-agent idle settings: on or off, pre-check conditions (new messages, feedback, `MEMORY.md` size, stale files), daily token budget, turn cap, model from the registry, time window.
- [x] Pre-checks run without a model call. A test asserts that no provider request happens when no condition matches.
- [x] Idle passes cannot send, delete, spend or install; a test covers it. Their outputs are memory diffs with undo, routine suggestions, read-only notes, and cleanup proposals through delete requests.
- [x] Back-off after 3 dismissed notes, and a pass with no output is logged as wasted.
- [x] The "Last night" digest shows each output, and "didn't run, 0 tokens" for agents whose pre-check failed.

### Triggers
- [x] The agent has a `propose_trigger` tool with kinds webhook, watched folder, IMAP poll and check command, plus cron. It shows a card in the chat that the owner turns on, followed by a guided test that the agent confirms when it fires.
- [x] A webhook gets an unguessable URL and a secret. IMAP credentials arrive through the form flow and are stored encrypted. Each trigger has a rate limit.
- [x] Each kind fires a turn in the agent's thread. Covered by tests: the webhook route, the folder watcher, the check command firing on changed output, IMAP against a fake server or a stub.
- [x] Triggers are listed with routines in the agent's settings and inspector.
- [ ] `[user-gated]` A live IMAP mailbox triggers an agent.

### Goals and helpers
- [x] A goal entity has a title, a lead agent, plan steps with an owner and state (maintained by the lead through a tool), results, and "next from you". Goal pages exist on Mac and iPhone; the sidebar and home show progress rings.
- [x] The lead agent can add helpers of either kind and decides which: a worker on its account with its own Xvnc display, or a temporary agent with its own user and desktop. The daemon records the kind, and the goal page shows the reason.
- [x] Helpers show the parent's colour with a dashed outline and "For this goal". They are removed when the goal is done, and "Keep as agent" promotes one.
- [x] Tests cover creating a goal, updating steps, adding both helper kinds, finishing the goal and cleaning up.

### Creating, restoring, forwarding
- [x] New agent from a description: the model suggests a name, label, bloub look, starting rules and first routine, all editable. Creation starts the desktop in the background while the interview runs.
- [x] Workspace snapshots are taken before each turn and kept for 7 days.
- [x] The Restore and Retry confirmation offers "Put the files back too", lists the file changes, and lists actions that can't be taken back (sent messages, payments). Restoring files posts a line the agent sees.
- [x] Tests cover snapshot, restore and the list of things that can't be undone.
- [x] Forward: a context-menu "Send to" on a message or file lists agents by name and label, takes a note, and starts a turn in the target with the file and the source message. Covered by a test.

### Recovery
- [x] Browser watchdog: a hung Chromium is restarted once automatically. After that, the chat card offers Restart browser, Restart desktop and retry, or Look at the screen.
- [x] Model 429 and 5xx errors retry automatically with backoff (up to 5 attempts). The card shows the attempt, Retry now, and Use backup model when a backup exists. After the last attempt the item lands in Needs you.
- [x] A 401 skips the retries and appears once in Needs you for all agents, with a link to provider settings.
- [x] Tests use `provider-stub.py` or an in-process stub for 429, 5xx and 401.

### Search
- [x] `POST /api/search` takes a question. The model turns it into filters: type, agent, date range, words. Without a model, it falls back to plain text search.
- [x] SQLite FTS5 indexes messages, workspace files (name, path, agent, time) and screenshot OCR text from tesseract, which is in `infra/install.sh`.
- [x] Results carry an "understood as" list and provenance for each hit. ⌘K on the Mac and the iPhone search field show them.
- [x] A test answers "that PDF Ledger downloaded 3 days ago" against fixture data.

### Models
- [x] The model registry has CRUD routes and a Settings UI: any number of models, each with endpoint, key (encrypted, never echoed back), model id and extra fields.
- [x] Per-agent assignment, a default and a backup exist. The loop, idle work and recovery all resolve their model through the registry.
- [x] A migration moves the existing `provider.*` settings into the first entry as the default, covered by a test.

### Everything
- [x] `pnpm check`, `pnpm test` and `xcodebuild test` (macOS and the iPhone 17 simulator) pass. — note: slice 35 ran the iOS suite (203) and a macOS build only; the macOS test host last passed in slice 33 (204), no Swift change since.
- [x] `infra/smoke.sh` passes twice in a row and covers Needs you, approvals, the rules refusal, a webhook trigger, search and the model registry.
- [x] Migrations are generated with `pnpm migrations`, and a fresh database and an upgraded one both boot.
- [x] `docs/architecture.md`, `docs/configuration.md`, `docs/development.md` and `apple/README.md` describe the new routes, tools, settings and targets.
- [ ] `[user-gated]` An end-to-end run on the owner's server with a real model endpoint: an agent hits a login and the form flow fills it, a payment approval from the lock screen, and a trigger firing overnight with a "Last night" digest in the morning.

## Open questions
None.
