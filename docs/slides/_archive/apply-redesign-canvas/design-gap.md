# Design gap: canvas vs the app as it renders (2026-10-01)

Canvas: https://claude.ai/artifact/Ns9Ynh8yTKkCmoPrQESQir (22 artboards; source copies in
`scratchpad/artifact-files/b1105e48-.../project/`). Screens checked live: iPhone 17 Pro simulator
against the bed daemon on :7795 (`sim-home-light.png`, `sim-chat-light.png`, `sim-needs-light.png`).
Mac: not rendered (focus-free rule, lever app unreliable under cua-driver); judged from code. The
owner's own read ("looks like a stock macOS app") matches the code.

## Canvas design language (exact values)

| Token | Light | Use |
|---|---|---|
| window | #efebe3 | Mac window behind the panels |
| ground | #f6f4ef | iPhone screens, chips |
| card | #ffffff, border ink 8% | cards, file rows, routine rows |
| panel | white 66%, 1px white 90% border, shadow 0 1 2 / 0 12 32 ink 6% | Mac sidebar + inspector |
| ink / secondary / muted | #16150f / #4a463e / #6b675e | text |
| hairline | ink 8% | dividers |
| needs you fill / text | #fdeedd (Mac), #fbd9b4 (iPhone strip) / #9a4d00 | Needs you row, chips |
| failed / retrying / done | #fdecea + #b3261e / #8b6818 / #17754d | state |
| agent: tint, bubble, accent, soft | AgentPalette (exists, correct) ; soft = white mixed 16% with base (#f1ebfd for Mo) | thread ground, owner bubble, agent buttons, selected row |

All already in `Views/Theme.swift` except **panel**, **soft** and **needsYou #fdeedd** (only the
iPhone strip fill exists).

Type: SF Rounded for every title and agent name (large title 34 bold, chat agent name 22 bold,
sidebar name 15 bold, section h2 16 bold); body SF Pro 15 (16 iPhone); caption 12; section labels
11 semibold uppercase +0.04em muted; paths SF Mono 12.

Shape: Mac panels r22 with 10px gutters and 10px window padding; cards r16–20; rows r12–14; chips
r9–10; owner bubble r20/20/**6**/20 (tail corner). Buttons are pills, h36 r18 13 semibold, six
kinds: Primary ink, Agent action (bubble colour), Secondary ink 6%, Outline (white, agent-accent
border/text), Soft (agent soft + accent text), Destructive #b3261e. Small variant h28–32.

Icons: stroke 1.8 line icons (SF Symbols are the right substitute).

## Per screen

### Mac window shell (biggest gap)
- Canvas: no visible titlebar; window #efebe3; three floating panels: sidebar 292pt white-66% r22,
  chat panel in the agent's tint r22, inspector 340pt white-66% r22; traffic lights sit inside the
  sidebar panel.
- App: stock `NavigationSplitView` with system glass sidebar, system `.inspector`, system toolbar
  and window title (`ConsoleView.swift:194`, `:249`, `.navigationTitle("Agents")` `:397`). Theme
  ground only on the detail (`:245`); the sidebar list keeps system background on macOS on purpose
  (`:389-393`, `#if os(iOS)` only).
- Change: `.windowStyle(.hiddenTitleBar)` / `.toolbarBackgroundVisibility(.hidden)` +
  `.containerBackground(Theme.window, for: .window)` on the console `WindowGroup`
  (`SchermesApp.swift:79`); sidebar `List` `.scrollContentBackground(.hidden)` on macOS too, wrapped
  in a panel background; detail and inspector content padded and clipped to r22 panels.

### Mac sidebar
- Canvas: "Search or ask ⌘K" field-look row (ink 6% fill, r10); Needs you as a filled row (#fdeedd,
  orange icon tile r10, ink count capsule); uppercase 11pt section labels; agent rows: bloub 34,
  name 15 rounded bold, state line, count capsule in the agent's bubble colour; selected row = agent
  soft fill r14, not system accent; helpers indented 26pt in 12pt; bottom: ink "New agent" pill +
  round Settings button.
- App: system `Label`s, `.badge(needs.count)` (`ConsoleView.swift:338-344`), system `Section`
  headers, system blue selection, `AgentRow` bloub 44 with blue `UnreadDot` (`:925-970`), "New
  agent" as a toolbar `+` (`:414`).
