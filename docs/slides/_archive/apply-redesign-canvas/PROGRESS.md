# Progress: apply-redesign-canvas

## Current state
- `Views/Theme.swift`: tokens (+ `panel`, `needsYouSoft/Fill/Tile`, `onInk`, `hairline`, `screenFrame`), `AgentPalette`
  (`soft` fill, `softText`), `PillButtonStyle` (`.pill(.primary|.agent(c)|.secondary|.outline(c)|.soft(c)|.destructive)`,
  `round:`, height from `.controlSize`), `ThemedForm { }`, `Text.formHeader()`, `Font.sectionTitle`, `Font.pageTitle`
  (Mac 34 / iOS `.title`, rounded bold), `Font.canvas(size, style)` (Mac point size; iOS Dynamic Type style). Mac text
  styles run tiny (subheadline 11), so canvas sizes go through `.canvas`.
- Forms: every `Form` is `ThemedForm`; only Theme.swift and Share.swift's extension branch use `.formStyle(.grouped)`.
  macOS grouped sections keep the system fill (`listRowBackground` ignored; recorded differs).
- Sheets: `role: .confirm` toolbar buttons, `.presentationBackground` per sheet.
- Mac shell: hidden title bar, `Theme.window`, `MacPanel` r22 / `.macPanel` (`Views/Sidebar.swift`), sidebar rows are
  Buttons (`ConsoleView.pickRow`), `SidebarLabel` (cross-platform). Mac branches use `#if os(macOS)`, never `roomy`.
  Sidebar and iPhone card counts exclude `.failure` items.
- Mac chat header = `.safeAreaInset(edge: .top)` in `ChatView.header`; iOS toolbar only `#if os(iOS)`.
- iPhone home: `PhoneAgentCard`, `PhoneHomeBar`, `.largeTitle` toolbar title (works on the list root only).
  Pushed iPhone pages (Needs you, goal): `ToolbarItem(.topBarLeading)` title or lead line beside the back button,
  `.toolbar(removing: .title)`, inline mode. `UINavigationBar.appearance()` fonts are ignored on iOS 26.
- Failed bloub: `BloubStateId.failed` (X eyes), used everywhere `AgentState.failed` shows.
- Two-column pages (`NeedsYouPage`, `GoalPage`) switch by width with `onGeometryChange`, not `ViewThatFits`. On the Mac,
  wrapped Text in those cards needs `.fixedSize(horizontal: false, vertical: true)` or it clips to one line.
- In-chat action cards (form, trigger, interview, hand-over, browser hang) use `actionCard(bubble)` in ChatView:
  white r20, 1.5pt agent-bubble border at 45%, soft shadow (FlowTriggers / FlowSignIn). `DaySeparator` is relative
  ("Today").
- `NeedsYouCard(compact:)` = menu bar row. `ResultRow(top:)` serves ⌘K and the iPhone search section.
  `FileKind.tint` is a `BloubColorId`.
- **Colour grep** (empty): `grep -rnE '#[0-9a-fA-F]{6}\b|0x[0-9a-fA-F]{6}\b|Color\.(blue|red)|\.(blue|red)\b|accentColor|glassProminent'
  apple/Schermes/Views | grep -v Views/Theme.swift | grep -v 'BloubColorId\.'`
- **Verification:** `xcodebuild test -scheme Schermes -destination 'platform=macOS' -derivedDataPath <own>` from `apple/`
  plus the full suite on a private iPhone 17 Pro sim; `pnpm check`, `pnpm test`. New files need `xcodegen generate`.

### Screenshot method (focus-free, works)
- Bed: `sqlite3 .backup` of `scratchpad/bed` (owner `test1234`) + `master.key`, `DELETE FROM sessions`, then
  `SCHERMES_PORT=<spare> SCHERMES_DATA_DIR=<copy> node src/main.ts` from `daemon/`. `scratchpad/bed6` adds a goal.
- DEBUG levers `-schermes.debugOpen`: `needs-you | goal:<id> | agent:<n> | search:<q> | pages:<n>:<Page> | new-agent |
  menu-bar (Mac sheet) | settings` (+ `-schermes.settingsTab`).
- iPhone: own sim + own `-derivedDataPath`, `simctl ui <udid> appearance`, `simctl launch --terminate-running-process
  ... -schermes.serverAddress 127.0.0.1:<port> -schermes.debugPassword test1234`, sleep 8, `simctl io screenshot`.
  Notification prompt: tap Allow (275,518) via idb + XShim companion on your own port.
