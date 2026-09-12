# Progress — apple-app

## Current state

A SwiftUI app under `apple/` covering every route the web UI calls: connect, setup and silent
Keychain re-login; the agent list; every thread with paging, polling and collapsed tool rows; the
bloub avatar driven by agent state; an RFB client with take/return control; routines, activity,
settings, plugins; three columns on macOS and iPad regular width. Both destinations build clean and
`xcodebuild test` passes 83 tests on each. **Open:** only the two `[user-gated]` items.

**Invariants future slices must respect**
- No daemon API changes and no web UI changes. Polling is the contract.
- `Api/Types.swift` mirrors `shared/src/index.ts` one to one; merged bodies live by the client.
- `Bloub/` and `Vnc/` are `nonisolated`; the rest is `@MainActor` by default, **file-scope
  `private func` and `private let` included**. New build settings go on the **target**.
- A thread is named by `ThreadSource`; its `key` is the chat's identity. **A `List` flattens every
  row into one identity space**: give each row an id that cannot collide.
- Local state (looks, last-seen) lives on `RootView`; `Session` owns server, auth and the 401 retry.
- **One Keychain item per daemon**, keyed by the client's base URL; `reLogin` reads only the
  connected daemon's. The legacy unscoped item is dropped in `Keychain.save`, never at launch.
- **`Engine.swift` and `States.swift` stay as ported.** `BloubPlayer` loops a held `comet` or
  `orbit` round its measured `heldLoop` with `reset`, never under Reduce Motion.
- A row with text and calls is a bubble plus a tool line. **The divider is the first row past `mark`;
  only a send from this app moves `mark`**. Never infer the owner from a row: a routine firing is one.
- **`RfbClient` writes input only while `hold(true)` has been called.** A SwiftUI control over an
  `NSViewRepresentable` also clicks the view under it on macOS.
- **One socket per agent desktop.** The inspector's `DesktopLink` is lent to the full desktop; the
  inspector's content is built only while `roomy && inspecting`. macOS has no File ▸ New Window.
- **`cadence(_:)` answers nil rather than guess.** A stored key is never shown and a blank key never
  sent; Save exists only after the `GET`; the MCP box starts empty; typed JSON goes through `typedJSON`.
- **Glass and materials fall back by themselves** under Reduce Transparency: add none of our own.
  Colour meets the scheme in `BloubColorId.rgb(dark:)` (ink on dark, cream on light), nowhere else.
- Mac only: with the inspector open a window stops at about 2 × sidebar + 320 (the 240 ideal keeps it
  under 800); a `Form` field in `LabeledContent` gets `.rowField()`; sheet minimum sizes are Mac-only.

**Key files**
- `apple/project.yml` — XcodeGen; one app target for iOS and macOS, plus a test target.
- `Api/` — `SchermesClient` (every route, settings types, `typedJSON`), `Types`, `Thread`, `Readable`.
- `Session.swift` — auth phase, server address, Keychain. `Unread.swift` — last-seen per thread.
- `Views/` — `Entry`, `ConsoleView` (sidebar, bottom band, inspector), `ChatView`, `Inspector`,
  `Avatar`, `Routines`, `Activity` (+ `AgentPages`), `Settings` (+ `rowField`).
- `Bloub/` — engine port, `BloubView` (+ `rgb(dark:)`), state table + `BloubPlayer`, picker, board.
- `Vnc/` — `RfbClient`, `Framebuffer`, `Keysym`, `DesktopInput`, `DesktopView` (+ `DesktopLink`).

## Slice 1 — the thinnest end-to-end path (2026-09-11)

A multiplatform SwiftUI app under `apple/` that connects to a daemon, gets the owner in, lists
agents and reads and sends messages in an agent's own thread. Built and run against a real daemon
on both destinations.

### What was built

- `apple/project.yml` — XcodeGen, one `Schermes` application target with
  `supportedDestinations: [iOS, macOS]`, a `SchermesTests` unit-test target, Swift 6 with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, ATS opened with the reason in the plist comment.
  `apple/.gitignore` hides the generated project and DerivedData. `apple/README.md` carries the
  build commands, the ATS note, the session and Keychain rules and the layout.
- `Schermes/Api/Types.swift` — `Codable` mirrors of every type in `shared/src/index.ts`.
- `Schermes/Api/SchermesClient.swift` — base URL, shared cookie storage, JSON in and out, the
  `{error}` envelope thrown as `SchermesError.daemon`, 401 as `SchermesError.unauthorized`.
  Methods: health, setup, login, logout, agents, createAgent, messages, send, live.
- `Schermes/Api/Thread.swift` — `merge`, `atStart`, `oldestId`, `newestId`, `isOrphanTool`,
  `toolName(for:in:)`, and the `AgentState` label and `busy` table, mirroring `ui/src/thread.ts`.
- `Schermes/Session.swift` — `@Observable`; owns the server address (UserDefaults), the password
  (Keychain) and the auth phase, and is the one place a 401 is answered.
- `Schermes/Views/` — connect, setup/login gate, agent list as conversation rows inside a
  `NavigationSplitView`, create-agent sheet, and the chat.
- `SchermesTests/` — 24 tests: the wire shapes decoded from JSON literals, and the thread helpers
  against the same cases as `ui/src/thread.test.ts`.

### Decisions worth carrying forward

- **Signing is ad-hoc and must sit on the target, not the project.** XcodeGen writes
  `CODE_SIGN_IDENTITY = "iPhone Developer"` onto every iOS-capable target, and a target setting
  beats a project one, so a project-level override is silently ignored and the macOS build fails
  asking for a team.
- **`TEST_HOST` needs a macOS override.** XcodeGen emits the iOS shape
  (`…/Schermes.app/Schermes`); a Mac app keeps its executable at `…/Schermes.app/Contents/MacOS/`.
  `TEST_HOST[sdk=macosx*]` fixes it.
- **`@Observable` cannot see `Self` in a stored-property initializer.** The UserDefaults key had
  to move to a file-level constant.
- **The daemon's session cookie carries an expiry**, so `HTTPCookieStorage` persists it and a
  relaunch is still logged in. The Keychain re-login is the backstop for a session that aged out,
  not the normal path.
- **Never route an auth route through `Session.run`.** `POST /api/auth/login` answers 401 for a
  wrong password, so a blanket 401 retry would loop. One retry, guarded routes only.
- **Success is the whole 2xx range**: setup 201, create 201, send 202 wrapped as `{message: …}`.
- **The screenshot rides on a `tool`-role message**, not a following one, despite what the tool
  result's own text says. Collapsing tool rows blindly hides it; `ToolRow` renders the image
  outside the disclosure.
- **Bubble colours must be concrete.** `.background(.primary)` under `.foregroundStyle(.background)`
  resolves both against the same environment, so the owner bubble painted itself invisible. Two
  explicit colours keyed off `colorScheme` instead.
- **Scroll position is anchored, not driven.** `.defaultScrollAnchor(.bottom)` plus
  `.defaultScrollAnchor(.bottom, for: .sizeChanges)` opens at the newest row, stays there as a
  reply lands, and leaves the reader put when an older page is prepended. A `ScrollViewReader`
  doing it by hand raced the first load.
- **The live-reply loop is keyed on the whole `Agent`** (`.task(id: agent)`) so it restarts with a
  fresh state each list poll; the message loop is keyed on `agent.name` so a state change does not
  re-read the thread.
- **`ChatView` carries `.id(current.name)`**, the same guard the web UI writes as
  `<Chat key={agent.name}>`. Without it SwiftUI keeps one view across a sidebar switch: `loaded`
  is replaced by the reload but `draft` and `trouble` are not, so a half-typed message would be
  sent to whichever agent was picked next.
- **A torn-down poll throws `URLError.cancelled`, not `CancellationError`**, so `catch is
  CancellationError` never fires and every thread switch would have flashed a cancellation
  message. `Error.isCancellation` covers both.
- **The Keychain read must not run on the main actor.** `SecItemCopyMatching` can block
  indefinitely — macOS puts an authorisation panel in front of it for an app whose code signature
  it does not recognise, which is every ad-hoc build — and it froze the app on its spinner when it
  happened. `Keychain` is `nonisolated` and `reLogin` reads it from a detached task.
  What triggered the block was never pinned down: the item that hung was seeded by the `security`
  CLI, so it may have been that foreign ownership rather than the signature. The known ceiling
  either way is that if it *is* the signature, an owner who rebuilds gets an authorisation panel
  and, on dismissing it, quietly lands on the login screen. The app now survives it; making it
  never happen would mean the data-protection keychain, which needs real signing.
- `apple/Schermes/Info.plist` is written by XcodeGen from `project.yml` and is gitignored with the
  generated project, for the same reason.
- `ComputerAction` is mirrored as a flat struct rather than a Swift enum with associated values:
  the daemon parses flat fields off one object and `encodeIfPresent` omits what an action lacks.
  `ExecutionEvent.data` uses a small `JSONValue` enum. Neither is used by a slice-1 view.

### Verified

Both destinations build clean (zero compiler warnings; the one `warning:` line in the log is
`appintentsmetadataprocessor` noise from the toolchain, not a diagnostic) and `xcodebuild test`
passes 24 tests on each.

Against a real daemon (a disposable container on `:7778` from the same image, since the harness
volume on `:7777` has an owner whose password is not known here):

- Mac app: connect screen → health → setup screen → password set → agent list → created `scout`
  through the app → sent a message from the composer → the scripted provider's full turn arrived
  by poll with the screenshot inline, tool rows collapsed to one line each named after their call,
  the owner bubble right and the agent bubble left, and a date separator.
- Mid-turn the sidebar row and the toolbar pill both showed `using the terminal` with an orange
  dot, then returned to `waiting for you`.
- With 64 messages in the thread the app opened on the newest 50 and, on scrolling to the top,
  pulled the older page back to message id 1.
- iOS simulator (iPhone 17, iOS 26.5): reached the same daemon over plain HTTP, logged in, showed
  the compact agent list with preview, time and state dot, and pushed the same chat view.
- With two agents, switching between them in the sidebar shows each one's own thread, avatar
  colour and composer placeholder, in both directions and with nothing carried over.
- Silent re-login: every row was deleted from the daemon's `sessions` table under a running app.
  It never reached the login screen, and the daemon had exactly one new session ten seconds later
  — the one the app minted from the Keychain password.
- `git status --untracked-files=all apple/` lists only sources; the generated project,
  `Info.plist` and DerivedData are ignored.

### Not verified

- **The streaming live reply.** `infra/provider-stub.py` answers instantly, so `/live` is only
  non-empty for a few milliseconds and the `LiveRow` could not be caught on screen. The poll and
  the row are implemented; seeing them needs a real provider.
