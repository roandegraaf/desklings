# Progress — redesign-polish

## Current state
- Tokens, styles, levers, iPhone shots: `docs/slides/_archive/apply-redesign-canvas/PROGRESS.md` (still true).
- **Mac render path (focus-free):** `apple/SchermesTests/MacRenders.swift`, test `renderMacScreens()`, off unless all
  three env vars reach the test host (one command):
  TEST_RUNNER_SCHERMES_RENDER_DIR=<abs dir> TEST_RUNNER_SCHERMES_RENDER_ADDRESS=127.0.0.1:<port> \
  TEST_RUNNER_SCHERMES_RENDER_PASSWORD=test1234 [TEST_RUNNER_SCHERMES_RENDER_ONLY=<name prefix>] \
  xcodebuild test-without-building -scheme Schermes -destination 'platform=macOS,arch=arm64' -derivedDataPath <own> \
    '-only-testing:SchermesTests/renderMacScreens()'
  Bed daemon: `SCHERMES_PORT=7911 SCHERMES_DATA_DIR=<scratchpad>/bed node src/main.ts` from `daemon/` (stopped).
  `ONLY=main` ~40 s, `page-`/`settings-` ~4 min each. Writes `<name>-<mode>.png`, `.views.txt`, `.sheet.png`,
  `.sheet.views.txt`. `cacheDisplay` misses window-server drawing; controls draw inactive. **View dumps prove chrome.**
- **Test host is focus-safe** (`hostingTests`); keep the renderer crash-free and poll `lsappinfo front` every run.
- **Mac shell (slice 2): `MacSplit` in `Views/Sidebar.swift`**, an `NSSplitViewController` (sidebar 220/292/420,
  chat min 320, inspector 220/340/420), Mac only; iOS keeps `NavigationSplitView`, whose glass can't be removed, so
  don't go back to it on the Mac. 10pt invisible gutters, panes pad themselves (`safeAreaRegions = []`), an empty
  unified toolbar puts the traffic lights in the sidebar card, panes get the environment via
  `.environment(\.self, …)`. `inspecting` drives collapse. ⌃⌘S posts `.toggleSidebar`. Full pages log 10
  pre-existing AttributeGraph "Cycle detected" lines per render.
- **Inspector (slice 3):** Main's aside: Screen, `GoalSummary`, `RoutinesSummary` ("Ask…" sends a message).
  `AgentPages` (page sheets) serves the capsule's Routines/Memory, the settings pills and the right-click menu.
- **App settings (slice 4/5):** no `Settings` scene. `SettingsSheet` (Settings.swift, Mac) is a sheet over the
  console window. Sidebar gear and Needs you set `settingsOpen`. ⌘, is `SettingsCommand`: it sets
  `SettingsRequest.pending`, brings back or opens the console window, then posts `.showSettings`; `settingsSheet(_:)`
  presents on the notification or, for a console that mounts later, on appear. Renders: `settings-<tab>`.
- **Agent settings page (slice 5), MacSettings with option A:** `AgentSettingsPage` (Views/AgentSettings.swift,
  Mac only) is the detail pane for `SidebarPick.agentSettings(name)` (a full page, so the inspector is shut). The
  chat capsule's gear opens it; a back pill (⌘[) returns. Header pills: Name and appearance (`AgentLookSheet`, which
  now holds `ProfileView(bare:)` on the Mac), Memory and Activity (page sheets). The agent model is a menu in the
  subtitle. Left `RulesView(board: true)`, right 380pt `RoutinesSummary` + `IdleSettingsView(card: true)`; stacked
  below 1000pt. Levers `agent-settings:<name>`, `look:<name>`. Reachability table: `shots/slice-5/NOTES.md`.
- **Sheets and forms (slice 6, Mac):** no `NavigationStack`/toolbar in any Mac sheet. Use `sheetChrome(...)`
  (Theme.swift; iOS keeps NavigationStack + toolbar) or `SheetHeader` (title left, pills right, Esc). `ThemedForm`
  on the Mac is a custom `CardFormStyle` (white r18 cards, ink 8% border) with row label/toggle styles; a bare
  `TextField` needs `.formLabel("…")` to keep its label. Renders write `.sheet.views.txt` (the proof: no NSToolbar).