- Mac: Debug build copied to `~/Applications/SchermesLever<N>.app` + `lsregister -f`; cua-driver `launch_app`
  (`creates_new_application_instance`, a `session` label, `-ApplePersistenceIgnoreState YES`,
  `-NSRequiresAquaSystemAppearance YES` for light); window ids from CGWindowList (sheets are their own window);
  `get_window_state(include_accessibility_tree: false, screenshot_out_file:)` (file lands a second later).
  Cleanup: kill the pid, `lsregister -u`, delete the copy, stop the daemon, delete the sim.
- **Mac renders are blocked on this Mac since slice 7:** cua-driver sees no AXWindow for the lever pid and
  ScreenCaptureKit plus `screencapture` both fail, with every TCC grant green. Mac checks are owner sign-off (`[user-gated]`).
- **Status (slice 8):** DoD met except the `[user-gated]` owner sign-off; next step is `/complete`.

## Slice: 1 — Foundations (2026-10-01)
**Shipped**
- `Theme.panel`, `Theme.needsYouSoft`, `Theme.onInk`; `AgentPalette.soft`, `AgentPalette.softText`.
- `PillButtonStyle` (six kinds, round variant, controlSize heights, Dynamic Type) and `View.themedForm()`.
- Root ink tint on all four scenes and an ink AccentColor asset.
- All 45 `.bordered`/`.borderedProminent` sites replaced (NeedsYou, Forms, Restore, Goals, NewAgent, Idle,
  Interview, Triggers, ChatView, BloubPicker); trailing `.tint`/`.foregroundStyle(Theme.ground)` removed.
  Also restyled the unstyled neighbours of those buttons (BloubPicker Reset, NewAgent Cancel) and ChatView's
  `.glassProminent` "Set up" button. ChatView's `.accentColor` fallbacks are now ink.
- Idle Send is the secondary circle (canvas); enabled Send is the agent bubble; Stop is a destructive circle.
- Shots: `shots/slice-1/` iPhone and Mac, Needs you and chat, light and dark, with `NOTES.md`.

**Key decisions**
- Kind mapping from the boards: deny/keep/open/back/skip/dismiss = secondary; approve/finish/turn on (agent's
  own) = agent; Always allow = outline; Keep helper as agent = soft; retry/answer/fill/take screen/next =
  primary; delete (with confirmation) = destructive. Trigger proposal "Delete" is secondary, as FlowTriggers
  pairs "Change" (secondary) with "Turn it on".
- Approve whose daemon role is destructive gets the destructive pill.

**Notes / leftovers**
- `Views/Files.swift:47` (`tint: .blue` for documents) and `Views/Settings.swift:45` (`.web: .blue`) still use
  system blue; fold into the slice that owns those screens.
- `Entry.swift` login buttons still `.glassProminent` (now ink via the tint); restyle with the gate screens.
- macOS tests were compile-checked (`build-for-testing`) only: running the Mac test host takes focus.

**Placeholder choices** (canvas has no value; owner to review)
- `Theme.panel` dark `#1c1b20` (between window `#0f0e12` and card `#232127`, muted text 7.0:1).
- `Theme.needsYouSoft` dark `#33261b` (needs-you text 7.3:1).
- `Theme.onInk` dark `#16150f`, so destructive in dark is `#ff8a80` with dark text (8:1); white on it is ~2:1.
- Soft fill: boards hard-code `#f1ebfd` (violet) and `#fdf3d9` (amber), but the Colours script gives `#ece5fe`
  and `#fdf3dd`; no single ratio reproduces the boards, so the script wins. `softText` for violet is a step
  darker than the boards' `#6a42d0` to hold 4.5:1.
- Outline border: agent bubble at 45% opacity (canvas violet `#c9b6f7` is ~44% bubble on white); neutral
  outline uses ink 20%.
- Pressed state opacity 0.7, disabled 0.4 (no canvas specimen).

**Runtime-unverified**: the macOS test run (compile-checked only); pill buttons under macOS Full Keyboard Access
(focus ring with a custom `ButtonStyle`); pressed and disabled states beyond the idle Send; pills on the menu bar
panel and the sheets (their slices).