- Reduce Transparency and Reduce Motion, a physical iPhone, and window resizing down to 800x600.

### Housekeeping

- `xcrun simctl create 'iPhone 17' …` was run, because only `iPhone 17 Pro` existed and the
  Definition of Done names the plain device. The command is in `apple/README.md`.
- The Docker VM disk was at 0 bytes free and the daemon was crash-looping on
  `SQLITE_IOERR_SHMSIZE`. Only dangling **build cache** was pruned (5.3 GB, derived state); no
  image and no volume was touched. The `schermes` container on `:7777` is healthy and left
  running.
- The disposable `schermes-verify` container and its volume, the app's UserDefaults, its Keychain
  entry and the simulator install were all removed afterwards.

## Slice 2 — the avatar (2026-09-11)

bloub's engine ported to Swift, rendered in a `Canvas`, driven by the agent's state, with a shape
and a colour per agent that survive a relaunch. The placeholder circle is gone from the list, the
chat pill and the create sheet.

### What was built

`apple/Schermes/Bloub/`, a port of `src/bot/{math,repere,profiles,shape,face,expressions,decor,
states,skins,eyefit,engine}.ts` from `github.com/jeremy-prt/bloub` at
`b4bb3c1b5f93c7b87a2e8d620f667c4093d97749` (MIT). `cycles` skipped, as scoped.

- `Math.swift` — clamps, easings, `loopNoise`, and mulberry32 reproduced with truncating 32-bit
  arithmetic, because the seeded ring, particle and blink tables are only reproducible if it is.
- `Tables.swift` — generated. The three measured profiles, the eight customiser shapes, the two
  `!` bars and the teardrop.
- `Shape.swift`, `Face.swift`, `Expressions.swift`, `Decor.swift`, `States.swift` — the geometry,
  the sphere the eyes live on, the sixteen resting expressions, the orbit and comet seeds, and the
  fifteen state definitions.
- `Eyefit.swift` — the eye-offset solver, run once on first use and cached in a `static let`.
- `Engine.swift` — `BloubEngine.sample(_:)`, a pure function of time, yielding a `BloubFrame` of
  points, eye transforms and arc polylines.
- `BloubView.swift` — `Canvas` inside `TimelineView(.animation)`, or frozen at a given second.
- `AgentBloub.swift` — the `AgentState` → `BloubStateId` table, `BloubIdentity`, and `AgentLooks`.
- `BloubPicker.swift` — the shape and colour rows, and the sheet behind the chat pill.
- `BloubBoard.swift` — the fifteen states side by side, over any shape and colour. Debug only,
  behind a **States** button under the agent list.
- `SchermesTests/BloubGoldens.swift` + `BloubTests.swift` — 18 new tests.

### Decisions worth carrying forward

- **The engine yields geometry, not path strings.** bloub's `sample` returns SVG `d` attributes
  and a `matrix(...)`; the port returns `[CGPoint]` and a `CGAffineTransform`, and `closedPath`
  becomes a `Path` builder in the view. No golden is lost by this: bloub's own tests measure the
  path's *anchors*, which are exactly the 64 points of `toPoints` rounded to two decimals.
- **The goldens are bloub's own numbers.** `BloubGoldens.swift` is a JSON literal dumped by running
  bloub's TypeScript at the ported commit (`npx tsx` over a script in a scratch clone — the sources
  import relatively, so no config is needed). Body outlines, eye transforms, dot positions, arc
  geometry with its front/back depth split and gradient stops, and the whole eye-offset table are
  asserted against it. Tolerance is 0.01 wherever a value came through a rounded path string.
- **The customiser's shapes are baked, not generated.** In bloub they are built at import time by
  `superellipseProfile`, `regularPolygonProfile`, `unionOfCirclesProfile` and `hullOfCircles`, with
  specific step counts. `skins.ts` says outright they are analytic, not measured, so the port
  embeds their 8 x 64 results and carries none of those generators. The eyefit *solver*, by
  contrast, is ported rather than baked — baking it would have made the golden a constant compared
  with itself, and that table is the one thing a port can get wrong invisibly.
- **`decalageDesYeux` keys by array reference in bloub; the port keys by `BloubShapeId`.** Swift
  arrays are values, so an identity lookup is not available and would silently return zero — which
  is a valid-looking answer that puts the eye back through the edge of a capsule or a droplet.
- **`setLook` is deliberately not ported.** Nothing in this app aims the gaze, and with no target
  its whole contribution reduces to the resting drift that is kept. Port it back from `engine.ts`
  if a later slice wants the avatar to follow the cursor.
- **The eyes are holes, so the body needs an opaque backing.** `GraphicsContext.drawLayer` with
  `blendMode = .destinationOut` punches the eyes and the notification notch out of the body; a fill
  in `paper` goes underneath first, or the back half of the orbit rings shows through the eyes.
- **Everything under `Bloub/` is `nonisolated`.** The target sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which also applies to file-scope `private func` and
  `private let` — those need the annotation individually, not just the types.
- **A large struct literal built from `Double(i)` arithmetic times out the type checker.** The
  swoosh seeds needed `let i = Double(index)` hoisted out. Watch for this in any further port.
- **Reduce Motion holds the decor, not the clock.** `sample(_:decorStill:)` renders the arcs at
  their phase origin while the morph, the blink and the drift keep running, which is what "keeps
  the morph and drops the decor motion" has to mean — freezing time would stop the morph too.
- **The eyefit table is cheap.** 8 shapes x 37 entries solved with 12 directions and 8 bisections
  each, inside a test run that finishes in 0.23 s. No warm-up task is needed; `static let` is lazy
  and thread safe and that is the whole mechanism.
- `AgentLooks` lives on `RootView` and goes down through `.environment`, not on `Session`: an
  agent keeps its look across a log out.
- **Both sheets carry a macOS-only `minWidth: 500`.** A Mac sheet sizes to its content, and the
  picker's twelve colours need 428 points plus the padding; at 320 the last swatch was drawn half
  off the edge. The rows stay in a horizontal `ScrollView` because a phone cannot fit them.
- `BloubStateDef.minDuration` and `BloubEngine.reset` have no caller in the app now that `cycles`
  is skipped. Both are kept as part of the port; `reset` has its own test.

### Verified

Both destinations build with zero compiler diagnostics on our sources and `xcodebuild test` passes
42 tests on each.

Against a disposable container on `:7781` from the existing image (no rebuild), with the scripted
provider inside it and a `sleep 12` command to park a turn:

- The **state board** renders all fifteen states, and they match bloub's reference board: the three
  pulsing dots, the wink's dash, the tilted `!` with its teardrop, `notify`'s badge with the notch
  cut out of the body, the six gradient orbit rings with their front/back depth split, the comet's
  ribbon, `burst`'s particles. Shape and colour pickers reach all 8 and all 12.
- Through a real turn `scout`'s row went capsule at rest → a ball with eyes while `using_terminal`
  (the comet, whose silhouette replaces the chosen shape) → capsule with the blue badge at
  `waiting_for_user`. The chat toolbar pill showed the same avatar throughout.
- Eight captures of an idle agent's avatar, 0.45 s apart, are eight different images: it drifts and
  blinks at rest.
- `scout` was changed to a violet droplet through the pill's sheet; the app was quit and relaunched
  and came back a violet droplet, while `archivist`, never chosen for, still showed the teal
  squircle its name derives.
- On a second, empty daemon: the owner was set through the app's own setup screen, then `nomad` was
  created through the create sheet. Typing the name moved the preview through the look that name
  derives (a teal triangle); picking the droplet and violet overrode it; the created row drew a
  violet droplet and `agentLooks` held `{"nomad":{"shape":"droplet","color":"violet"}}`, which came
  back after a relaunch.

### Not verified