- Change: custom rows + `.listRowBackground` keyed to selection, `.listRowSeparator(.hidden)`,
  custom section header view, bottom bar via `.safeAreaInset(edge: .bottom)`.

### Mac chat + header
- Canvas: header in the panel: bloub, name rounded 22 bold, state line; glass context pill "62%";
  one capsule holding 4 icon buttons (routines, memory, settings, inspector; active one soft agent
  colour). Day dividers as hairline-label-hairline; "New" divider in agent accent; owner bubble with
  tail corner; agent text unboxed; cards white r16 with hairline; feedback icon row; worker chips
  and floating composer (white 86% r26) centred max 760.
- App: thread tint and flat bubble are done (`ChatView.swift:289`, `:1578`), composer is glass
  (`:819`). Header is a system toolbar principal "pill" (`:555-575`) plus separate toolbar items;
  bubble uses uniform r20 (`:1578`); date stamps are a grey capsule (sim screenshot) not the hairline
  divider.
- Change: `UnevenRoundedRectangle` for the bubble; on macOS put the header in the content (hidden
  toolbar) as the canvas draws it; day divider view.

### Mac inspector
- Canvas: sections with rounded 16 bold h2; Screen thumbnail r14 on dark #2a2640 with a 2pt
  needs-you ring and a PAUSED chip; full-width "Take control" agent-action pill + round pop-out
  button; goal block with ring + helper cards (white r14); routine cards with soft icon tile;
  "Ask Mo to set one up" soft pill.
- App: `Views/Inspector.swift` uses no Theme token at all; system inspector column, system buttons.
- Change: restyle sections/cards/buttons; panel background.