## Slice: 2 — Mac shell and sidebar (2026-10-01)
**Shipped**
- Hidden title bar, `Theme.window` container background, window toolbar background hidden.
- Three r22 panels: sidebar and inspector on `Theme.panel` with a soft shadow, detail masked to a panel (agent tint
  in a chat, ground on pages); 10pt window padding and gutters; traffic lights on the sidebar panel.
- Mac sidebar (`Views/Sidebar.swift`, `ConsoleView` macOS branches): "Search or ask ⌘K" field row, Needs you row with
  tile and ink count capsule, uppercase 11pt +0.44pt section labels, agent rows (bloub 34, rounded 15 bold, 12pt
  state line, count capsule in bubble colour, unread dot when no count), helpers indented 26pt at 12pt, soft-fill
  selection, bottom ink "New agent" pill (h40, ⌘N) + round Settings. Toolbar `+` removed on the Mac.
- Rows became Buttons so the List draws no selection; arrow keys via `onMoveCommand`; selected AX trait.
- Sidebar ideal width 292 (board), min 220 kept.
- Shots: `shots/slice-2/` chat and Needs you, light and dark, with `NOTES.md`.

**Key decisions**
- `NavigationLink` + `.listRowBackground` was tried first: the List's own highlight drew over and beyond the soft
  fill (visible even in the inactive window), so the Mac rows are Buttons. Accepted cost: type-to-select in the
  sidebar is gone; up/down arrows are re-implemented.
- Count capsule = that agent's pending Needs you items; the unread dot stays when there are none, so the unread
  signal survives.
- Detail panel uses `.mask` (ignoring the top safe area) instead of `.clipShape`, so the panel starts 10pt from the
  window top and the chat still scrolls under the floating toolbar.

**Notes / leftovers**
- The chat's toolbar items (title pill, meter, export, inspector toggle) float over the detail panel's top: slice 3
  moves the header into the panel.
- The sidebar toggle is the system toolbar button at the sidebar's top-right; the board has none. Kept for collapse.
- Goals, helpers, shared threads and workers render via the new rows but were not in the bed: not seen in a shot.
- `Views/Files.swift:47` and `Views/Settings.swift:45` still use system blue (from slice 1).

**Placeholder choices**
- Agent state line with pending items reads "Needs you" (bell icon, needs-you colour), not the board's
  "Needs you · payment": the daemon's item titles are sentences and truncate to nothing at 240-292pt.