- Reduce Motion and Reduce Transparency, a physical iPhone, and the iOS layout beyond the build and
  the test run (slice 1's simulator pass covered the screens, not the avatar).
- The streaming live reply, still, for slice 1's reason.

### Housekeeping

- Docker was **not** rebuilt and nothing was pruned. Disk was already tight (28 GB images, 20 GB
  build cache); the verification container came from the image slice 1 built.
- The disposable `schermes-slice2-verify` container and its volume, the app's UserDefaults and its
  Keychain entry were all removed afterwards. The harness container on `:7777` is untouched.
- Seeding the Keychain with the `security` CLI so the app logs itself in **does** raise the
  authorisation panel slice 1 described. It let the app through once here, but it is not a reliable
  route; a future slice wanting an unattended login should expect to answer that panel by hand.
- `screencapture -l <windowID>` captures the app's window even when another app is in front, which
  is the only way to look at the app without stealing the owner's focus. The window id comes from
  `CGWindowListCopyWindowInfo`.

## Slice 3 — every thread, and a list that looks like the reference (2026-09-11)

Group threads and worker threads, workers nested under their parent, the pinned row of large
avatars, unread state with a "new" divider, and sidebar search.

### What was built

- **`ThreadSource`** in `SchermesClient.swift` — `.agent(name)` or `.conversation(id)`, mirroring
  `Source` in `ui/src/api.ts`. `messages`, `send` and `messagesURL` take one and switch the route;
  `conversations(agent:)` reads `GET /api/agents/:name/conversations`.
- **`ChatThread`** in `ChatView.swift` — `.agent(Agent)` or `.group(id:members:)`. It yields the
  source, the title, the members and `isWorker`, and `ChatView` reads a thread rather than an agent.
- **`Thread.swift`** gained `AgentTree` / `groupAgents` and `sharedConversations`, ported from
  `ui/src/thread.ts`.
- **`Unread.swift`** — `@Observable` over `UserDefaults`, last-seen message id keyed by
  `ThreadSource.key`, alongside `AgentLooks` on `RootView`.
- **`ConsoleView`** rebuilt: selection is a `ThreadSource`; shared threads and a foldable worker
  list nest under each agent; a horizontal row of 58pt avatars sits in a `safeAreaInset(edge:.top)`;
  `.searchable` filters on agent name and last-message preview; rows carry an unread dot.
- **`NewDivider`** in the chat, at the first message above the mark captured on open.
- Five new tests (46 total): nesting, `sharedConversations`, `ThreadSource` keys, the unread rule
  and its persistence, and the conversation route in the URL test.

### Decisions worth carrying forward

- **Agent ids and conversation ids collide.** `scout-w1` had `id: 3` and the shared thread had
  `id: 3`, and a `List` flattens every row into one identity space regardless of which `ForEach`
  emitted it. The symptom was the shared-thread row rendering as a duplicate worker row the moment
  selection changed. `AgentTree.id` is now the agent's **name** and the worker `ForEach` is keyed
  by `\.name`, so the two kinds can never share an id. Any later slice adding a row type to this
  sidebar — schedules, the inspector — walks into this again.
- **The chat's SwiftUI identity is `thread.source`, not the agent's name.** A group thread carries
  the name of one of its members, so keying by name would keep one view across the switch and carry
  a half-typed draft into the other thread. This is slice 1's `<Chat key={…}>` rule, widened.
- **The live reply is agent-only.** `/live` is per agent; a shared thread would have to ask every
  participant. The loop returns early for a group, as `Chat.tsx` does.
- **Shared threads are fetched for one agent at a time, on a 5 s tick**, as the web UI does it.
  Listing them for everybody would be another request per agent on the 2 s poll, on top of the
  previews the OVERVIEW already budgets. Selecting a **worker** expands its parent's subtree, not
  its own.
- **A worker's thread is `.agent(workerName)`.** `parentConversationId` is where a worker reports
  its result, not where its own transcript lives — the field name invites the wrong wiring.
- **A thread nobody has opened is entirely unread.** There is no message id at or below zero, so
  `lastSeen ?? 0` needs no special case and the dot and the divider read one rule. The cost is that
  a fresh install shows a dot on every row, which is accurate rather than broken.
- **The pinned row is a `safeAreaInset`, not a `List` section**, so its avatars stay out of the
  selection binding. It shows every permanent agent: the slice asks for a row, not pin management.
- **The iOS title must be inline.** A large title scrolls under the top inset and reads as a smudge
  behind the pinned row's material.
- `GET /api/agents/:name/conversations` includes the agent's own solo thread; without the
  `sharedConversations` filter every agent grows a row reading "with " and nothing else.

### Verified

Both destinations build with zero compiler diagnostics on our sources and `xcodebuild test` passes
46 tests on each.

Against a disposable container on `:7782` from the existing image (no rebuild), with the stub's
`worker` and then `talk` scripts, giving `scout` a task worker and a thread shared with `archivist`:

- `scout-w1` nests under `scout` behind a "1 task worker" fold, on **both** macOS and iOS. Its
  thread opens and the composer is replaced by the note that a worker reports to its parent.
- The `scout + archivist` thread opens from under `scout`, names every sender, and a message typed
  into it reached the daemon as an owner row that both agents then answered.
- A message posted to `scout` while `archivist`'s thread was open left an unread dot on `scout`'s
  row; opening it drew the "new" divider exactly at that message and cleared the dot.
- A half-typed draft in `scout`'s composer did **not** follow a switch to the group thread.
- Search on `spawn_task_worker` — a string that appears only inside a preview, never in a name —
  kept `scout` and dropped `archivist`; a non-matching term gives `ContentUnavailableView.search`.
- Clicking the untagged worker-fold row does not clear the chat selection.
- The compact iOS layout shows the pinned row, the grouped list, the fold and the search field, and
  pushes the chat with the pill, the bubbles and the glass composer.

### Not verified

- The streaming live reply, still, for slice 1's reason: the stub answers instantly.
- Reduce Motion, Reduce Transparency, and a physical iPhone.
- The pinned avatars animating through a real turn. They are the same `BloubView` slice 2 verified
  in list rows, differing only in `size`.

### Housekeeping

- Docker was **not** rebuilt and nothing was pruned. The verification containers came from the
  image slice 1 built; both were removed with their volumes afterwards, as were the Mac app's
  UserDefaults and Keychain entry and the simulator install. The harness on `:7777` is untouched.
- `set value of` a SwiftUI field through System Events drives it where `keystroke` does not, since
  keystrokes only reach the frontmost app. An outline reference goes stale when the window title
  changes with the selection, so re-resolve it per call.

## Slice 4 — the desktop, view-only (2026-09-11)

A hand-written RFB 3.8 client over the daemon's WebSocket proxy, and an agent's live screen on
iPhone and on Mac. View-only: the client writes no input message of any kind.

### What was built

- **`Vnc/RfbClient.swift`** — `RfbTransport` (a byte pipe: `send`, `receive`, `close`),
  `WebSocketTransport` over `URLSessionWebSocketTask`, and `actor RfbClient`. Handshake, the
  server-message loop, `Raw`, `CopyRect` and `ZRLE`, plus `Inflate` over the SDK's own zlib.
  `SetColourMapEntries`, `Bell` and `ServerCutText` are stepped over rather than parsed, because a
  desynchronised stream is worse than the three lines that skip them.
- **`Vnc/Framebuffer.swift`** — one `CGContext` the rects are written into, `makeImage()` per frame.
- **`Vnc/DesktopView.swift`** — the framebuffer scaled to fit and letterboxed on black, with the
  back chevron and the agent pill over the top left.
- **`SchermesClient.vnc(agent:)`** — the same URL builder, `http`→`ws`, on the same `URLSession`, so
  the daemon's session cookie rides the upgrade. It does; no header had to be set by hand.
- **`ChatView`** — a `display` button in the toolbar for any agent the daemon would give a desktop
  to, opening `DesktopView` in a `fullScreenCover` on iOS and a sheet on macOS.
- **`project.yml`** — `OTHER_LDFLAGS: -lz` on **both** targets: the app for `Inflate`, the test
  target because the ZRLE fixtures are deflated with real zlib rather than pasted as a blob.
- **`SchermesTests/RfbTests.swift`** — seven tests (53 total) against canned byte streams handed
  out in 7-byte chunks, so nothing may assume a message is a frame.

### Decisions worth carrying forward

- **ZRLE, not Tight.** TigerVNC serves both. Tight needs a JPEG decoder, four zlib streams and its
  filters; ZRLE needs no image decoder at all and its five subencodings are about eighty lines.
- **32-bit BGRX is chosen so nothing converts.** `byteOrder32Little` + `noneSkipFirst` lays a pixel
  out as B, G, R, ignored, which is exactly what a `Raw` rect carries and exactly the three bytes a
  ZRLE CPIXEL carries. Xvnc's own log confirms it: *Client pixel format depth 24 (32bpp)
  little-endian rgb888*, the same as its server default, so it converts nothing either.
- **One `z_stream` for the life of the connection.** ZRLE flushes per rect but never ends the
  stream and carries its dictionary across it. Resetting per rect decodes the first rect and then
  garbage, which is why the ZRLE test spans three updates in one stream. `import zlib` resolves
  against the SDK on both platforms; the `Compression` framework was passed over because it only
  does raw DEFLATE, so the zlib header and the flush semantics would have to be hand-rolled.
- **Edge tiles are clipped, not padded.** A 70-wide rect is a 64 tile and a 6 tile, and the packed
  palette pads each row to a byte using the tile's *actual* width. The fixture is 70 wide for this.
- **`CopyRect` rows are walked away from the destination.** A window dragged down over itself
  smears into a repeat of its first row under a naive forward copy; `memmove` per row, bottom-up
  when the destination is below the source.
- **The client task must be a child of the view's `.task`, not an unstructured `Task` beside it.**
  Cancelling it from a `defer` after `for await … in client.events` looks equivalent and is not:
  leaving the desktop left the socket open and Xvnc still had a viewer. `withTaskGroup` with
  `addTask { await client.run() }` makes cancellation reach the client whatever the frame stream is
  doing, and `run()` then closes the socket and finishes the stream, which is what ends the loop.
- **`Error.isCancellation` had to become `nonisolated`.** It is the target's default-MainActor rule
  again: an actor that is not the main one cannot read it otherwise.
- **No pseudo-encodings are requested.** Xvnc is started at a fixed geometry and changing it
  restarts the server, which drops the socket, so `DesktopSize` has nothing to report here.
- **The chrome sits over the picture, not in a toolbar.** A macOS sheet has no toolbar to put a
  `.principal` item in, so the pill vanished there while the back button fell to the sheet's
  bottom edge. An overlay is one code path and is what the reference shows anyway.
- **The desktop is presented, not pushed.** The detail column is not a `NavigationStack`. The
  inspector column on regular width, where this becomes a thumbnail, is a later slice.
- **A task worker has no desktop.** `desktopAgent` in the daemon refuses one, so the toolbar button
  only appears for an agent with no `parentId`.
- **A rect is bounds-checked on its header, before its payload is read.** A rect is up to 65535 on
  a side and its bytes are buffered whole, so checking only on the way into the framebuffer means a
  desynchronised stream can pull gigabytes first. The ZRLE length word gets its own ceiling for the
  same reason.

### Verified

Both destinations build clean and `xcodebuild test` passes 53 tests on each.

Against a disposable container on `:7783` from the existing image (no rebuild), with one agent
`pixel` and two xterms on its display:

- The desktop shows the live screen on **macOS** and in the **iOS simulator**. On macOS it was
  compared against `import -window root` taken inside the container at the same moment, twice, and
  the two pictures match: same wallpaper gradient, same windows in the same places, same dock, same
  clock. The iOS screenshots were read by eye against the same desktop, not diffed against a
  server-side capture.
- **Colours are not swapped.** The xterm is started `-bg '#ffcc00'` and renders amber, not the cyan
  a reversed BGR would give.
- **ZRLE and `CopyRect` are what actually ran**, not just what the tests cover. A rect-by-rect
  log over one session counted 46 ZRLE rects and 4 `CopyRect` rects and no `Raw` at all: TigerVNC
  honours the preference order, and each window drag sent one `CopyRect` of the whole window frame
  (366x263) followed by ZRLE repaints of what it uncovered.
- **A dragged window leaves nothing behind.** Six `xdotool windowmove` hops across the screen, then
  the comparison above: no torn rectangle, no smear, no stale copy of the window. Repeated with
  four more hops on the instrumented run, with the `CopyRect` count above to prove the path.
- **It keeps up.** The dock clock advanced 13:38 → 13:47 across the session and window moves
  appeared immediately.
- **Rescaling is aspect-correct.** The Mac window was resized to 900x1000 and 1700x700 and the
  iPhone rotated to landscape and back; the picture letterboxes and never stretches. Measured on
  the rotated shot, both xterm frames keep the 1.39 ratio their geometry gives.
- **Leaving closes the socket.** Established connections to Xvnc's `127.0.0.1:5901` go 1 → 0 on
  Back, twice in a row on macOS and once on iOS, and Xvnc's own log pairs every `Connections:
  Accepted` with a `Connections: Closed`.

### Not verified

- Reduce Motion, Reduce Transparency, and a physical iPhone — still outstanding from slice 3.
- The `Raw` decoder against a real server. TigerVNC never chose it, because ZRLE is first in the
  preference list and it honours that; `Raw` is covered by tests only. Dropping ZRLE from
  `encodingsMessage` for one run is how to exercise it, and it needs no daemon change — one
  `NSLog` in `readUpdate` is how the encoding counts above were taken.

### Worth knowing

- **The daemon logs `vnc viewer connected` and nothing on close.** `pipe()` in `daemon/src/vnc.ts`
  destroys the socket silently, so the slice's "the daemon logs the viewer disconnecting" cannot be
  read off `docker logs`. Xvnc's `Connections: Closed` line in `/var/lib/schermes/logs/<agent>.log`
  is the evidence instead. Adding the log line would be a daemon change this task does not allow.
- A `SecureField` does not take `set value of` through System Events — the binding never sees it
  and the button stays disabled. Activate the app and `keystroke` instead; plain `TextField` is
  still fine with `set value of`.
- The Simulator forwards the app's accessibility tree, so System Events drives it the same way it
  drives the Mac app. Its window **moves** when the device rotates, so any coordinate-based tap has
  to re-read `position of window 1` rather than cache it.

### Housekeeping

Docker was **not** rebuilt and nothing was pruned. The verification container came from the image
slice 1 built and was removed with its volume, as were the Mac app's UserDefaults and Keychain
entry and the simulator install. The harness on `:7777` is untouched.

## Slice 5 — taking the desktop back (2026-09-11)

Control state and its poll, and the write side of the RFB client behind it: pointer, wheel, three
buttons and a keyboard with X11 keysyms, on iPhone and on Mac.

### What was built

- **`SchermesClient.control(agent:)` / `setControl(agent:held:)`** — `GET`, and `POST` to take and
  `DELETE` to give back, mirroring `api.control` / `api.setControl`. All three answer `{held}`.
- **`viewOnly(_:)` in `Api/Thread.swift`** — the Swift mirror of `ui/src/thread.ts`. Unknown
  ownership is view-only.
- **`RfbClient` gained a write side** — `hold`, `move`, `button`, `release`, `wheel`, `key`, all
  behind one `input(_:)` that refuses to write unless the hold is there. `PointerEvent` (5) and
  `KeyEvent` (4) only; the clipboard is still not bridged, so `ClientCutText` (6) is not written.
- **`Vnc/Keysym.swift`** — Latin-1 as its own code point, the Unicode escape above it, the named
  keys, AppKit's private-use scalars for arrows and function keys, and the HID usages UIKit reports.
- **`framebufferPoint` in `Vnc/Framebuffer.swift`** — the letterbox transform, which answers with
  nothing for a point on the bars rather than with the nearest edge.
- **`Vnc/DesktopInput.swift`** — an `NSView` on macOS (three buttons, wheel, hover, `keyDown`,
  `keyUp`, `flagsChanged`) and a `UIView` on iOS (one finger is the left button, two fingers scroll,
  a two-finger tap is the right button, `UIKeyInput` raises the software keyboard and
  `pressesBegan` carries a hardware one's arrows, escape and chords).
- **`DesktopView`** — the control poll every 4 s, take/return and keyboard buttons, and one ordered
  pipe from a hand to the client.
- **Tests** — 67 now: the keysym table, the letterbox transform both ways, and four on the gate.

### Decisions worth carrying forward

- **The chrome moved off the picture into a `safeAreaInset(edge: .top)` band, reversing slice 4's
  "the chrome sits over the picture, not in a toolbar."** On macOS a click on a SwiftUI control
  drawn above an `NSViewRepresentable` reaches the view underneath as well, so with the chrome
  overlaid every press of Return control also landed a real click on the agent's desktop —
  measured at framebuffer 1626,24, exactly where the button was. UIKit does not do this; AppKit
  does. A band removes the overlap instead of teaching the view where the buttons are.
- **One ordered pipe, not a `Task` per event.** Input reaches the actor through an
  `AsyncStream<@Sendable (RfbClient) async -> Void>` drained by a single task in the view's task
  group. Separate `Task {}` hops onto an actor have no order at all, and a button down and the
  button up that ends it are not interchangeable.
- **The client owns the button mask and the set of pressed keys.** `PointerEvent` carries the whole
  current mask every time, and `hold(false)` can only let go of what is still down if the actor
  knows. It releases *before* the flag flips, while the writes are still allowed.
- **A release with no framebuffer point still happens.** A drag that ends on the letterbox bar has
  nowhere to aim, so `release(_:)` lets the button go where the pointer was last seen. Dropping it
  would leave a button down on a desktop about to be handed back.
- **`charactersIgnoringModifiers`, never `characters`.** Ctrl+C reports `characters` as U+0003,
  which would go out as keysym 3. Shift is still honoured by the former, so a capital arrives as a
  capital beside the Shift press `flagsChanged` sends. Keys are remembered by keycode on the way
  down so a modifier released mid-press cannot change what is released.
- **AppKit sends no `keyUp` while Command is down**, so a Command chord is written as a tap.
  `resignFirstResponder` and the window resigning key both let go of everything, because a stuck
  Command on an agent's screen outlives the window that sent it.
- **On iOS a bare modifier press is swallowed and the chord is synthesised** from the
  `modifierFlags` of the key it modifies, and any key the text input system will deliver as text is
  left to `insertText` so it cannot be typed twice. `Keysym.hid` therefore has no letters, digits,
  Return, Tab or Backspace in it.
- **Escape is conditional.** `.keyboardShortcut(.escape)` on Back is consulted before the key shim
  ever sees the press, so it is removed while control is held and Escape reaches the desktop. A
  `Cmd+Escape` on Return control was tried as a second way out and **does nothing** on macOS 26, so
  it was removed rather than left as a hatch that is not one. The way out while holding is the bar,
  which is now clickable by construction.
- **A failed control poll leaves the last answer standing** rather than replacing it with a guess,
  which is what the web UI does. Take control is disabled while the answer is still unknown.
- **Leaving the desktop does not return the hold.** `control.ts` documents a forgotten hold as
  deliberate and the web UI does the same; diverging here would be a surprise.
- **"Return", not "Return control", on the button.** The full phrase beside the keyboard button is
  wider than an iPhone and wrapped onto two lines; the accessibility label keeps the full phrase.

### Verified

Both destinations build clean and `xcodebuild test` passes 67 tests on each.

Against a disposable container on `:7785` from the existing image (no rebuild), with an agent
`pixel` on a 1920x1200 display, an xterm and an `xev` window:

- **The transform is exact, on both platforms.** On macOS, aiming at framebuffer 960,600 / 426,274
  / 1917,1197 through a 720x450 picture put the agent's pointer on exactly those pixels. On iOS the
  measured scale matched the fit scale on both axes to within a pixel of tap rounding. Taps and
  moves on the letterbox bars moved nothing, above and below the picture and either side of it.
- **A standalone harness linking the real `RfbClient`, `Framebuffer` and `Keysym`** drove the same
  desktop directly: four aim points landed pixel-exact, a point on the bar mapped to nothing, and
  `xev` recorded X11 button 3 for the right button, button 2 for the middle, three button 4 for
  three wheel-up clicks and two button 5 for two down.
- **Typing reaches the focused window, from both apps.** Each key was proved by the file it left
  behind in the container: `Slice5_OK-42` (letters, capitals, digits, underscore, hyphen, `>` and
  `/`), `good` for BackSpace, `ABC` for Left and Right, `tabworks` for Tab completing `ech`, a
  missing file plus `ctrlc` for a Ctrl+C chord abandoning a half-typed line, and `keep` for Escape
  then BackSpace reaching readline as meta-backspace.
- **Hover works on macOS.** A move with no button down put the agent's pointer on the aimed pixel.
- **The middle button goes through the AppKit shim**, not only over the wire: `otherMouseDown` and
  `otherMouseUp` produced X11 button 2 press and release.
- **Two fingers scroll on iOS.** A two-finger drag downward produced six X11 button 4 clicks.
- **A drag that ends on the bar still lets go.** `xev` logged the press inside the picture and the
  release after the finger left it, with button 1 still in the state mask.
- **No input before the hold and none after it.** A move, a click and a line of text sent before
  `hold(true)` moved nothing; the same after returning control moved nothing and left no file. The
  chrome band was clicked sixteen times while holding and the agent's pointer never moved.
- **Leaving still closes the socket.** Xvnc's `Connections: Accepted` and `Connections: Closed`
  counts stayed paired across every open and close, on macOS (Escape) and on iOS (Back).

### Not verified

- **The two-finger tap for the right button on iOS.** The Simulator will not synthesise a
  two-finger tap: a short Option+Shift drag collapses to one touch, and a long enough one is a pan.
  The right button itself is proven on the wire and through the macOS shim; only the gesture that
  asks for it on iOS is untested.
- Reduce Motion, Reduce Transparency, and a physical iPhone — still outstanding from slice 3.
- The `Raw` decoder against a real server — still outstanding from slice 4.

### Worth knowing

- **The first keystrokes after raising the iOS keyboard can be lost** while UIKit installs the
  first responder. Nothing in this code drops them; they never arrive. A person is slower than a
  test harness, so it shows up only under automation.
- **The Mac app exposes no window to the accessibility API**, so System Events and `AXUIElement`
  both see a menu bar and nothing else. Driving it needs synthesised `CGEvent`s at screen
  coordinates read from `CGWindowListCopyWindowInfo`, with the daemon's own API as the oracle for
  whether a click landed.
- **A Keychain item made with `security add-generic-password` puts an authorisation panel in front
  of the app** on first read, and while that panel is up the app answers nothing. `-A` avoids it
  for a throwaway item; delete the item afterwards, because `-A` means any application can read it.
- **The Simulator's `ConnectHardwareKeyboard` decides whether special keys forward at all.** With
  it off, characters reach the device through the software-keyboard translation but Delete, Tab and
  the arrows do not. It also fights Option+Shift, which is how two-finger gestures are synthesised,
  so the keyboard tests and the gesture tests need it set differently.
- **`xev` is in the image and is the way to see what the desktop actually received.** Resize its
  window to cover the screen when the aim is uncertain; X11 button numbers are 1 left, 2 middle,
  3 right, 4 wheel up, 5 wheel down.

### Housekeeping

Docker was **not** rebuilt and nothing was pruned. The verification container came from the image
slice 1 built and was removed with its volume, as were the Mac app's UserDefaults and its Keychain
entry, the simulator install and the `ConnectHardwareKeyboard` default. The harness on `:7777` is
untouched, and `apple/` is still uncommitted, as it was after slices 1 to 4.

## Slice 6 — routines and the activity feed (2026-09-11)

An agent's schedules, called Routines as the reference calls them, and its execution events as
sentences. Both live in one sheet opened from the chat toolbar, and each is a view that stands on
its own so the inspector column can take it later.

### What was built

- **`SchermesClient`** — `events`, `schedules`, `createSchedule`, `pauseSchedule` and
  `deleteSchedule`, with the names `ui/src/api.ts` uses. The slice file asked for
  `addSchedule` / `setSchedulePaused` / `removeSchedule`, which exist nowhere; the web UI's names
  won.
- **`Api/Readable.swift`** — `cadence(_:)`, a cron expression in words or nil, and
  `sentence(for:)`, one line per `ExecutionEvent`.
- **`Views/Routines.swift`** — `RoutinesView`. Each routine shows its cadence in words above the
  expression, its prompt, and "Next … · last ran …" (or "not run yet", or "Paused"), with a
  switch that is on while it runs and Delete on a swipe and in the context menu. The New routine
  form's cron field reads itself back in words as it is typed. Polled every 5 s, as
  `ui/src/Schedules.tsx` does it.
- **`Views/Activity.swift`** — `ActivityView`, newest first with a symbol per event type and the
  time, polled every 4 s while on screen. Also `RoutinesAndActivity`, the sheet with a segmented
  Routines / Activity control.
- **`ChatView`** — a `clock.arrow.circlepath` button beside Screen, for permanent agents only.
- **`SchermesTests/ReadableTests.swift`** — three tests (70 in total): 38 cron readings, 16
  expressions that must read as nil, and 30 events mapped to sentences.
- `apple/README.md` layout lines.

### Decisions worth carrying forward

- **Nil beats a near miss.** Each field is expanded to the set of values it matches and the sets
  are described. "Every n minutes" is said only when the set is evenly spaced round the whole hour:
  `*/7` has a four-minute gap at the top of the hour, so it reads as nil. Up to four clock times
  are listed. Seconds must be 0 and the year `*`; `L`, `W`, `#`, `?` and `+` all read as nil. The
  row then shows the bare expression, with no empty line where the words would be.
- **croner's day rule was measured, not assumed.** Day-of-month and day-of-week are either-or only
  when neither is a bare `*`: `0 9 1 * 1` fires on the 1st and on Mondays, and `1-31 * 1` and
  `*/1 * 1` fire every day. `? * 1` also fires every day, because `?` is not `*` to croner. croner
  10 refuses `5/15` and wrap-around ranges like `FRI-MON`, takes names in any case and `7` for
  Sunday, and takes an ISO timestamp as a one-shot, which `parseSchedule` will store. Every reading
  in the tests was checked against `new Cron(p).nextRuns()` from the daemon's own `node_modules`.
- **A tool result carries no tool name**, so its sentence comes from which fields are present. The
  three schedule tools' results differ only by `cron`, `paused` or neither, and are asked about in
  that order.
- **Each change applies the row the daemon answered with** rather than re-fetching, so the switch
  never flicks back while a list is in flight. The poll picks up what the agent itself changes.
- **One sheet, two pages behind a `switch`**, so the page that is not showing is torn down and its
  poll stops. The segmented control sits in a `safeAreaInset` band, not the toolbar, because a
  macOS sheet has no `.principal` slot (slice 4 met this). Done is a `.confirmationAction`, which a
  Mac sheet puts at the bottom right.
- **Only a permanent agent gets the button**, the same gate as Screen. The web UI gives a task
  worker neither a schedules tab nor an activity feed, and a worker cannot hold a schedule through
  its tools.
- **The cron is on the daemon's clock and the next run is on the viewer's.** The harness runs in
  UTC, so "on weekdays at 09:00" beside "Next 14 Sep 2026 at 11:00" is right in CEST. The app cannot
  know a daemon's zone, so the form's footer says that rather than naming one.
- **English lists are joined by hand.** `ListFormatStyle` follows the device's locale and would put
  a Dutch "en" in the middle of an English sentence.
- The events route is not paged; the feed keeps the newest 200 (a `ponytail:` note in
  `Activity.swift`).
- The prompt field keeps autocorrect, since it is prose. The cron field turns autocorrect and
  capitalisation off and asks for the numbers-and-punctuation keyboard on iOS.

### Verified

Both destinations build with zero compiler diagnostics on our sources and `xcodebuild test` passes
70 tests on each.

Against a disposable container on `:7786` from the existing image (no rebuild), with
`infra/provider-stub.py` as the provider and one agent, `scout`:

- **Through the iOS app, with the daemon as the oracle.** A routine added as `0 9 * * 1-5` appeared
  in `GET /api/agents/scout/schedules` with no `lastRunAt`. Its switch set `paused: true` and the
  row read "Paused · not run yet". Switching it back cleared `paused` and the row read "Next 14 Sep
  2026 at 11:00 · not run yet". A swipe revealed Delete, and pressing it took the row off the
  daemon and off the list.
- **Both kinds of row read correctly.** A `* * * * *` routine that had fired read "every minute …
  Next 11 Sep 2026 at 19:22 · last ran 11 Sep 2026 at 19:21", and the new one "on weekdays at
  09:00 … not run yet". The form showed "on weekdays at 09:00" as soon as the cron was typed.
- **The feed shows real events as sentences, newest first, and picks up new ones by poll.** With
  Activity open, `POST` then `DELETE /api/agents/scout/control` made two `control` events. Within
  one 4 s tick they sat at the top as "You gave the mouse and keyboard back" above "You took the
  mouse and keyboard", over the turn's "Now thinking" / "Now waiting for you" lines.
- **macOS.** The toolbar button opens the sheet. Routines shows the same rows and form in dark
  mode, and Activity lists the same sentences newest first. Driven with cua-driver in the
  background.

### Not verified

Runtime-unverified:

- **The pause switch on macOS.** cua-driver's element click did nothing: it sees the switch as an
  `AXCheckBox` whose only action is `showmenu`. A background pixel click did nothing either, but
  its aim was never confirmed. The capture is 1568x1066 for a 1000x680 pt window, and the click's
  coordinate space may not be the capture's. So this is no evidence the switch refuses a real
  click. A foreground click would have needed the owner's approval. The same `RoutineRow` switch
  works on iOS, and the Mac's row context menu has Pause / Resume, also not driven.
- Swipe-to-delete on the Mac (trackpad only), and the context menus on both platforms.
- Tool-call and tool-result lines on screen. They are in the feed's data from the stub's first
  turn, but further down than was scrolled to; the fixture test covers the mapping. `restart` and
  `schedule_dropped` are fixture-only.
- The hidden page's poll stopping. It is true by construction (a `switch` tears the page down), but
  it was not measured, because the daemon does not log requests.
- The daemon's refusal under the Add button. After the live run it was moved there from a section
  of its own, which a phone draws below the fold. The build and tests cover it; it was not seen
  on screen.
- Still outstanding from earlier slices: the streaming live reply, Reduce Motion, Reduce
  Transparency, a physical iPhone, the `Raw` decoder, and the iOS two-finger tap.

Placeholder choices:

- "Routines and activity" as the toolbar button's label and `clock.arrow.circlepath` as its
  symbol; "Routines" and "Activity" as the two pages.
- A switch that is on while a routine runs (the alarm list's convention) rather than a Pause button.
- 24-hour clock times in the cadence, to match the expression beside it; next and last runs in
  the device's own date format.
- The copy: "Nothing scheduled.", the footer under the list (adapted from the web UI's), "A cron is
  read on the daemon's clock. Next runs are shown on yours.", and the prompt placeholder (from
  the daemon's own tool description).
- Every event sentence ("Now thinking", "Ran “…”", "Got the screenshot", "Done" for a result with
  nothing more to say) and the SF Symbol for each event type.
- The feed's cap of 200 rows.

### Worth knowing

- **`GroupRow` in `ConsoleView.swift` builds "with a and b" with `ListFormatStyle`**, so it will
  read "with a en b" on a Dutch device. Not touched here.
- **iOS 26's switch ignores idb's zero-length tap.** `idb ui tap --duration 0.2` works.
- **The Mac app is fully visible to cua-driver**, sheets included, even though System Events saw
  only a menu bar in slice 5. `click` needs a `snapshot_id` with the index, and its JSON needs
  Python's `strict=False` because it carries raw control characters.
- **The SwiftUI switch lists no press action to cua-driver on macOS.** Worth a VoiceOver check in
  the accessibility pass, since VO-Space normally performs `AXPress`. It is a question, not a
  finding: nothing here showed the switch refusing a real click.
- A schedule firing writes an owner-role row ("Scheduled task N (…) is due"), so it shows in the
  chat as an owner bubble. That is the daemon's design, documented in `schedules.ts`.

### Housekeeping

Docker was **not** rebuilt and nothing was pruned. The disposable `schermes-slice6` container and
its volume were removed, and so were the simulator install, the scratch DerivedData and the Mac
app's `-A` Keychain item. The Mac app's UserDefaults were put back by deleting the domain and
importing an export taken before the run: `defaults import` alone merges, and left the run's
address and last-seen map behind until the domain was deleted first. The
harness on `:7777` is untouched, and `apple/` is still uncommitted, as it was after slices 1 to 5.

## Slice 7 — settings and plugins (2026-09-11)

The last thing the web UI did that the app could not: the provider, web search, and the MCP
servers with the per-agent connection test, behind a gear and a Plugins row at the bottom of the
sidebar. The app now calls every route the web UI calls.

### What was built

- **`Api/SchermesClient.swift`** — `settings`, `saveSettings`, `mcpServers`, `saveMcpServers` and
  `testMcpServer` (both path segments escaped). `DaemonSettings` and `DaemonSettingsUpdate` read
  and write the provider half and the web half as one object, which is `Settings` in
  `ui/src/api.ts`. `SettingsForm` is what the screen edits; its `update` is `settingsUpdate`.
  `mcpServers(fromDraft:)` parses the box, `typedJSON` straightens keyboard quotes, and
  `SchermesError.notJSON` carries a parse error.
- **`Views/Settings.swift`** — `SettingsView` (provider, extra request fields, web search, one
  Save) and `PluginsView` (each configured server with a Test button and its result, Test as, and
  the replace-the-list box), plus `McpTestResult.report`.
- **`ConsoleView`** — the bottom band is a Plugins row above Log out, States and the gear (icon
  only, Cmd+,). The two new sheets and the debug board all go through one `.sheet(item: $panel)`.
- **`SchermesTests/SettingsTests.swift`** — seven tests (77 in total).
- `apple/README.md` layout line. `Api/Types.swift` needed no change: its four settings mirrors
  already matched `shared`.

### Decisions worth carrying forward

- **Save exists only after the `GET`.** The form is a `SettingsForm?` built from the daemon's
  answer. Every non-key field goes on every save, because empty is how a search endpoint or an
  extra body is cleared, so a save from an unloaded form would blank everything stored.
  `ui/src/Settings.tsx` has exactly that hole: its save button is live before `api.settings()`
  returns. Save is also disabled while the form equals what is stored.
- **A blank key is left out, and a successful save rebuilds the form from the answer**, so both
  key fields come back empty with "Stored" as their placeholder.
- **A successful MCP save clears the box.** The web UI leaves the typed secrets on screen; the
  app does not. A refusal leaves the box as typed, to be fixed. The box never starts filled, for
  the reason the web UI gives.
- **The iOS keyboard turns `"` into curly quotes, and SwiftUI has no `smartQuotesType`.**
  Measured: `["x"]` typed into the extra-body field arrived as `[“x”]`, and a typed MCP list
  arrived curly throughout. `typedJSON` straightens `“ ” „ ‟` only when the raw text does not
  parse and the straightened text does, so a curly quote inside a valid string value is left
  alone and text that is wrong either way reaches the daemon as typed, to be refused in its words.
- **`JSONDecoder` into `JSONValue`, not `JSONSerialization`**: the result is `Encodable`, so the
  body is `["servers": value]` with no raw-data path in the client. Both accept a trailing comma,
  which is harmless because the body is re-encoded. A syntax error's `NSDebugDescription` names
  the line and column.
- **A test runs as a permanent agent**, the first by default: a stdio server starts as that
  agent's Linux user and a worker has none. A thrown error from the route (no such agent or
  server) is shown on the row like a failed test.
- **The debug board moved into the same `Panel` enum**, so Debug and Release builds carry the
  same sheet modifiers and a sheet cannot silently fail to open in one of them.
- **`LabeledContent` rows on iOS.** A `TextField` in an iOS `Form` shows only its prompt, so a
  filled field would lose its name.
- `DaemonSettings`, not `Settings`: that name would shadow SwiftUI's `Settings` scene.

### Verified

Both destinations build with zero compiler diagnostics on our sources and `xcodebuild test` passes
77 tests on each.

Against a disposable container on `:7787` from the existing image (no rebuild), with one agent
`scout`, through the **iOS simulator** app:

- The sidebar shows the Plugins row and the band (Log out, States, gear) above the search field.
- A provider saved in the app (`http://127.0.0.1:9/v1`, `stub-model`, a typed key) appeared in
  `GET /api/settings` with `apiKeySet: true`. The key field came back empty with "Stored" as its
  placeholder, and "Saved." showed under the button.
- Saving again with the key field blank, the model changed and a web search endpoint and key
  added, kept `apiKeySet: true` and set `searchUrl` and `searchKeySet: true`. Both key fields read
  "Stored".
- `["x"]` in Extra request fields showed "extraBody must be a JSON object" in red under Save,
  visible without scrolling, and `GET /api/settings` was unchanged.
- `{"reasoning":{"effort":"low"}}` typed (arriving curly) was stored as straight JSON by a save
  with both key fields blank, and both keys stayed set.
- An MCP list typed into the box (curly throughout), with a Python stdio stub and a server whose
  command does not exist, appeared in `GET /api/mcp/servers` and the box emptied. Testing as
  `scout` gave "2 tools: mcp__stub__clock, mcp__stub__echo" for the stub and
  "MCP error -32000: Connection closed" for the broken one.
- Saving the box empty showed "Saved." and left `[]` (by accident, when a tap missed the editor).

### Not verified

Runtime-unverified:

- **The Mac app, live.** Seeding its Keychain item (`security add-generic-password -A`) and its
  address (`defaults write`) was refused by this session's permission classifier as unauthorized
  persistence, and the cua-driver permission check in the same batch with it, so the Mac sheets
  were never opened. Both build and pass their tests on macOS and every view is shared. To check:
  log the Mac app in to a disposable daemon, open the gear (or Cmd+,) and Plugins, and repeat the
  iOS steps above.
- Whether macOS curls quotes too. `typedJSON` covers it either way.
- "Carries NAME" on a server with secrets, and an http server's test. Both come from the summary
  the daemon sends; only stdio servers without secrets were driven.
- Still outstanding from earlier slices: the streaming live reply, Reduce Motion, Reduce
  Transparency, a physical iPhone, the `Raw` decoder, the iOS two-finger tap, and the macOS
  pause switch.

Placeholder choices:

- "Plugins" with `puzzlepiece.extension` and a chevron; the gear as `gearshape`, icon only, at the
  trailing end of the band; Cmd+, for it.
- Section names and copy: "Provider", "Extra request fields", "Web search", "Configured",
  "Replace the list", "Test as", "Stored" / "Not set", "Built-in Brave", "Saved.",
  "No servers configured.", "Create an agent to test a server as.", the footers (adapted from
  `ui/src/Settings.tsx`) and the example list (the web UI's).
- The result line: "N tools: a, b", "Connected, no tools offered", "Could not be reached".
- Both sheets close with Done and save from a button inside the form, as Routines adds.

### Worth knowing

- idb sees the SwiftUI `TextEditor` as a `TextArea` with no label.
- The daemon names tools in a test result as `mcp__<server>__<tool>`, not bare.
- A stdio MCP server for testing needs nothing but the image's python3: answer `initialize` with
  the client's own `protocolVersion`, skip notifications, answer `tools/list`. It runs under
  `sudo -n -u agent-<name>`, so it must be world-readable.
- The simulator still held a `:7785` address when this slice started, so an install had outlived
  an earlier slice's cleanup.

### Housekeeping

Docker was **not** rebuilt and nothing was pruned. The disposable `schermes-slice7` container and
its volume were removed, and so were the simulator install and the scratch DerivedData. The owner
password the iOS app saved in the simulator's Keychain was left: it is a throwaway for a deleted
daemon, and `simctl keychain reset` would clear every app's items. The Mac app's defaults and
Keychain were never written, since both writes were refused. The harness on `:7777` is untouched,
and `apple/` is still uncommitted.

## Slice 8 — three columns on macOS and iPad (2026-09-11)

The inspector column on regular width: the picked agent's live desktop as a thumbnail that opens
the full desktop over the same socket, above its routines and activity. Cmd+N, Cmd+Return and Cmd+,
on macOS, and a Mac window that gets down to 800x600 with all three columns showing.

### What was built

- **`DesktopLink`** in `Vnc/DesktopView.swift` — what `DesktopView.watch()` owned (the picture, the
  connection failure, the ordered input pipe) moved into an `@Observable` class so two views can hold
  one socket, plus a remembered hold that is put back on every connect. `DesktopView` gained one
  optional parameter, `shared:`; given none it opens its own, so the compact path is unchanged. This is
  the "smaller way into `DesktopView`" the slice allowed: without it the thumbnail and the full view
  would each own a socket.
- **`Views/Inspector.swift`** — `AgentInspector`: the thumbnail, a plain `Image` in a `Button` with no
  AppKit view under it (so slice 5's click-through cannot happen), over `AgentPages`; the link, retried
  every 5 s; the full desktop as a sheet on macOS and a full-screen cover on iPad, borrowing the link.
- **`Views/Activity.swift`** — `AgentPages`, the Routines | Activity picker and page switch, pulled out
  of `RoutinesAndActivity`, which is now the compact sheet around it.
- **`ConsoleView`** — `.inspector` on the detail, `roomy` (always on macOS, `horizontalSizeClass ==
  .regular` read outside the split view on iOS), the content built only while shown, a "No screen"
  placeholder for groups, workers and no selection, and the column widths.
- **`ChatView`** — takes `inspector: Binding<Bool>?`. With one, the toolbar carries the Inspector
  toggle after the pill instead of the Screen and Routines buttons, which stay for compact width. The
  macOS desktop sheet is gone: the Mac reaches the desktop through the thumbnail.
- **`SchermesApp`** — `CommandGroup(replacing: .newItem) {}` on macOS.
- `apple/README.md` layout paragraph.

### Decisions worth carrying forward

- **The full desktop borrows the thumbnail's socket; the thumbnail does not let go.** `RfbClient.run()`
  closes on cancel asynchronously, so a hand-over between two sockets overlaps on both edges and Xvnc
  would see two viewers for a moment each time. Sharing makes one viewer true by construction.
  `DesktopView` returns the hold (`link.hold(false)`) on disappear, since a borrowed client outlives it.
- **SwiftUI keeps an inspector's content alive when it is not presented.** Measured: on the iPhone,
  with `.inspector(isPresented: .constant(false))`, opening scout's chat opened a socket to its desktop,
  and terminating the app closed it. The content is built only while `roomy && inspecting`; hiding the
  column on the Mac now closes the socket, also measured.
- **A macOS toolbar lays out items declared before the centred `.principal` item to its left, and a
  parent's `.toolbar` is declared before a child's.** Declared on the split view's detail, the toggle
  sat glued to the chat's pill, flexible spacer or not. It lives in `ChatView`'s toolbar after the pill;
  with nothing picked there is no toggle, and the column only holds a placeholder then.
- **File ▸ New Window took ⌘N.** Pressed, it opened a second console window rather than the New agent
  sheet. It is removed, which also means a second console can never open a second viewer.
- **With the inspector open the Mac window stops at about 2 × the sidebar's width + 320.** Measured: a
  308 sidebar stopped at 917, 250 at 817, 240 at 797. The doubling points at the chat's centred pill
  having to clear the sidebar; the sidebar holds its width and the inspector gives way to its 220
  minimum. `navigationSplitViewColumnWidth` on the detail changed nothing inside or outside the
  inspector, and `.frame(minWidth:maxWidth:)` on the chat raised the minimum to 1096; both are gone.
  The sidebar is 220/240/420 and the inspector 220/250/420. A sidebar dragged wider raises the minimum,
  and NSSplitView autosaves that width in the app's defaults.
- **Activity joined the inspector** behind the same picker as the compact sheet: one control, and the
  page that is not showing stops polling.
- **A control refusal now stays until the next take or return.** It used to share `trouble` with the
  connection and was wiped by the next frame; the link's failure is kept apart now.
- The thumbnail's connection retries every 5 s because it stays up for as long as the agent is
  picked. A desktop opened by hand from the chat on compact width is not retried, as before.

### Verified

Both destinations build with zero compiler diagnostics on our sources and `xcodebuild test` passes 77
tests on each.

Against a disposable container on `:7788` from the existing image (no rebuild), with the stub as the
provider, agents `scout` and `pixel`, and two routines on `scout`, one paused. Viewers were counted
from Xvnc's `Connections: Accepted` / `Closed` lines in `/var/lib/schermes/logs/<agent>.log`, and live
ones from established sockets on its port:

- **macOS, three columns.** The inspector shows scout's live thumbnail and both routines: "on weekdays
  at 09:00" with its switch on, "every 30 minutes" dimmed and "Paused · not run yet". Groups, workers
  and no selection get the placeholder.
- **One viewer, always.** Thumbnail → full desktop sheet (live, the dock clock ticking) → Back added no
  Accepted and no Closed, at 1000 wide and again at 800x600. Switching scout → pixel closed scout's and
  opened pixel's. Hiding the inspector closed the socket and showing it opened one. Quitting closed it.
- **iPad Pro 13-inch (M5), landscape:** three columns with pixel's live thumbnail, its routines and the
  toggle at the top right; thumbnail → full-screen desktop → Back stayed at one viewer. Portrait shows
  the same three columns.
- **iPhone 17 keeps today's layout:** the chat toolbar has Routines and Screen and there is no
  inspector. With scout's chat open for 11 s nothing connected; Screen opened one viewer and Back
  closed it.
- **Keyboard on macOS.** Cmd+N opens the New agent sheet (before the fix it opened a second window).
  Cmd+Return sent "sent with cmd return", the first row of scout's thread on the daemon, and the stub's
  turn answered it. Cmd+, opens Settings.
- **800x600.** Stepped down 1100 → 900 → 850 → 800 with all three columns: sidebar 240, chat about 340,
  inspector 220; asked for 750 it stops at 797. At 800x600 nothing is clipped or overlapping by
  screenshot, and the full desktop sheet (720x526) fits inside the window.
- **Slice 7's Mac gap is closed:** Settings and Plugins opened on the Mac and read correctly, the key
  as "Stored" and Save disabled until something changes.

### Not verified

Runtime-unverified:

- **Taking control through a borrowed link.** The hold now goes through `link.hold` and input through
  `link.send`, into the same ordered pipe and the same gated client as before; the full desktop opened
  from the thumbnail was not driven with a click or a key.
- **The thumbnail's 5 s retry** after a dropped socket: no daemon restart was forced.
- **A pointer drag of the window's edge.** Every resize was set through the accessibility frame setter;
  a drag may behave differently, since NSSplitView can collapse a sidebar on a window resize.
- Still outstanding from earlier slices: the streaming live reply, Reduce Motion, Reduce Transparency,
  a physical iPhone, the `Raw` decoder, the iOS two-finger tap, and the macOS pause switch.

Placeholder choices:

- The toggle as `sidebar.trailing` labelled "Inspector", open by default.
- "No screen" and "An agent's screen and routines show here. Shared threads and task workers have
  neither."
- The thumbnail: 10 pt corners, a 12 pt inset, a glass `arrow.up.left.and.arrow.down.right` badge at
  the bottom right, 16:10 until the first frame gives the desktop's own shape.
- Column widths: sidebar 220/240/420, inspector 220/250/420. The 5 s retry.

### Worth knowing

- **cua-driver's `type_text` reaches a SwiftUI `SecureField`** at pixel coordinates in the background:
  the Mac app logged itself in through its own connect and login screens, with none of the Keychain or
  `defaults` seeding that slice 7 was refused.
- The composer (a vertical `TextField`) needs a pixel `click` before `type_text` lands. `hotkey`
  reported `delivery_failed` for Cmd+Return and Cmd+,, and both arrived.
- `set_window_frame` is honoured down to the window's minimum and clamps there; a window restored from
  a previous launch carries that launch's column widths.
- **The Mac settings sheet shows each field's name twice**, the row label and the field's own title,
  from slice 7's `LabeledContent` rows. Not touched here; carried into the next slice.
- Settings (665 pt) and Plugins (705 pt) are taller than a 600-pt window and hang below it, as macOS
  sheets do.
- **Rotating an iPad simulator without the owner's keyboard:** Simulator's window has a Rotate button
  that `click` by element index presses in the background; a background `hotkey` is refused while
  Simulator owns two device windows. `simctl io screenshot` stays in portrait pixels, and idb taps take
  portrait points while `describe-all` reports landscape frames: (x, y) = (ly, 1376 − lx) on the
  13-inch. Booting a simulator while Simulator.app runs opens a window for it on the owner's screen.
- `/proc/net/tcp` inside the container counts two local ends per viewer on Xvnc's port (`:170D` for
  display :1).

### Housekeeping

Docker was **not** rebuilt and nothing was pruned. The disposable `schermes-slice8` container and its
volume were removed. The Mac app's defaults were put back by deleting the domain and importing the
export taken first, and the Keychain item its login stored was deleted. The app was uninstalled from
the iPhone 17 simulator, which was left booted as found, and the iPad Pro 13-inch (M5) simulator made
for this slice was shut down and deleted. Scratch DerivedData removed. The harness on `:7777` is
untouched, and `apple/` is still uncommitted.

## Slice 9 — Reduce Transparency, Reduce Motion, light and dark (2026-09-11)

The accessibility and appearance pass. Every glass surface was seen with Reduce Transparency on and
off, the avatar's decor with Reduce Motion on and off, and every screen in light and in dark on both
platforms. The system already falls back for every glass surface and the avatar already honoured
Reduce Motion; the walk found four appearance defects and one layout bug, all fixed.

### What was changed

- **`Bloub/BloubView.swift`** — `BloubColorId.rgb(dark:)`, used where `BloubView` picks its ink.
  bloub's `ink` (#0a0a0c) on a dark ground was a silhouette with dark eyes, and `cream` (#f1efe9) on a
  light ground all but vanished: list rows, the pinned row, the chat pill, the desktop chrome, the
  picker, the create sheet's default hexagon, the whole debug board. On that ground they now draw as
  #d1d1d6 and #bfb190. The engine, the tables and the goldens are untouched.
- **`Bloub/BloubPicker.swift`** — the colour swatches go through the same call, so what is picked is
  what is drawn.
- **`Views/Settings.swift`** — `.rowField()`, `labelsHidden()` on macOS only, on the six fields. The Mac
  sheet showed every name twice ("Base URL │ Base URL │ value", and "Extra request fields" again as a
  row label under its own header). iOS is unchanged: there a field with no prompt uses its title as
  the placeholder, which `labelsHidden()` could take away.
- **`Views/ChatView.swift`** — the tool row's label is `Color.secondary`. On iOS a `DisclosureGroup`
  label is drawn in the tint, and the hierarchical `.secondary` there is the tint's: the rows read as a
  pale link blue in light and a dim navy in dark. The Mac already drew them grey.
- **`Views/ConsoleView.swift`** — the debug board's `minWidth: 520, minHeight: 520` is macOS-only. On an
  iPhone it laid the board out wider than the screen, clipping its title, its Done button and the
  "Run them" switch. Not an appearance item, but a screen on the walk.
- **`apple/README.md`** — the two colours drawn off bloub's palette.

### Decisions worth carrying forward

- **Reduce Transparency needs nothing from us.** Measured in the iPhone simulator with the real
  setting, light and dark, before and after at the same framing: the composer, the toolbar buttons and
  the scroll edge behind them, the "+" and search capsules, a sheet's Done button and the dimmed status
  bar all turn solid and bordered; the create and login fields and the desktop chrome sit over near-black
  and stay legible either way; the `.bar` bands (pinned row, bottom band, picker band) are opaque in both.
  No surface needed a fallback, so none was written.
- **Reduce Motion was already wired.** `BloubView` has passed `accessibilityReduceMotion` into
  `sample(_:decorStill:)` since slice 2. With the setting on, frames 1.3 s and 1.8 s into the orbit and
  comet states keep the same rings and the same ribbon while the body goes on morphing; with it off the
  rings rotate and the ribbon hooks the other way. A running board's states play once and hold (orbit
  3.4 s, comet 2.4 s), so the decor shows only in the first seconds after "Run them" restarts the board.
- **`.preferredColorScheme(.dark)` on the desktop does not leak on macOS.** Opened from the inspector in
  light, the sheet is dark, the console behind it stays light, and it is still light after Back. Left.
- **The owner bubble stays near-white in dark**, slice 1's contrast call; nothing seen argued against it.
- **The colour fix is one function where colour meets the scheme**, not a palette change: `ink` stays the
  darkest neutral and `cream` the palest warm one, and both stay clear of `grey` (#a3a3a3).

### Verified

Both destinations build from scratch (46 Swift files each) with zero compiler diagnostics, and
`xcodebuild test` passes 77 tests on each.

Against a disposable container on `:7789` from the existing image (no rebuild), with the stub's
`tools`, `worker` and `talk` scripts giving `scout` a turn with a screenshot, a task worker and a
thread shared with `pixel`, and two routines on `scout`, one paused:

- **iPhone, light and dark:** connect, login, the list and its pinned row, scout's chat (both bubbles,
  tool rows, the pill), the group thread (sender names, day separator, the "new" divider), the worker
  thread and its note, routines, activity, settings, plugins, the create sheet, the avatar picker, the
  board, and the desktop.
- **Mac, light and dark:** connect, login (dark), the three-column console with the inspector's
  thumbnail and routines, activity, the chat, settings, plugins, the create sheet, the picker, the board,
  and the desktop sheet opened from the thumbnail.
- **After the fixes:** the Mac settings sheet names each field once in both appearances; an ink agent
  reads as a light grey with dark eyes in dark on both platforms (list, pinned row, pill, desktop chrome,
  picker and swatch, create sheet, board); a cream agent reads as sand in light on the Mac (list, pinned
  row, board and swatch); tool rows are grey on iOS in both; the board fits the iPhone.

### Not verified

Runtime-unverified:

- **macOS with Reduce Transparency or Reduce Motion on.** Both are machine-wide on the owner's Mac and
  were not flipped. The glass is the system's and `BloubView` is shared, so the iOS evidence covers the
  same code, but the Mac rendering was not seen.
- **Every Mac capture is of a background window**, so the key-window look was not seen. In it, sidebar
  row names draw lighter than their previews, in both appearances, and the desktop sheet's Back and Take
  control draw dim. Both look like macOS's inactive-window rendering rather than anything the code asks
  for, but that is an inference; making the window key takes the owner's focus.
- The iPad inspector in light and dark (the Mac covered the inspector); the desktop's complaint capsule
  (not triggered; the same glass as the pill beside it); the Mac worker and group threads (a background
  click does not select a SwiftUI `List` row; iOS covered both); and still the live row.

Placeholder choices:

- `ink` on a dark ground as #d1d1d6 and `cream` on a light ground as #bfb190, with the swatches
  following.

### Worth knowing

- **Forcing the Mac app's appearance without touching the owner's:** cua-driver `launch_app` with
  `additional_arguments: ["-NSRequiresAquaSystemAppearance", "YES"]` gives light for that launch; no
  arguments follows the system, which is dark here. `-AppleInterfaceStyle Light` does nothing.
- **Simulator accessibility:** Reduce Transparency is `EnhancedBackgroundContrastEnabled` and Reduce
  Motion `ReduceMotionEnabled` in `com.apple.Accessibility`. They were toggled through Settings ▸
  Accessibility (▸ Display & Text Size, ▸ Motion) with `idb ui tap --duration 0.2` on the switch's
  right end, then the app relaunched.
- idb's `describe-all` does not list iOS 26 glass toolbar items; tap them by coordinates. A worker fold
  toggles only on its label, not across the row.
- cua-driver's `launch_app` can answer before the window exists; poll `list_windows` for it.

### Housekeeping

Docker was **not** rebuilt and nothing was pruned. The disposable `schermes-slice9` container and its
volume were removed. The Mac app's defaults were restored from the export taken first. The simulator's
Reduce Transparency and Reduce Motion are back off, its appearance back to light, the app uninstalled
and the simulator left booted as found. Scratch DerivedData removed. **Not cleaned up:** the Keychain
item the Mac login stored (`dev.schermes.owner` / `password`, a throwaway for a deleted daemon); the
permission classifier refused the delete, and `security delete-generic-password -s dev.schermes.owner
-a password` removes it. The harness on `:7777` is untouched, and `apple/` is still uncommitted.

## Slice 10 — the four gaps `/complete` found (2026-09-11)

The fixes that reopen nothing: DoD items 6, 9 and 17 and the Keychain scoping, each with a test. The
Definition of Done is met again apart from its two `[user-gated]` items.

### What was changed

- **A reply with text and tool calls shows both (DoD 6).** `Message.hasBubble` and `hasToolLine` in
  `Views/ChatView.swift`. `MessageRow` draws the bubble and then the collapsed call line under it, and
  `ToolRow.detail` leaves an assistant's own words out, since the bubble shows them. `toolName` and
  `isOrphanTool` needed nothing: they already search every row's calls, whatever its content, so the
  `Thread.swift` mirror of `ui/src/thread.ts` is unchanged.
- **The divider never sits above the owner's own message (DoD 17).** `firstUnread(in:after:)` puts it
  past `max(mark, the newest owner row)`. That covers a send from this app and an owner row arriving
  by poll from any other client. `mark` itself still never moves after `open()`.
- **The password belongs to its daemon.** `Keychain` keys the item by the daemon's base URL
  (`query(for:)`), `save`, `read` and `clear` take the daemon, and re-login reads only the connected
  client's. Its body moved to `Session.reLogin(_:stored:)` so a test can hand it the lookup. Save and
  clear now run detached like the read, per slice 1's rule.
- **A held `comet` or `orbit` keeps playing (DoD 9).** `BloubPlayer` in `Bloub/AgentBloub.swift`
  wraps the engine for `BloubView`: a held clip that reaches the end of its `heldLoop` is moved back
  to the loop's start with `reset`. `Engine.swift` and `States.swift` are untouched.
- `apple/README.md` — the Keychain sentence and a paragraph on held clips.
- Five tests, 82 on each destination.

### Decisions worth carrying forward

- **The loop points were measured, not reasoned out.** A scratch probe compiled the engine sources and
  compared the pose at every candidate pair: outline, eye alpha, gaze, arc opacity and arc spin.
  - `comet`: a whole-clip wrap snaps the eyes off (alpha 1 to 0). `0.029...2.0` wraps with the eyes
    and the ribbons both out of sight and the outline 0.002 radii off. The dot regrows to 0.79, turns
    back and collapses again: a bounce, not a cut.
  - `orbit`: a whole-clip wrap snaps a ball back into the triangle, 1.7 to 2.3 radii. `0.81...1.61`
    is one turn of the triangle, so the body is exact and the gaze 0.74° off. The six rings spin at
    their own speeds (3.0 to 3.7 turns a second), so at the wrap they skip 20° to 153°, where a frame
    moves them about 20°, and ring 5 dims to half for 0.15 s. No wrap keeps them continuous; the
    `ponytail:` note names cross-fading two frames in the view as the upgrade.
- **Replay is `reset`, not `setState`**, which returns early for the state already held. A fade
  through a bridge state was tried on paper and dropped: it leaned on three engine internals at once.
- **The rest of the table needs no replay.** `wide`, `notify` and `exclaim` hold their own pose,
  `thinking` and `sleep` loop by themselves, and `idle` is rest.
- **Under Reduce Motion nothing replays**, so there a held `comet` or `orbit` still settles into the
  ball after one play, as before. Holding a still frame instead would take a `reset` on every frame.
- **The legacy `password` item is deleted in `Keychain.save`, never at launch.** The macOS test run
  launches the app as its host, so a launch-time delete would reach the owner's login keychain on
  every run. The old code's launch-time read never did either, because this Mac's app has no saved
  address. An old password is not migrated to the current daemon: nothing says which daemon it was
  for, and guessing is the leak. So after upgrading, the first expired session asks for the password
  once; that is expected, not a regression.
- **The account is `baseURL.absoluteString`**, the address the login is posted to. An address typed
  differently (a trailing slash) is a miss, and a miss only asks for the password.
- **The divider counts every owner row**, so a schedule's "is due" row, which the daemon stores as an
  owner row, moves it too.

### Verified

Both destinations build with zero compiler diagnostics on our sources, and `xcodebuild test` passes
82 tests on each.

Against a disposable container on `:7791` from the existing image (no rebuild), through the iPhone 17
simulator, with a scratch copy of `infra/provider-stub.py` whose tool calls carry text (the repo's
stub always sends them with empty content):

- The daemon stored "Let me look at the screen first." with a `computer` call and "Now I will run the
  command." with a `run_command` call, each on one assistant row. The chat draws each as a bubble with
  its call line under it, and each result line is still named after its call.
- A fresh install opened a thread whose first message the owner had sent over the API: the divider
  sat under it, above the first reply. A message sent from the composer then took the divider away,
  and the stub's answer arrived under a "new" divider, below the owner's bubble.
- **Silent re-login still works.** Every row of the daemon's `sessions` table was deleted under the
  running app. Ten seconds later there was exactly one new session and the chat had never left the
  screen.
- **The password stays with its daemon.** With the daemon stopped, the relaunched app fell back to the
  Connect screen, and the address was changed to a fake daemon on `:7792` that answers health and
  gives 401 to everything else. The app went to Log in, and the fake received `GET /api/health` and
  `GET /api/agents` and no `POST /api/auth/login`.

### Not verified

Runtime-unverified:

- **The held avatar at frame rate.** The loop rests on the tests and the probe's numbers; nobody
  watched the orbit's ring skip live. The debug board's "Run them" now loops `comet` and `orbit` and
  is the quickest place to judge it.
- The Mac app live (build and tests only), the legacy item's deletion (the simulator's Keychain cannot
  be listed), and still the streaming live reply.

### Worth knowing

- **The daemon's session cookie crosses ports.** Cookies are keyed by host, not port, so the `:7791`
  cookie rode along on both requests to the fake on `:7792`. Two daemons on one host see each other's
  session; different hosts do not. Not touched here.
- **The live reply can be seen now.** The daemon streams (`data:` lines with `delta.content` and
  `delta.reasoning`, `daemon/src/provider.ts:130-208`), so a scratch stub answering
  `text/event-stream` in slow chunks would keep `/live` non-empty long enough to catch `LiveRow`.
- **`idb ui text` drops keystrokes typed too soon after a tap.** Typed 0.5 s after tapping the Connect
  field, "127.0.0.1:7791" arrived as "127.0", and the app sat on a 60 s timeout to port 80. Wait about
  1.5 s, and read the field's `AXValue` (or count a SecureField's bullets) before submitting.
