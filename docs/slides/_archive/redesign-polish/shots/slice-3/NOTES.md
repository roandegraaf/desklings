# Slice 3: inspector contents

Renders: `mac-main-{agent,mo,bare}-{light,dark}.png` (ONLY=main, bed daemon on 7911). The inspector renders at 340pt.

## Matches Main's `<aside>`
- Padding 16, section gap 18, sections in order: Screen, Goal, Routines and triggers.
- Screen: unchanged (PAUSED chip, thumbnail with the needs-you ring, Take control in the agent colour, round pop-out).
- Goal (Mo, Lisbon): 30pt ring, title in rounded 16 bold, "Goal · 2 of 6 done" in 12 muted, chevron; the whole row
  opens the goal. A helper does not lead, so its row reads "Helping Mo · …".
- Worker rows: white (`Theme.card`) r14, padding 8/10, a 26pt helper bloub, name 13 semibold, live state line in 12.
- Routines (Juno has the proposed IMAP trigger): white r14 cards with a 30pt r9 tile in the agent's soft/softText
  colours, title 13 semibold, detail 12 muted. "Ask Juno to set one up" is a soft agent pill with a bolt.

## Differs
- The board's worker status is free text ("Holding two hotels near Baixa"). The app shows the helper's state line,
  because that is the data it has.
- Schedule cards use the prompt as the title, since a schedule has no name, and "<cadence> · next at HH:mm" (or
  "paused") as the detail. Trigger cards use the reason as the title and "<kind> · <state>" as the detail.
- With no routines and no triggers (Mo), a muted line reads "Nothing scheduled and nothing watched." The board
  always has a card.
- The pill is full width. The board's button also stretches in its flex column.
- Cards open the Routines page as a sheet from the inspector pane.
- The inspector card keeps slice 2's two-layer shadow. Main has none.

## Reachability (former inspector rows → now)
| Former row | Mac | iPad regular / iPhone |
|---|---|---|
| Profile | header gear menu → Profile; sidebar right-click "Profile, routines and activity…" | toolbar ⋯ menu → Profile |
| Rules | gear → Rules; sidebar right-click | ⋯ → Rules |
| When idle | gear → When idle; sidebar right-click | ⋯ → When idle |
| Routines and triggers | header capsule button; inspector cards; `/routines` | ⋯ → Routines and triggers; inspector cards |
| Activity | gear → **Activity (new)**; sidebar right-click; `/activity` | ⋯ → **Activity (new)** |
| Memory | header capsule button; `/memory` | ⋯ → **Memory (new)** |
| Now (state) | chat header state line, sidebar row | toolbar pill |
| Runs as / Model | any page sheet → back chevron "Overview" (⌘[) still shows the Now / Runs as / Model card | same |

The model picker lives only in the page sheet's Overview until the agent settings page lands. That is not one of the
two homes NEXT_SLIDE suggested (gear menu or When idle). Both of those would need new state: a models fetch in
ChatView, or edits to Idle.swift.

iPad: the ⋯ pages menu used to show only without an inspector, so removing the rows would have stranded the pages
there. It now shows with the inspector too, without "Screen" (the inspector is the screen) and without a second
Export item.

## Addendum (from slice 2)
- `SchermesTests/MacSplitTests.swift`, `detailStateAndScrollSurviveARefresh`: a `MacSplit` whose parent re-renders 3×.
  The detail sees ticks 0,1,2,3 with one `@State` token throughout, and the `NSScrollView` stays at y=1000. Passes,
  so no fix was needed: `AnyView` around a stable concrete type diffs instead of replacing.
- Toggle Sidebar: `NSWindow` answers `toggleSidebar:` itself, so a responder relay after the window never ran
  (tried and dropped). `CommandGroup(replacing: .sidebar)` "Toggle Sidebar" ⌃⌘S now posts `.toggleSidebar` with the key
  window; `MacSplitController` toggles when it is that window. Tests: `viewMenuHasToggleSidebar` checks the menu item and
  shortcut, and `toggleSidebarCommandTogglesTheWindowsSidebar` collapses and reopens. The items keep default
  behaviour, so the glass stays gone.