- **Composer (slice 7, Mac):** `floatingCard(radius:fill:shadow:blur:y:)` (ChatView, Mac) is Main's floating
  white; the composer capsule, worker chips and notice use it, iOS keeps glass. Tool runs are white r16 cards
  (`WholeRowDisclosure` chip on the Mac). Bed workers: insert busy `agents` rows (parent_id 4) after boot.
- **Search (slice 8, Mac):** an overlay, not a sheet: `SearchOverlay` (Search.swift) dims the console (black
  40%/50%) and floats `SearchPanel` (max 720x650, r26, 100pt from the top); click outside or Esc closes via
  `onClose`. iOS keeps the sheet. The `search:` lever captures it in the main window PNG (no `.sheet.png`).
- **Pickers (slice 9):** `ValueMenu` (Theme.swift) is the one picker: Mac = label + bold value + chevron menu
  (honours `labelsHidden()`), iOS = stock `.menu` Picker. Use it for any new picker. Card row labels have
  `minWidth: 110`, so text fields line up. Rules' coloured `levelMenu` stays its own.
- **Audit:** `shots/audit.md` is fully resolved (its "Resolution (slice 10)" table: fixed, or kept with a reason).
  Final renders of every board, light and dark, are in `shots/final/` + NOTES.md. Grep gate clean. All gates green.
  Only the `[user-gated]` owner review is open.
- Verification: `xcodebuild test` on macOS with your own `-derivedDataPath` (render env unset) while polling the
  front app, plus `build-for-testing` for the iOS sim; `pnpm check`, `pnpm test`. New files need `xcodegen generate`.

## Slice: 1 — Mac render path and board-by-board audit (2026-10-01)
- Shipped:
  - `SchermesTests/MacRenders.swift`: the env-gated renderer described above.
  - Test-host guard in `SchermesApp.swift` (`hostingTests`, `applicationWillFinishLaunching`, console skipped) and
    `Notifier.swift` (`ask()` skipped under tests).
  - Renders in `shots/slice-1/`, light and dark: the full window for Juno (inspector with PAUSED) and Mo, Needs
    you, the goal, Search ("invoices"), New agent, the six agent pages (as sheets), the six Settings tabs, the
    menu bar panel.
  - `shots/audit.md`.
- Key decisions:
  - Real data from a bed daemon rather than in-memory fixtures: `ConsoleView` loads everything through
    `Session.client`, and the bed already holds every screen's states.
  - Off-screen titled window, never activated. The non-activating on-screen fallback wasn't needed.
  - Glass columns are composited by hand rather than captured (ScreenCaptureKit is broken on this Mac and would
    raise a TCC prompt for the test host).
- Notes / leftovers:
  - Not in the bed, so not rendered: task workers above the composer, shared threads / "Messages" section, the
    interview Needs-you card, the menu bar "Working" rows, a goal description.
  - The Settings window renders with a garbled tab strip (borderless window); moot, since that window goes.
  - Inspector renders at its 220pt minimum in a fresh window, not the 340 ideal (audit, Main).
  - A duplicate worker (slice-1-3) briefly built the same renderer in `MacRenderTests.swift`; the lead removed it.
- Placeholder choices: the Activity / Profile homes in `shots/audit.md` are a proposal for the owner, nothing
  built.
- Runtime-unverified: the real Mac app was not launched; the renders stand in for it. Glass tint and active-window
  control colours are not in the renders.