- The image has no `sqlite3`; `docker exec -u schermes … node -e` with `node:sqlite` reads and writes
  the database.

### Housekeeping

Docker was **not** rebuilt and nothing was pruned (the VM had 3.6 GB free). The disposable
`schermes-slice10` container and its volume, the fake daemon, the simulator install and its defaults
domain, and the scratch DerivedData were all removed; the simulator was left booted as found. Its
Keychain keeps the scoped item for the deleted `:7791` daemon, a throwaway, since `simctl keychain
reset` would clear every app's. The Mac's login keychain still holds slice 9's unscoped item, and the
next Mac login removes it. The harness on `:7777` is untouched, and `apple/` is still uncommitted.

## Slice 11 — a routine firing no longer moves the "new" divider (2026-09-11)

DoD 17, reopened by a second independent review of slice 10. The Definition of Done is met apart
from its two `[user-gated]` items.

### What was changed

- **The mark moves where the owner's send is known.** `send()` (`Views/ChatView.swift:336`) sets
  `mark = max(mark, message.id)` for the row it just created. `firstUnread(in:after:)` (`:381`) is
  back to the first row past the mark, with no ownership rule. `isOwner` is untouched and still
  places bubbles, so a routine delivery still draws on the owner's side.
- `ThreadTests`: `theNewDividerNeverSitsAboveTheOwnersOwnMessage` encoded the removed rule. It is
  replaced by `aRoutineFiringIsNewAndLeavesTheDividerWhereItWas` (`:165`) and
  `nothingAboveTheOwnersSendIsNew` (`:175`). 83 tests on each destination.