### Needs you (Mac and iPhone)
- Canvas: cards white r20, header with bloub + name + bell state; buttons pills (Don't = secondary,
  Approve = agent action in the agent's colour, Delete = destructive #b3261e, Retry = primary ink).
- App (sim): card layout is close. Buttons are system `.bordered`/`.borderedProminent` →
  system grey and **system blue/red** (`NeedsYou.swift`, 14 sites). Large title "Needs you" is SF
  Pro, not Rounded. Agent name not rounded in the card header.

### Goals
- Canvas `MacGoal`/`PhoneGoal`: progress ring, step list with owner bloubs, helpers with dashed
  outline. App `Goals.swift` already uses Theme 30× and palette 4×; buttons system (5 sites). Medium gap.

### Settings, Rules, Idle, Routines, Profile, Forms, Forward, sheets
- Canvas `MacSettings`: custom page in the window panels, cards on ground, segmented 4-level rule
  pickers in pills.
- App: 16 stock `.formStyle(.grouped)` forms (Settings.swift ×6, Rules, Idle, Routines, Profile,
  Memory, Forms, Forward, About, Share, ChatView:1289) → grey grouped look, system toggles and
  pickers. Settings is a separate system `Settings` scene.
- Change (cheap, most of the win): `.scrollContentBackground(.hidden)` + `.background(Theme.ground)`
  and `.listRowBackground(Theme.card)` via one `View.themedForm()` modifier; pill buttons.

### Menu bar panel
- Canvas: r18 panel #fbfaf7 with shadow; input row white r12 with ⌥Space mono hint; uppercase
  section labels; Needs you rows on #fdeedd r12 with small pills; Working rows with 22pt bloubs and
  elapsed time; "Open Schermes ⌘O" footer.
- App `MenuBar.swift` uses Theme 8×; not rendered. Likely buttons/system list styling; check.

### iPhone home
- Canvas: left-aligned large title "Agents" rounded 34 + round settings button; Needs you strip
  (done, matches); goal cards row (white r18); **one card per agent in its own tint** (r20, bloub
  48, name rounded 17, label, state line, last line, count capsule in bubble colour); floating
  bottom bar: search field (white 86% r26) + ink round "+".
- App (sim): inline centred title, top search field, `+` top-right, lone gear bottom; agents in one
  white inset-grouped list with separators (`ConsoleView.swift:519` rows, list styling `:389-401`);
  blue unread dots (system accent).
- Change: `.listRowBackground(palette.tint in r20)`, `.listRowSeparator(.hidden)`, row spacing via
  `listRowInsets`/`listSectionSpacing`; large rounded title (UINavigationBar appearance with a
  rounded font descriptor, or own header); move search + new into a bottom `safeAreaInset`.
- Failed agents (Mo, Pixel) render as a bare coloured "!" with no body
  (`Bloub/AgentBloub.swift:16` `.failed: .exclaim`); canvas keeps the bloub with crossed eyes and
  puts the warning in the state line. Identity is lost on the home list. Verify intent.

### iPhone chat
- Close to the canvas (tint ground, bubble colour, glass header pill and composer). Gaps: bubble
  tail corner; date capsule vs hairline divider; system-blue elements elsewhere.

## Global
- **Accent/tint**: no app-wide tint; system blue shows in unread dots, links, toggles, selection,
  prominent buttons. 42 `.tint(`/accent uses are local. Set an ink tint at the root
  (`SchermesApp.swift`) and the AccentColor asset; agent-scoped views tint with the palette.
- **Buttons**: 45 system `.bordered*` sites across 10 files. One `PillButtonStyle(kind)` in
  `Theme.swift` replaces them.
- **Rounded titles**: `.fontDesign(.rounded)` is applied in ~20 places by hand; nav/large titles
  aren't rounded anywhere.

## Ranked by visual impact
1. Mac window shell: panels on #efebe3, hidden titlebar, no system glass (`ConsoleView.swift:194-249`, `SchermesApp.swift:79`).
2. Mac sidebar rows, Needs you row, section labels, selection, bottom bar (`ConsoleView.swift:330-520, 925`).
3. System blue/grey/red buttons everywhere → six pill styles (45 sites, `NeedsYou.swift` first).
4. No app tint: blue dots/links/toggles (`SchermesApp.swift`, `UnreadDot`).
5. Mac inspector unstyled (`Inspector.swift`).
6. Grouped grey forms for Settings/Rules/Idle/Routines/sheets (16 `.formStyle(.grouped)`).
7. Mac chat header in the system toolbar instead of the panel header with icon capsule (`ChatView.swift:555`).
8. iPhone home: one white list instead of tinted per-agent cards; top search; inline title (`ConsoleView.swift:389-420, 519`).
9. Large titles not SF Rounded (Needs you, Agents, Settings).
10. Failed bloub loses its body; bubble tail corner; date divider (`AgentBloub.swift:16`, `ChatView.swift:1578`).

## Unwise or impossible in SwiftUI, with substitutes
- Fully custom three-panel window: don't replace `NavigationSplitView` (loses collapse, resize,
  iPad behaviour). Style it: hidden titlebar + window container background + clear list/inspector
  backgrounds + inset rounded panel backgrounds.
- Traffic lights drawn inside the sidebar panel: with a hidden titlebar the real ones land at the
  sidebar's top-left; just pad for them.
- White-66% translucent panels: over a solid window there's nothing to see through; use solid
  `Theme.card`-ish panel colour (light #fbfaf7, dark #232127), not `Material`.
- Rounded navigation large titles: no SwiftUI API; on iOS use `UINavigationBar.appearance()` with a
  rounded `UIFontDescriptor`; on macOS hide the title and draw the header in content.
- Menu-bar panel shadow/radius: `MenuBarExtra(.window)` owns the panel chrome; style the content only.
- Canvas dark values exist only for palette/ground/ink; panels, soft, needsYou #fdeedd need dark picks.

## Proposed slices
1. Foundations in code: `PillButtonStyle` (6 kinds + small), root ink tint + AccentColor, panel/soft/needsYou tokens, section-label and card modifiers, `themedForm()`; sweep all 45 `.bordered*` sites. Golden/snapshot test of the button styles.
2. Mac shell + sidebar: hidden titlebar, window ground, rounded panels for sidebar/detail/inspector, sidebar rows/Needs you row/section labels/selection/bottom New agent + Settings.
3. Mac chat header in-panel + icon capsule, bubble tail, day dividers, inspector restyle.
4. Forms and sheets: apply `themedForm()` to the 16 forms, Mac settings page per `MacSettings`, segmented rule pickers.
5. iPhone home: tinted agent cards, large rounded titles, bottom search + new bar, failed-bloub decision.
6. Needs you, Goals, Search, menu bar polish against their artboards, light + dark, plus a screenshot pass (sim; Mac via lever app or owner).