## Slice: 2 — no seam: three floating cards on one ground (2026-10-01)
- Shipped:
  - `Views/Sidebar.swift`: `MacSplit` / `MacSplitController` / `GutterSplitView` (the Mac three-pane shell);
    `macPanel()` with Main's fill, border and two-layer shadow (no edge parameters any more).
  - `Views/ConsoleView.swift`: `body` → `split` (macOS `MacSplit`, iOS `NavigationSplitView` + `.inspector` as
    before) and `detail`; chat card masked at r22; sidebar/inspector use `.macPanel()`; DEBUG lever `bare:<name>`.
  - `SchermesTests/MacRenders.swift`: `main-bare` screen.
  - Renders + `shots/slice-2/NOTES.md` (what failed first, matches/differs vs Main, dark values).
- Key decisions:
  - SwiftUI (`.containerBackground(for: .navigation)` is unavailable on macOS) and AppKit-on-NavigationSplitView
    (divider/shadow hideable, glass not) both failed; recorded in NOTES and sent to the lead before building.
  - Own `NSSplitViewController` rather than an HStack: native drag-resize and drag-collapse stay free; `toggleSidebar(_:)`
    is overridden (the stock one wants a sidebar-behaviour item), so a Toggle Sidebar menu item, if present, works.
  - Panel fill as `Theme.card.opacity(0.66)`: over `Theme.window` it is `#faf8f5` light and exactly the old dark
    panel `#1c1b20`. No new tokens; shadow uses `.black` like the rest of the code.
- Notes / leftovers:
  - Traffic lights at (19,19), Main (29,27); sidebar search row ~62pt from the top vs Main's 51 (List top inset).
  - A collapsed *sidebar* leaves a 20pt left edge (its divider plus the window pad); only the inspector case is
    compensated, since the binding only knows the inspector.
  - The inspector card has the two-layer shadow (per NEXT_SLIDE); Main's `<aside>` has none.
  - `.navigationSplitViewColumnWidth` / `.inspectorColumnWidth` now only matter on iOS.
  - Split items don't stretch content: detail and inspector take `.frame(maxWidth/maxHeight: .infinity)` before
    their backgrounds (the empty states shrank them). Sheets from the sidebar pane still attach (all pages,
    new agent, search rendered with a `.sheet.png`).
- Placeholder choices: dark panel border `#222026` and panel `#1c1b20` (card dark at 90% / 66%), panel/window
  1.12:1, ink/panel 15.2:1; black 6% shadow (invisible in dark).
- Runtime-unverified: the real Mac app was not launched. Not exercised: dragging the gutters, drag-collapse and the
  binding write-back, whether the View menu still offers Toggle Sidebar (no `SidebarCommands` in the app), ⌘ shortcuts and keyboard focus across the
  three hosting controllers, window resize/min size, full screen, how the traffic lights look in an active window.
  Every ConsoleView update reassigns each pane's `rootView` (refresh loop, every 2 s): check a half-typed
  draft and the chat scroll position survive it in the live app.
  The header toggle path ran in the render (`bare:juno` sets `inspecting = false` after load; the inspector
  collapsed and the toggle reads off).


## Slice: 3 — inspector contents (2026-10-01)
- Shipped:
  - `Views/Inspector.swift`: an own ScrollView (padding 16, gap 18) with Screen, goal and "Routines and triggers"
    (white r14 cards with soft agent tiles, a soft agent "Ask <agent> to set one up" pill, and a muted empty line).
  - `Views/Goals.swift` `GoalSummary`: the board's layout (30pt ring, rounded 16 title, "Goal · 2 of 6 done",
    chevron; white r14 helper rows with a 26pt bloub, name and state line).
  - `Views/ChatView.swift`: Activity in the Mac gear menu. The iOS ⋯ menu shows with an inspector too (iPad regular
    width), with Profile / Activity / Memory as separate items and no duplicate Export.
  - Addendum: `SchermesApp.swift` Toggle Sidebar command + `Notification.Name.toggleSidebar`;
    `Views/Sidebar.swift` `MacSplitController` observes it. New `SchermesTests/MacSplitTests.swift` (3 tests).
  - Renders + `shots/slice-3/NOTES.md`, which holds the matches/differs list and the reachability table.