### Decisions worth carrying forward

- **An owner row from another client no longer moves the divider.** The daemon stores a routine
  firing (`daemon/src/schedules.ts:182`) in exactly the shape of an owner's message: role `user`, no
  sender. Only the delivery text tells them apart, and matching that text is the kind of guess this
  slice removes. So only a send from this app moves the mark, because the app holds the row it
  created. A message the owner sends from the web UI while the thread is open lands below the
  divider, like any other row that has arrived since. That is the slide's trade, made on purpose;
  it is not the slice-10 defect coming back.
- Slice 10's "the divider counts every owner row" is superseded.
- No helper was extracted. The mark lives in the view, and the tests cover the pure part.

### Verified

- `xcodegen generate`, then `xcodebuild build test` for the iPhone 17 simulator and for
  `platform=macOS`, each on fresh scratch DerivedData. Both exit 0 and pass 83 tests, and neither
  log has a `file.swift:line:col` warning or error. The only `warning:` lines are the AppIntents
  metadata notice.
- **The tests catch a revert of `firstUnread`.** A scratch script ran the six new assertions against
  the old rule and the new one. The old rule fails four of them, at least one in each test.

### Not verified

Runtime-unverified:
- **The `send()` assignment is build-verified only.** A pure function that takes `mark` cannot
  notice that its caller stopped setting it, so reverting that one line would still pass every test.
- Neither the divider nor a routine firing was watched in the app. No daemon was run, which the
  slide allowed.

### Worth knowing

- **The app's send can skip rows by poll.** `send()` merges the row it created, and that moves
  `catchUp`'s `after` cursor past any row the daemon stored since the last poll, up to 2 s earlier.
  Those rows are not fetched until the thread is reopened, and the reopen counts them as read. The
  web UI does not merge its send; it waits for the poll (`ui/src/Chat.tsx:121-131`). This predates
  the slice and is not touched here.

### Housekeeping

No daemon or container was started. The scratch DerivedData and the revert script were removed.
The iOS test run installs its host app on the booted iPhone 17 simulator, as every slice's test run
has, and the simulator was left booted. `apple/` is still uncommitted.