- Picked Needs you row deepens to `needsYouFill`; picked goal, group or worker row uses ink 6% r12 (no agent colour).
- Needs you tile glyph `bell.fill`; tile `#f08a24` in both modes with `#16150f` glyph.
- Panel shadow: black 6%, radius 16, y 6 (approximates the board's two-layer ink 6% shadow); no white border.
- Helper row: bloub 20, name semibold secondary, state word muted (board shows a status phrase).

**Also verified**: ⌘N sent as a background hotkey opened the New agent sheet (AX sheet with Cancel).

**Refusals (auto-mode classifier)**: a screenshot of the lever window after `bring_to_front` was refused (not
retried; every check after that stayed in the background). A `grep` listing the `NavigationLink` sites in
`ConsoleView.swift` was refused; the `pickRow` replacement was made from the file as read earlier, without reading
it again.

**Side effect for the owner**: the lever copy shares the bundle id, so the 1440x900 window frame it ended with
was saved in the shared `dev.schermes.Schermes` defaults. The owner's own Schermes window may open at that size.

**Runtime-unverified**: the active (key) window, since screenshots of a foregrounded window are refused; arrow-key
movement (a background Down press on a row did nothing, which is inconclusive on an inactive window; a click on a
plain Button row may not give the List focus, and then `onMoveCommand` never fires) and Tab focus through the sidebar buttons; Full Keyboard Access focus rings on the custom rows; VoiceOver
speech (AX labels were read back); sidebar resize by dragging.

## Slice: 3 — Mac chat header, chat polish, inspector (2026-10-01)
**Shipped**
- Mac in-panel chat header (`ChatView.header`): bloub 44 + rounded 22 bold name + 13pt state line; context pill
  (h36, card 72% / 95% border, 20pt ring, 12pt "62%"); one icon capsule (Routines and triggers, Memory, settings
  menu, inspector toggle with soft active fill). Mac toolbar items removed; iOS toolbar unchanged.
- Owner bubble tail corner (20/20/6/20), hairline day divider, "New" divider in the agent accent (both platforms).
- Inspector: "Screen" section title, r14 `screenFrame` bezel with r8 inner screen, PAUSED chip and 2pt needs-you
  ring when a non-failure Needs you item holds the agent, full-width agent "Take control" pill (sets control, then
  opens the desktop) + round pop-out. `AgentPages` overview as white r14 cards with soft icon tiles; page header
  restyled (no `.bar`, no Divider); the Model picker sits in a labelled row with `Theme.failed` errors.
- Inspector ideal width 250 → 340 (board). `ContextMeter` ring 20pt, 12pt label.
- Shots: `shots/slice-3/` Mac chat light/dark, Mac PAUSED inspector (Juno), iPhone chat light/dark, `NOTES.md`.

**Key decisions**
- Header below the toolbar strip (allowed by the slice): content under the window's title-bar area is not reliably
  clickable, and the sidebar toggle and traffic lights live there.
- Export moved into the settings menu (permanent agents) or stands alone in the capsule (workers, shared threads),
  keeping the board's four icons. Name and appearance is both the header title button and a menu item.
- PAUSED = any Needs you item for the agent except a failure.
- `AgentPages` overview became cards on both platforms, which also restyles the `RoutinesAndActivity` sheet.

**Notes / leftovers**
- The board's inline inspector sections (goal helpers, routine cards, "Ask Mo to set one up") are not built: the
  inspector keeps its page list. Would be a content change, not just styling.
- `ChatView.swift:760` composer error text still uses `.red`; chat cards (trigger card, tool runs) still use system
  grey fills. `Views/Files.swift:47`, `Views/Settings.swift:45` still system blue (from slice 1).
- Day stamps show the date ("30 Sep 2026"), not the board's "Today".

**Placeholder choices**
- `Theme.screenFrame` `#2a2640` in both modes (board light only).
- Header pills in dark: card `#232127` at 72% fill / 95% border (no canvas dark value).
- "New" rule is the accent text at 45%, not the board's `#c9b6f7`.
- Settings icon is a menu (Profile, Rules, When idle, Name and appearance, Export) rather than a link to one page.
- Take control ignores a failed `setControl` and still opens the desktop, where the control button shows the real
  state.
- Inspector page-list cards keep their existing copy; no section title over them.

**Side effect for the owner**: the lever shares the `dev.schermes.Schermes` defaults, so its split-view frames
(inspector width) were saved there, and `threadLastSeen` now holds bed keys (`agent:mo` 26, `agent:juno` 97, ...).
None of those names is one of the owner's agents, so no real unread dot changed.

**Runtime-unverified**: the Export share picker (background menu press shows none; item present and enabled); Take
control and the pop-out (bed has no desktop); the header with the sidebar collapsed (not shot this slice); the
group-thread and worker header variants (not in the bed); keyboard focus on the header buttons.

## Slice: 4 — Forms and sheets (2026-10-01)
**Shipped**
- `ThemedForm { }` replaces `themedForm()`; all 16 app forms use it (Settings ×6, Rules, Idle, Routines, Profile,
  Memory, Forms, Forward, About, Feedback, plus Share's `SendToSheet` outside the extension). `Text.formHeader()`
  on every section header (Mac rounded 16 bold ink, iOS caption bold uppercase muted).
- Rules: Mac 4-level segmented pills (track ink 5% r14, segment 96x30 r10, picked = agent bubble, Hand to you =
  ink); compact rows and the locked row stack under the name when narrow (Mac); verbatim pre-approved prompt.
- Pills: Save / Revert / Cancel / Edit / Interview (Memory, Profile), Turn back on (Idle), Add routine, Settings'
  Save, Add model, Add server, Test / Edit / Delete, Send test push, Use a different daemon, Log out (destructive),
  Fill from snippet, Add secret.
- Sheets: `role: .confirm` toolbar buttons; `presentationBackground` on Settings, Model, Server, Forward, Forms,
  Feedback, pages (ground), Restore (panel), New agent and Agent look (identity tint). New agent per PhoneNewAgent:
  Cancel / title header, rounded bold question, white fields, suggestion card, full-width ink Create (large).
  Agent look: rounded title2 name, tint ground. Activity list on ground.
- Colours: system red → `Theme.failed` (Profile, Routines, Settings, Memory, NewAgent, BloubPicker, Activity, composer
  error); `.secondary` → `Theme.muted` in the touched pages; Settings tiles = `BloubColorId` soft / softText.
- DEBUG lever `-schermes.debugOpen new-agent` (`ConsoleView.openLaunchTarget`).
- Shots: `shots/slice-4/` (iPhone Rules + New agent, Mac Settings, Rules sheet, inspector Rules, New agent) with NOTES.

**Key decisions**
- `ThemedForm` is a container, not a modifier: row colour only reaches the rows through a `Group` inside the Form
  (probed on the sim; `.listRowBackground` and `.backgroundStyle` on the Form do nothing).
- The tint stays out of `ThemedForm`: the root is ink already, and Rules / Idle tint in the agent's colour.
- macOS: no API colours grouped-form sections (probed Group / Section / row `listRowBackground`, `backgroundStyle`,
  `backgroundProminence`). Accepted the system fill rather than rewriting 16 forms as custom layouts.
- iOS locked rule row stays a plain HStack: a `ViewThatFits` there sized the row to 260pt and hid it.

**Notes / leftovers**
- Mac sheet toolbars' Done / Save / Cancel stay system buttons (`role: .confirm` is prominent only on iOS 26).
- `Share.swift:164` still `.red` (compiled into the extension too); `Views/Files.swift:47` `.blue` and the
  `Entry.swift` / `Markdown.swift` / `Files.swift` reds belong to later slices.
- The MacSettings board's two-column agent settings page (rules + routines/idle aside) is not built: Rules, Idle,
  Routines stay separate pages.

**Placeholder choices**
- Settings tiles: Models violet, Web blue, Notifications red, Plugins orange, Daemon grey, About teal (canvas
  palette, soft fill + softText, r9) instead of system gradients.
- Segment width 96 (board 100), pages sheet min width 680 on the Mac, New agent and Agent look sheets on the
  identity tint (PhoneNewAgent shows the agent tint), Restore on `Theme.panel` (board `#fbfaf7`).
- Mac Form section headers in ink rounded 16; iOS headers uppercase caption bold with 0.5 kerning.

**Side effect for the owner**: the lever shares `dev.schermes.Schermes` defaults, so its split-view / inspector widths
and `threadLastSeen` bed keys were written there (as in slices 2 and 3).

**Runtime-unverified**: the real Mac `Settings` window and tab chrome; the iOS `SettingsSheet` list; Forward,
Restore, FormSheet, Feedback, Agent look, trigger proposals and the Mac "Send to Schermes…" window (themed, not
opened in a render).

## Slice: 5 — iPhone home (2026-10-01)
**Shipped**
- iPhone home cards: one r20 card per agent in its `AgentPalette.tint`, bloub 48, rounded bold name (body) + tagline
  (caption), state line, last line (footnote), count capsule in the bubble colour or the ink unread dot. No
  separators, 8pt gaps, cards at the 16pt list margin; helpers, shared threads and workers sit on the ground too.
- Large rounded "Agents" title (`.largeTitle` toolbar placement) + round settings button (⌘,) top right.
- Bottom bar (`safeAreaInset`): search capsule (card 86%, white border, shadow, h52, clear button, Return asks) + ink
  round "+" (⌘N). The `.searchable` field, toolbar `+` and bottom gear are gone on the phone; iPad keeps them.
- Needs you strip: chevron moved inside (the row's own indicator is hidden now).
- Failed bloub: new `.failed` state = the agent's own body, near-frontal gaze, X eyes (holes like every eye).
- Shots: `shots/slice-5/` iPhone home light/dark, search (dark), iPad split view, with `NOTES.md`.

**Key decisions**
- Kept `NavigationLink` and hid the chevron with `navigationLinkIndicatorVisibility(.hidden)`; tap pushes, back pops
  (checked with idb).
- `previewLine(_:)` is now a free function shared by `AgentRow` and `PhoneAgentCard`.
- Bloub tests changed only where the change has to: catalogue count (16, non-sequence `[.swirl, .failed]`, test renamed)
  and the failed mapping. No goldens regenerated.

**Notes / leftovers**
- Mac sidebar still counts failure items in its "Needs you" line and capsule (`SidebarAgentRow`), so a failed Mac agent
  with a failure item says "Needs you" rather than "Failed"; the iPhone card excludes failures. Worth aligning in slice 6.
- Mac shots from slices 2-3 show the old "!" for failed agents; they now show the X-eyed body.
- Rounded large titles did NOT come for free on other iOS screens (appearance proxy ignored): Needs you, Goals and
  Settings need their own `.largeTitle` toolbar item in slice 6.
- `BloubView.swift` holds hex literals (paper defaults, ink/cream tweaks); it is in `Bloub/`, outside the DoD grep.

**Placeholder choices**
- Failed face gaze yaw 10 / pitch 8 / split 17; X arms 0.87 x eye height, 0.6 x eye width.
- Bottom bar shadow black 10% r14 y8; search text `.callout` (canvas 16).
- Card state line with pending items: "Needs you" (no detail), as on the Mac.

**Runtime-unverified**: the bottom bar with the software keyboard up (sim used the hardware keyboard); Dynamic Type at
large sizes on the cards; VoiceOver reading of the card and the large-title header; the goal cards row (no goals in
the bed).

## Slice: 6 — Needs you, Goals, Search, menu bar, leftovers (2026-10-01)
**Shipped**
- Needs you: cards per MacNeedsYou/PhoneNeedsYou (bloub 40/34, bold 15 headline, subline "agent · state word · time",
  detail on the agent's soft fill or ground, Mac pills trailing, iPhone pills equal width), 390 aside, canvas font
  sizes in "Right now" and "Last night" (`Idle.swift` fonts only). iPhone title rounded beside the back button.
- Goal page: lead tint ground, two columns at >= 800pt (plan + results | next from you, on it, actions), `StepMark`,
  owner dots, result cards, helper chips and "Lead's choice" box, keep link, outline "Open <lead>'s thread". iPhone: lead
  line + ring in the toolbar row. Goal card 170 wide, ring 10.5; sidebar goal row in canvas sizes with ink title.
- Search: `SearchPanel` on `Theme.panel` with 20pt field, `esc`, hairlines, amber chips, top hit on amber soft, "Also
  close" label, footer; `ResultRow` restyled (kind tile, headline, "kind · who · place", time), shared with iPhone.
- Menu bar panel: canvas input well, section labels, compact Needs you rows (`NeedsYouCard(compact: true)`), working
  rows, hairline + "Open Schermes" footer (opens the console like Open did).
- Login/connect gate: pill primary buttons, solid r12 fields (panel fill, ink 12% border), rounded title, ground fill,
  `Theme.failed` errors. No `.glassProminent` left.
- Leftovers: `FileKind.tint` → palette ids (soft/softText tile), Files/Markdown reds → `Theme.failed`, Settings tiles
  spelled `BloubColorId.*`, `Share.swift` error colour via `troubleColor` (`Theme.failed` in the app, `.red` in the
  extension branch, which has no Theme). Mac sidebar count/capsule exclude `.failure` items.
- DEBUG lever `menu-bar` (Mac). Shots + NOTES in `shots/slice-6/`.

**Key decisions**
- No `.largeTitle` placement on pushed iPhone pages (ignored in the detail column, checked on the sim); leading toolbar
  title instead, which is also the board's layout.
- Menu bar rows keep every in-place answer (Don't / Always allow / Approve); with two or more they wrap under the text.
- No new buttons from the boards that would be features (Search's Open / Show / Send to, Goal's "Review payment").

**Placeholder choices**
- File kinds: purple → violet, indigo → teal, gray → grey; sizes 36 tile r9.
- Detail fill: approval → agent soft, else ground. Results tile: green palette soft/softText with a tick.
- Goal two-column breakpoint 800pt; aside 340. Menu bar width 370, rows r12 padding 8.
- Mac title tracking -0.7 (board -0.02em).

**Notes / leftovers**
- Mac two-column `ViewThatFits` clipped wrapped Text to one line: both pages now switch by width, and the Last night
  note / routine prompt plus the goal helper texts carry `.fixedSize(horizontal: false, vertical: true)`.
- `NeedsYouPage` is now inline title mode on iPad too (it was default); iPad keeps its in-content header. Not rendered.

**Side effect for the owner**: the lever shares `dev.schermes.Schermes` defaults (window frame, split widths,
`threadLastSeen` keys from the bed), as in slices 2-4.

**Runtime-unverified**: login/connect gate (sim stays signed in via Keychain), the real `MenuBarExtra` window (content
rendered via the lever sheet), iPad Needs you / goal page, Dynamic Type at large sizes on the new screens.

## Slice: 7 — Proof sweep and DoD audit (2026-10-01)
**Shipped**
- Renders, iPhone light and dark: connect and login gate (fresh sim, empty Keychain), iOS `SettingsSheet` list, trigger
  proposal card, form card, Needs you form item, FormSheet, the message long-press menu, Restore, Forward, Feedback,
  Agent look. Notes and the "differs" audit are in `shots/slice-7/NOTES.md`.
- Fixes the renders exposed: the five in-chat action cards swap Liquid Glass r22 for `actionCard` (white r20 +
  agent border, per FlowTriggers / FlowSignIn); trigger Delete / Turn on are equal width at regular size on iOS
  (they hug their labels on the Mac via `.fixedSize()`); `DaySeparator` uses `doesRelativeDateFormatting` ("Today",
  which closes slice 3's unexplained differs); BloubPicker labels `.secondary` → `Theme.muted`.
- Audit: every "differs" across `shots/*/NOTES.md` now has a reason or is resolved (list in the slice-7 NOTES).
  Colour, `.bordered` and `.formStyle(.grouped)` greps are clean (grouped only in Theme.swift and Share's extension
  branch).

**Key decisions**
- Forward stays a sheet: the board's in-menu agent list plus a floating soft composer is a flow change, not styling.
- The trigger header keeps its state-coloured caption (the proposed / on signal) rather than the board's tile.
- FormCard's Fill in… stays primary ink (slice-1 kind mapping), not the board's agent-colour pill.

**Notes / leftovers**
- Bed tricks: a `propose_trigger` card returns by setting the trigger to `proposed` and deleting its "Trigger N is
  on" line; a Needs you form item needs an assistant `request_form` call, a non-error tool result, and a `forms`
  row with the same `call_id`. Use `node:sqlite` to edit the bed (the sqlite3 CLI lacks fts5, which the message
  triggers need).
- The idb CLI's pyenv 3.13.2 interpreter is gone; a scratch venv with `pip install fb-idb` works with the XShim
  companion.

**Refusals / harness**
- The auto-mode classifier refused launching the Mac lever without `-schermes.debugPassword` (the gate path). Not
  retried.
- One later launch with the usual recipe was allowed, but cua-driver returned `ax_window_unresolved` with no
  screenshot. Not escalated to the foreground.

**Side effect for the owner**: the lever launch shares `dev.schermes.Schermes` defaults, as in slices 2-6.

**Runtime-unverified**: Mac renders of the gate, Forward, Restore, FormSheet, Feedback, Agent look, the trigger and
form cards with `actionCard`, "Today", and the Mac New agent in dark. The real Mac `Settings` window can't be opened
focus-free (its pages were rendered via the `settings` lever in slice 4); that is a harness limit, not a gap.

## Slice: 8 — Mac sheet renders (blocked, handed to the owner) (2026-10-01)
**Shipped**
- No code changes. Fresh Debug build (`SchermesLever8`) against a bed7 copy on :7881, launched via cua-driver with
  `debugPassword` + `debugOpen agent:juno` (light). The window existed (CGWindowList: "Juno", 1412x882, on screen), but
  `get_window_state` returned `ax_window_unresolved` (0 AXWindow elements under the pid) and the screenshot failed
  (ScreenCaptureKit "Failed to start stream due to audio/video capture failure"; the `screencapture` fallback "could not
  create image from window"). `health_report`: Accessibility and Screen Recording granted, AX reachable. Retried once
  after settling, same result. Not escalated to the foreground, as the slice said. Cleaned up (pid, lsregister -u,
  copy, daemon). No `shots/slice-8/`.
- DoD item 9 reconciled: the Mac sheet renders move to the `[user-gated]` sign-off, which now lists them explicitly.

**Key decisions**
- Two failed attempts in two slices, the second with all permissions green: this is a harness limit on this Mac, not
  flakiness. Stopped rather than looping.

**Notes / leftovers**
- The owner might find out why capture fails (a stuck `replayd`/ScreenCaptureKit state usually clears after a logout
  or reboot). Only then can a later session render the Mac sheets.

**Runtime-unverified** (owner sign-off): Mac gate, real `Settings` window, Forward, Restore, FormSheet, Feedback, Agent
look, trigger proposal and form `actionCard`s (`.fixedSize()` pills), "Today", Mac New agent in dark.