- Key decisions:
  - "Ask…" sends a message through `session.run { $0.send(.agent(name), text:) }`. That is an existing path
    (`ProfileView.ask()`), so the board's label stays honest. No composer prefill exists.
  - The model picker stays in the page sheet's Overview, not in the gear menu or When idle. Both of those need new
    state, and the agent settings page will absorb it anyway.
  - `@State` survival needed no fix. Toggle Sidebar needed a notification, not a relay responder.
- Notes / leftovers:
  - Schedule cards use the prompt as the title (schedules have no name). Worker rows show the state line, not the
    board's free-text status.
  - The test host's Help menu also listed a "Toggle Sidebar" entry (likely the help-search mirror). Unchecked in the
    real app.
  - `pnpm check` / `pnpm test` not run: no daemon or web code was touched.
- Placeholder choices: the "Ask" message text ("Is there a routine or a trigger that would help with what you do for
  me? Propose one I can switch on."); the empty line "Nothing scheduled and nothing watched."; trigger detail words
  ("proposed", "waiting for the login", "on", "off"); the bolt and clock symbols.
- Runtime-unverified: the real Mac app was not launched. Not exercised: the "Ask" pill sending, the routines sheet
  opening from the inspector pane, ⌃⌘S from the real menu bar, the iPad ⋯ menu layout beside the inspector toggle.

## Slice: 4 — app Settings as a sheet (2026-10-01)
- Shipped:
  - `SchermesApp.swift`: `Settings` scene removed; `CommandGroup(replacing: .appSettings)` "Settings…" ⌘, posts
    `.showSettings`.
  - `Views/Settings.swift`: `SettingsRequest` + `settingsSheet(_:)` (sheet plus the `.showSettings` receiver on the
    Mac); Mac `SettingsSheet` (header, Done pill, tab track, `Theme.ground`) replacing `SettingsWindow`. Tabs keep
    their natural width, minimum 700pt. "Model" tab is now "Models".
  - `Views/ConsoleView.swift`: gear next to New agent opens the sheet; `SettingsSheet` gets the push registration
    environment; DEBUG lever `settings` reads its tab from `-schermes.settingsTab`.
  - `Views/Sidebar.swift`: no split autosave under `hostingTests`; `MacSplitTests` no longer saves/restores it.
  - `SchermesTests/SettingsTests.swift` `SettingsCommandTests` (2 tests); `MacRenders.swift` renders `settings-<tab>`
    as a sheet over the main window.
  - Renders + `shots/slice-4/NOTES.md`.
- Key decisions:
  - Notification with `object: nil`, not the key window: there is one console window and it owns the sheet, so ⌘,
    from a desktop window still opens settings in the console.
  - Retry worker: the dead worker's edits in SchermesApp, Settings, ConsoleView, MacRenders and SettingsTests were
    complete and compiled; kept as they were, apart from the tab truncation fix.
- Notes / leftovers:
  - The owner's defaults held a test-written `console.split` (1200x800, sidebar collapsed): the real app would have
    opened with no sidebar. Deleted (backup `shots/slice-4/console.split.leaked.txt`); root cause fixed.
  - Settings tabs keep grouped-form fills, stock `(...)` menus and duplicate page titles (audit gaps, later).
  - ⌘, does nothing while the console window is closed: the app lives on in the menu bar extra and only a live `ConsoleView` hears `.showSettings` (the old scene always answered). Reopen the console from the menu bar panel to reach settings. A fix would open the console window first (`openWindow(id: consoleWindowID)`), then post.
  - The sheet still presents with the sidebar collapsed (first render pass: split item hidden, `NSSheetEffectDimmingView` present), so ⌃⌘S does not strand it.
- Placeholder choices: sheet 700x580 minimum; header title uses `.sectionTitle`.
- Runtime-unverified: the real Mac app was not launched. Not exercised: ⌘, from the real menu bar, the gear click,
  Esc closing the sheet, the sheet over a narrow (1000pt) window, Needs you's "Open model settings" landing on Models.

## Slice: 5 — the agent settings page, option A (2026-10-01)
- Shipped:
  - `Views/AgentSettings.swift` (new, Mac): `AgentSettingsPage`, MacSettings' header, Rules matrix and 380pt column.
  - `Views/ConsoleView.swift`: `SidebarPick.agentSettings`, detail routing (agent row stays highlighted), levers
    `agent-settings:<name>` and `look:<name>`. `Views/ChatView.swift`: the gear opens the page (`onOpenSettings`);
    Export became a capsule icon for every thread.
  - `Views/Rules.swift` `board:` layout (column words, white rows, flexible segments in a fixed 400pt track,
    Pre-approved strip with an "Edit list" popover holding the existing editor). `Views/Idle.swift` `card:` layout
    (checkboxes, label + bold value menus). `Views/Routines.swift` `RoutinesSummary`, moved verbatim from the
    inspector. `Views/Profile.swift` `bare:`; `Bloub/BloubPicker.swift` look sheet shows it (Done waits for an open
    edit). `Views/Activity.swift` `AgentModelRow` internal with a `bare` menu.
  - Addendum: ⌘, with the console window closed (`SettingsCommand`, `SettingsRequest.pending`, Settings.swift;
    SchermesApp.swift) + test `settingsCommandWithTheConsoleClosedOpensItAndTheSheet`.
  - `MacRenders.swift` sized screens (`settings-agent`, `settings-agent-narrow` at 1000x680, `look`); renders and
    NOTES in `shots/slice-5/`.
- Key decisions:
  - Agent model in the subtitle, not When idle (its "Model" is the idle model).
  - Board layouts are flags on the existing views, so loading, saving and errors stay in one place.
  - One width read (`onGeometryChange`) with `AnyLayout` for the columns, so Rules/Idle keep their state on resize.
- Notes / leftovers:
  - Bed: added `preApproved` flytap.com, you@example.com to juno.
  - The shell's AttributeGraph cycle (every full page, 10 per render) is pre-existing, bisected in NOTES.
  - The sidebar right-click menu still opens the old page sheets (all still work); could point at the page later.
  - A slug change in the look sheet posts `.openAgent`, which leaves the settings page for the chat.
  - `pnpm check` / `pnpm test` not run: no daemon or web code touched.
- Placeholder choices: back pill with ⌘[; `checkmark.shield` on the Pre-approved strip; "nothing yet" for an empty
  list; the Idle footer's added "Hours are on the daemon's clock."; Activity pill icon = the page's
  `list.bullet.rectangle`; "Save or cancel the profile first" help on the disabled Done; 1000pt stacking threshold.
- Runtime-unverified: the real Mac app was not launched. Not exercised: the gear click and ⌘[ back, the Edit list
  popover, checkbox/menu edits writing through, the look sheet's profile Edit/Interview, ⌘, from the real menu bar
  with the console window closed (open path) and while hidden (bring-back path), keyboard focus on the page.

## Slice: 6 — sheet chrome and grouped forms on the Mac (2026-10-01)
- Shipped:
  - `Views/Theme.swift`: Mac `ThemedForm` = `Form` + private `CardFormStyle` (`ForEach(sections:)`, empty
    sections draw no card) + `CardRowLabeled` / `CardRowToggle` (honour `labelsHidden()`); `formLabel(_:)`;
    `sheetChrome(...)`; `SheetHeader`. iOS `ThemedForm` unchanged.
  - `Views/Activity.swift`: `AgentPages(done:)` puts back pill + title + Done in one Mac header row;
    `RoutinesAndActivity` has no NavigationStack on the Mac.
  - `Views/NewAgent.swift`: Mac header (title, Cancel pill, Esc), Create a regular trailing pill.
  - `Views/Settings.swift`: SettingsSheet header via `SheetHeader`; Model/Server sheets via `sheetChrome`;
    "Models" duplicate header dropped; model row `(...)` a round secondary pill on the Mac; Plugins "Test as" a
    label + bold value menu; Arguments `formLabel`. Page sheet minimum 720pt so the Rules track still fits.
  - `sheetChrome` also on `Forms.swift` (Form for), `Forward.swift` (Send to), `ChatView.swift` (Bad reply),
    `About.swift` (About sheet).
  - Duplicate titles: Rules and Profile section headers dropped. `Idle.swift`: Mac stepper row value beside
    the stepper. `Routines.swift`: Cron `formLabel`.
  - `MacRenders.swift`: writes `<name>.sheet.views.txt`. Renders + NOTES in `shots/slice-6/`.
- Key decisions:
  - A custom FormStyle, not modifiers: a swiftc probe showed `listRowBackground`, `backgroundStyle` and
    `containerBackground` can't recolour the macOS grouped section box.
  - The Models `(...)` is an action menu (Edit/Default/Delete), so it became a round pill, not a label + value menu.
  - Done-only sheets map Done to Esc; edit sheets keep Cancel = Esc, Save/Send/Fill = Return, as the toolbar did.
- Notes / leftovers:
  - Pickers inside cards (Idle sheet, editor sheets) stay stock pop-ups (no public custom PickerStyle); text field columns don't align
    across rows; LabeledContent values draw in ink. All in NOTES "Differs".
  - Bed daemon log is noisy with `sudo -n` desktop errors (no shims on this run); renders unaffected.
  - `pnpm check` / `pnpm test` not run: no daemon or web code touched.
- Placeholder choices: card radius 18 (brief said 16-20), 22pt between sections, 16pt row inset; header padding
  20/16/12; `ellipsis` in a round secondary pill for the Models row menu; Cancel as a secondary pill on New agent.
- Runtime-unverified: the real Mac app was not launched, and these sheets were not rendered: Model/Server editor,
  Form for, Send to, Bad reply, About from the app menu, and the Memory editor (bed can't read memory). Not exercised: Esc/Return on the new headers, ⌘[ in the
  page sheet, text entry in card rows, the Models row menu opening from the pill.

## Slice: 7 — composer capsule, worker chips, tool-run cards (2026-10-01)
- Shipped (`Views/ChatView.swift` only, Mac-gated): Main's composer capsule (760 max, r26, card 86%, white
  border, 8% shadow, round ink-6% attach, 15pt text); worker chips as white capsules in a row (column fallback);
  tool runs as white r16 cards with the ink 8% border; the notice row uses the same floating card. Placeholder
  is "Message <Agent>, or / for commands" on both platforms (suffix only when commands are offered); the
  editor's VoiceOver label stays "Message <Agent>". Renders + matches/differs: `shots/slice-7/`.
- Key decisions: `floatingCard` lives in ChatView (only the chat uses it); shadow is `.black` like `macPanel`.
  Tool-run label keeps the app's summary, not Main's "Worked for …" (needs elapsed time, a non-goal).
- Notes / leftovers: chips show the state word, not per-worker activity text (no data). Bed workers were added
  to a copy at `<scratchpad>/bed7`; the source bed is untouched.
- Placeholder choices: dark composer/chips reuse `Theme.card` dark (0x232127) at 86%/80% with a card-coloured
  border, no new token; its edge on the dark chat panel is faint (card vs panel ~1.1:1). Attach icon paperclip
  (matches the canvas path). Chip bloub 20pt.
- Runtime-unverified: typing, Return/⌘Return send, slash palette, attach menu and stop were not exercised in a
  running app (code paths unchanged; render path only).


## Slice: 8 — search floating panel (MacSearch) (2026-10-01)
- Shipped: on the Mac, ⌘K/sidebar search opens `SearchOverlay` (Views/Search.swift) over the console instead of a
  sheet: dim layer, panel max 720x650, r26 continuous, hairline border, black 35% shadow blur 80 y 30, 100pt from
  the top, 24pt from the other edges on small windows. `SearchPanel` takes `onClose` (falls back to `dismiss`
  on iOS); Esc, click outside, and opening a hit close it; `.isModal` for VoiceOver. The query no longer opens
  selected (`TextField(selection:)`, caret moved to the end after focus). Renders: `shots/slice-8/`.
- Key decisions: an overlay in the console view rather than a child panel: keeps ⌘K, focus and the result
  actions with no window plumbing, and the existing render lever captures it unchanged.
- Notes / leftovers: keyboard Tab can still reach controls behind the dim layer (no focus trap in SwiftUI
  overlays). Top hit preview / Open / Show in thread / Send to stay out (non-goal).
- Placeholder choices: dim is black 40% light (window #efebe3 -> ~#8f8d88, board #8f8a82) and black 50% dark
  (panel #1c1b20 vs dimmed ground ~#080709, ~1.2:1, so the hairline border carries the edge; light ~3.2:1);
  dark shadow reuses black 35%; 150 ms fade.
- Runtime-unverified: typing, Return to ask, Esc, click-outside and opening a hit were not exercised in a
  running app; only the render path (static open state) was checked.

## Slice: 9 — themed pickers in form cards (2026-10-01)
- Shipped: `ValueMenu` in `Views/Theme.swift` replaces every stock pop-up picker on the Mac: Idle sheet From/Until/
  Model and the When idle card's menus (`Idle.swift`, old private `valueMenu` removed), Plugins "Test as" and the
  server editor's Transport (`Settings.swift`), Form for select/radio fields (`Forms.swift`), New agent starting
  rules (`NewAgent.swift`), `AgentModelRow` both modes (`Activity.swift`). `CardRowLabeled` label minWidth 110 so
  text fields align across rows. Renders + NOTES: `shots/slice-9/`.
- Key decisions: one view, not a PickerStyle (no public custom one); the caller passes the value text.
  VoiceOver: label = title, value = selected text (was one combined label).
- Notes / leftovers: Daily budget field in the Idle sheet is a wide bordered field (not a picker, left).
  Rules `levelMenu` (coloured value) not merged into `ValueMenu`.
- Placeholder choices: label column min 110pt.
- Runtime-unverified: opening the menus, keyboard (Space/arrows) and VoiceOver readout not exercised live; Form for,
  server editor and New agent rules not rendered (bed has no such state / sheet lever).

## Slice: 10 — final board renders and the gates (2026-10-01)
- Shipped:
  - `shots/final/`: 74 PNGs (every lever, light and dark) from one unfiltered render run, plus NOTES.md with a per-board
    matches/differs list. Front-app hits: 0.
  - `shots/audit.md` "Resolution" table: every item is fixed (with its slice) or kept with a reason.
  - Small fixes: `Vnc/DesktopView.swift` recording label `.red` -> `Theme.failed` (the last grep hit).
    `Views/Goals.swift`: Delete and Finish goal are secondary pills. `Views/MenuBar.swift`: "Open Schermes" gets the
    ⌘O hint and a working ⌘O. `Views/ConsoleView.swift`: the selected goal row's fill spans the row.
    `Views/Activity.swift`: Mac list gets a 14pt side inset.
- Verification: `pnpm check` 0, `pnpm test` 0 (306). macOS `xcodebuild test-without-building` (render env unset) 0,
  215 tests, front polls 0. iOS `xcodebuild test` on a private iPhone 17 Pro sim (iOS 26.5, deleted after) 0, 207 tests.
- Notes / leftovers: the faint vertical ticks at the ends of the goal's outline pill are in the slice-1 render too.
  Likely a `cacheDisplay` artefact, so check it on the real app. Kept items, each with a reason: state wording, menu bar row size and
  "Pick an agent", Needs you rule subline / Watch screen, goal result tiles, search top-hit preview.
- Placeholder choices: Goal Delete/Finish both secondary (Delete keeps its confirmation dialog); "⌘O" hint text in
  `Theme.muted`; Activity inset 14pt.
- Runtime-unverified: ⌘O in the real menu bar panel; the new goal pills and Activity inset only in renders.
