# Mac audit: canvas boards vs renders (slice 1, 2026-10-01)

Renders: `shots/slice-1/mac-*-{light,dark}.png`, made by `SchermesTests/MacRenders.swift` against the bed
(see PROGRESS `## Current state`). A `.sheet.png` beside a render is the sheet that screen opens. Board values are
from the canvas HTML (`project/<Board>.dc.html`). Sizes are effort: **S** under an hour, **M** a few hours, **L** a
slice or more. "Owner #n" marks the owner's three findings.

## What the renderer can and can't show
- Draws: the whole SwiftUI tree, split view columns, dividers, sheets, light and dark.
- Can't draw what the window server composites. The macOS 26 sidebar and inspector columns sit in an
  `NSGlassEffectView`, so their glass tint and blur are missing: the render puts the column content on
  `Theme.window`. The real app shows *more* of a seam than the render, not less.
- Controls draw as in an inactive window, so the switches in the agent pages come out grey when on. Check the
  accent on the real app before treating that as a gap.
- The Settings window's `TabView` tab strip is garbled, because the render uses a borderless window with no
  toolbar. That doesn't matter: the window goes (Owner #3).

## Cross-cutting (every Mac board)
- [L] **Owner #1, the seam.** `NavigationSplitView` wraps the sidebar and the inspector in their own glass columns,
  each with a 1pt `NSSplitDividerView` and a 12pt `NSSplitViewShadowView` (view dump:
  `slice-1/mac-main-agent-light.views.txt`, dividers at x=291 and x=1219). The renders show a hard line at both
  edges (`#c9c9c9` light, `#0d0d0d` dark), with system grey (`#f1f1f1` / `#1a1a1a`) at the column edges instead of
  `Theme.window` (`#efebe3` / `#0f0e12`). Main draws three floating cards on one ground, with 10pt padding and
  gaps. Fix: hide the column chrome, or move off the split view's column backgrounds, and give every column the
  same 10pt inset. The sidebar has it too: its panel runs flush into the divider, with no gutter on its right.
  `Views/ConsoleView.swift:492-518, 739-765`, `Views/Sidebar.swift:71` (`macPanel`).
- [M] **Panel fill.** Main's sidebar and inspector are `rgba(255,255,255,0.66)` with a `rgba(255,255,255,0.9)` 1pt
  border and a two-layer ink 6% shadow. The app uses `Theme.panel` `#fbfaf7` with no border. In light that's close,
  but the white border is what makes the card read as floating. `Views/Sidebar.swift` (`MacPanel`),
  `Views/Theme.swift`.
- [M] **Fixed (slice 6).** **Sheets use stock chrome.** Every agent page, Settings page and New agent sheet gets a white system toolbar
  strip with a centred title ("Juno") and a stock grey "Done". In dark that strip is system `#1f1f1f`, not
  `Theme.ground`. The boards have no sheet chrome at all. `Views/Activity.swift:315-322`
  (`RoutinesAndActivity`), `Views/Settings.swift`, `Views/NewAgent.swift`.
- [M] **Fixed (slice 6).** **Grouped forms keep the system section fill** (`#ecebe7`-ish on ground), already a recorded "differs" last
  task. The boards draw white r16-20 cards with an ink 8% border. Hits Rules, Idle, Routines, Profile, Memory and
  every Settings tab. `Views/Theme.swift` (`ThemedForm`) plus each page.
- [S] **Pickers fixed (slice 9, `shots/slice-9/NOTES.md`); switches and steppers kept as native controls.** **Stock controls left.** Switches (Idle, triggers), steppers (Idle "Model calls per pass"), pop-up pickers
  (Idle From / Until / Model, inspector Model, menu bar "Pick an agent"). MacSettings uses accent checkboxes for
  idle conditions and plain "label / bold value" rows. `Views/Idle.swift`, `Views/Triggers.swift:257`,
  `Views/Inspector.swift`, `Views/MenuBar.swift`.
- [S] **Fixed (slice 9): the Model row is a `ValueMenu`, no pop-up bezel.** In dark, the inspector's Model pop-up draws a white bezel with unreadable text
  (`mac-main-agent-dark.png`). Possibly the inactive-window artefact; check on the real app.
  `Views/Inspector.swift`.

## Main (`mac-main-agent-*`, `mac-main-mo-*`)
- [L] **Owner #2, inspector contents.** The app lists a "Now / Runs as / Model" card and six page cards (Profile,
  Rules, When idle, Routines and triggers, Activity, Memory). Main's inspector has:
  1. Screen (this part matches);
  2. the goal (ring, title link, "Goal · 2 of 6 done", white r14 worker rows with bloub, name and status);
  3. "Routines and triggers" inline, with white r14 routine cards and a soft agent "Ask Mo to set one up" pill.

  The app already has a cramped `GoalSummary` (title wraps, worker shown as a bare bloub with no name). The page
  cards go. Their pages move to the header capsule and the agent settings page; see the proposal at the end.
  `Views/Inspector.swift` (`AgentInspector`, `GoalSummary`), `Views/ConsoleView.swift:739`.
- [M] **Inspector width.** It renders at 220pt (min), not 340 (ideal), in a fresh 1440pt window. Main is 340.
  `Views/ConsoleView.swift:765`.
- [M] **Fixed (slice 7, `shots/slice-7/NOTES.md`).** **Composer.** The app has a bare "Write to Juno" row with a paperclip on the chat panel. Main has a floating
  capsule (max 760, r26, white 86%, white border, shadow 0 8 28 ink 8%), a round attach button on ink 6%, and the
  placeholder "Message Mo, or / for commands". `Views/ChatView.swift:721`, `:1137`.
- [M] **Fixed (slice 7, `shots/slice-7/NOTES.md`).** **Working helpers above the composer.** Main shows the goal helpers as white capsule chips over the
  composer. The app pins task workers there, but they weren't in the bed, so they weren't rendered. Check the
  styling once a worker is present. `Views/ChatView.swift:50`.
- [S] **Fixed (slice 7, `shots/slice-7/NOTES.md`).** **Tool runs.** The app shows a grey pill ("Called propose_trigger >", "Ran 1 shell command"). Main shows a
  white r16 card with an ink 8% border ("Worked for 3 min · 4 steps", green check, chevron).
  `Views/ChatView.swift:1737` (`ToolRun`).
- [S] **Reply actions** (good / bad / copy / restore, 32pt round) aren't visible under replies in the render. If
  they only show on hover that's fine; Main shows them resting. `Views/ChatView.swift`.
- [S] **State wording disagrees.** The sidebar says "Needs you" for Mo while the header says "Failed". Main's header
  repeats the sidebar line ("Needs you · payment"). `Views/ChatView.swift` (`header`), `Views/Sidebar.swift`.
- [S] **Sidebar.** The selected goal row's fill stops short of the row width (Goal render). The "Messages" section
  and shared-thread rows weren't in the bed, so not rendered. `Views/ConsoleView.swift` (`pickRow`).
- [S] **Traffic lights.** In the render they sit on the window, not on the sidebar card at 2pt / 6pt inside, as
  Main draws them. That's part of the seam fix. `Views/ConsoleView.swift`.

## MacSettings (agent settings page; app: agent pages as sheets, plus the Settings window)
- [L] **Owner #3, settings live elsewhere.** App settings are a separate `Settings` scene
  (`SchermesApp.swift` `Settings {}`), opened by the sidebar gear (`SettingsLink`). The decision: open them as a
  sheet over the main window, keep ⌘, through `CommandGroup(replacing: .appSettings)`, and drop the scene.
  `SchermesApp.swift`, `Views/Settings.swift` (`SettingsWindow`), `Views/ConsoleView.swift` (gear).
- [L] **Agent settings page.** MacSettings replaces the main panel with "<agent>'s settings":
  - header: bloub, 28pt rounded title, "tagline · runs as agent-mo", then "Name and appearance" and "Memory"
    secondary pills;
  - left: Rules as white r16 rows on the ground, a 400pt four-segment track on `#f3f1ec`, a locked "Always yours"
    row, and a soft-agent "Pre-approved" strip with "Edit list";
  - right, a 380pt column: a "Routines and triggers" white r20 card (routines on ground r14 plus "Ask Mo to set one
    up") and a "When idle" card (On checkbox, condition checkboxes, budget / model / runs rows).

  Today Rules, When idle and Routines are three separate sheets in grouped forms. `Views/Rules.swift`,
  `Views/Idle.swift`, `Views/Routines.swift`, `Views/Activity.swift` (`AgentPages`), `Views/ConsoleView.swift`.
- [M] **Rules segments** sit inside a grey form section, so there are two fills behind the track. The segments say
  "Own / Pre-approved / Ask / Hand over", while the board's column header says "On its own / Pre-approved /
  Ask first / Hand to you". The selected segment uses the bubble (as specced); the board's tone matches.
  `Views/Rules.swift`.
- [S] **Profile page** shows "Profile" twice (page header and section header). `Views/Profile.swift`.
- [S] **Memory page.** "Today's note" has no body or empty state when nothing is there (in the bed's render it
  sits below a "could not read memory" error). `Views/Memory.swift`.
- [S] **Activity page** is a plain edge-to-edge list with full-width hairlines and no inset, unlike every other
  page. No board. `Views/Activity.swift`.
- [S] **Fixed (slice 6); pickers in cards left, see slice-6 NOTES.** **Settings tabs** (Models etc.): grouped-section fill and stock `(...)` menu buttons. The boards have no Mac
  app-settings board, so the target is the MacSettings card style. `Views/Settings.swift`.

## MacNeedsYou (`mac-needs-you-*`)
- [S] **Cards are close.** Title 34 rounded, subline, bloub 40, detail fill and trailing pills all match. Two board
  details are missing:
  - the "Watch screen" link on items whose agent is on a screen (the app reaches the screen through the
    inspector; check whether the card should link to it);
  - the board's "Rule: Spending money · Ask first" subline (the app shows "Needs you · asks first").
  `Views/NeedsYou.swift`.
- [S] **"Last night" with nothing in it** shows a bare title card. It needs an empty line, as "Right now" has
  ("Nothing is running."). `Views/Idle.swift` (Last night section), `Views/NeedsYou.swift`.
- [S] **Interview card** (Scout asks, option pills, "Answer later" / "Next question") wasn't in the bed; not
  rendered. `Views/NeedsYou.swift`.

## MacGoal (`mac-goal-*`)
- [S] **Matches the board's structure** (lead line, 34 title, Plan card with step marks and owner dots, results
  grid, Next from you, On it, keep link, outline "Open Mo's thread").
- [S] The **description paragraph** under the title isn't shown. The bed goal has none, so check on a goal that has
  one. `Views/Goals.swift`.
- [S] **Result cards** use a green tick tile for every result. The board uses the file-kind tile (spreadsheet
  green, markdown violet, thread amber) and a mono "who · when" subline. `Views/Goals.swift`.
- [S] **Delete / Finish goal** pills under the aside aren't on the board. They're existing behaviour, so they stay.
  Check they read as secondary to "Open Mo's thread" (Finish is a filled agent pill now). `Views/Goals.swift`.

## MacSearch (`mac-search-*`, `.sheet.png`)
- [M] **Presentation.** The app uses a standard sheet attached under the title bar (620pt, square top). The board
  is a free-floating 720x650 r26 panel, 100pt from the top, over a dimmed window (`#8f8a82`) with a big shadow.
  `Views/Search.swift`, `Views/ConsoleView.swift` (`searching`). **Fixed (slice 8):** `SearchOverlay`.
- [S] **Selection highlight.** The query text renders selected (grey box) at open. The board shows plain text.
  `Views/Search.swift`. **Fixed (slice 8):** caret placed at the end after focus.
- [S] **Top hit row.** The board shows a document preview thumbnail (84x108) and Open / Show in thread / Send to
  pills. That's out of scope (new behaviour, as last task).

## MacMenuBar (`mac-menu-bar-*`)
- [S] **Rows are bigger than the board.** The board uses 13pt single-line rows with a 26pt bloub and h28 pills; the
  app wraps titles to two lines with pills below. `Views/MenuBar.swift`, `Views/NeedsYou.swift`
  (`NeedsYouCard(compact:)`).
- [S] **"Open Schermes"** is missing its "⌘O" hint on the right. `Views/MenuBar.swift`.
- [S] **"Pick an agent ⌄"** is a stock menu label under the field; the board has none (the target comes from
  @name). Keep the behaviour, but restyle it as a muted inline chip. `Views/MenuBar.swift`.
- [S] **The "Working" section** wasn't in the bed, so it wasn't rendered.

## Foundations / Colours
- [S] Tokens match (`Theme.window`, `ground`, `panel`, ink, muted). The gaps above are about where they're used,
  not their values.

## Not on any Mac board (rendered for completeness)
- **Fixed (slice 6).** New agent sheet (`mac-new-agent-*.sheet.png`): follows PhoneNewAgent. The disabled Create button is a big grey
  slab. [S] Lighten its disabled state to the pill style's 0.4 opacity. `Views/NewAgent.swift`.

## Owner decisions (2026-10-01)
- **Activity and Profile: option A.** Profile folds into "Name and appearance" (name, look and profile text with
  Edit / Interview me again). Activity is a third pill in the agent settings page header, next to "Name and
  appearance" and "Memory".
- **Scope: all seven top gaps are in, seam first.** In order: seam, inspector contents, Settings as a sheet, stock
  sheet chrome, composer capsule, search floating panel, panel fill. The S rows stay on the list, fixed or given a
  recorded reason per the Definition of Done.

## Proposal for the owner: where Activity and Profile go (answered: A, above)
The canvas has no row for either, and both have to stay reachable. Pages reachable from the agent settings page
header (MacSettings) are the pattern the canvas already uses ("Name and appearance", "Memory"). So:
- **Profile → inside "Name and appearance".** The profile is what the agent is for, and MacSettings already shows
  the tagline right under the title ("Travel and errands · runs as agent-mo"). That sheet becomes name, look and
  profile text (Edit / Interview me again). The settings header's subtitle stays the tagline.
- **Activity → a third pill in the agent settings header** ("Name and appearance", "Memory", "Activity"). It's a log
  rather than a setting, but it's per agent, rarely visited, and a header pill costs nothing on the board.
  Alternative: a fifth icon (clock) in the chat header capsule, next to Routines and Memory. I'd skip that, since
  the capsule is four icons on the board.
- **The inspector's "Now / Runs as / Model" card** is also missing from Main. Runs-as is already in the MacSettings
  subtitle, and the model picker would move to the settings page's When idle / header area.

## Resolution (slice 10, 2026-10-01): every item fixed or kept for a reason
Final renders and per-board notes: `shots/final/` + `NOTES.md`.

| Item | Outcome |
|---|---|
| Owner #1 seam, sidebar seam, traffic lights | Fixed in slice 2 (`MacSplit`). Lights sit inside the sidebar card at (19,19), not Main's (29,27). |
| Panel fill | Fixed in slice 2 (`macPanel`: card 66% plus the white border). |
| Sheet chrome, grouped forms | Fixed in slice 6. |
| Stock controls | Pickers fixed in slice 9. Kept: switches and the Idle stepper stay native, on purpose (behaviour, a11y), and the board shows none. |
| Inspector Model pop-up in dark | Fixed in slice 9 (`ValueMenu`; the model now lives in the settings page subtitle). |
| Owner #2 inspector contents | Fixed in slice 3. |
| Inspector width | Fixed in slice 2 (the split item's ideal is 340). |
| Composer, helpers, tool runs | Fixed in slice 7. |
| Reply actions | Kept. They show on hover in the app. Showing them at rest under every reply would be noisy on long threads. |
| State wording (sidebar "Needs you" vs header "Failed") | Kept. The two lines report different facts: the sidebar shows the open item count, the header the run state. Making them agree means choosing one data source, which is a behaviour change. |
| Sidebar selected goal row fill | Fixed in slice 10 (`ConsoleView.swift`: the row takes the full width before its fill). |
| Owner #3 settings in-app | Fixed in slices 4 and 5. |
| Agent settings page | Fixed in slice 5. |
| Rules segments (two fills, words) | Fixed in slice 5 (board layout, column words). Kept: the short segment labels, because the long words don't fit a 400pt track. |
| Profile shown twice | Fixed in slice 6. |
| Memory "Today's note" | Already has an empty line ("Nothing noted today."). The render shows the failed-load case, where the error above it is the state. |
| Activity page edge-to-edge | Fixed in slice 10 (Mac: 14pt side inset, so rows line up with the sheet header). |
| Settings tabs | Fixed in slices 6 and 9. |
| Needs you: Watch screen link, rule subline | Kept. Both need new data on the item (screen state, rule name), and new behaviour is a non-goal. |
| Needs you: Last night empty | Fixed earlier: `LastNight` (Idle.swift) shows "What your agents do while you're away will show here." when there were no passes. The slice-1 bed had passes still loading. |
| Interview card | Not in the bed, so not rendered. Its styling is shared with the other `NeedsYouCard`s. |
| Goal description | Not in the bed (no goal has one). The code path shows it when present. |
| Goal result tiles | Kept. Results carry no file kind, so a kind tile would need new daemon data. |
| Goal Delete / Finish | Fixed in slice 10: both are secondary pills, so "Open <lead>'s thread" reads as the action (Delete still confirms). |
| Search presentation, selection | Fixed in slice 8. |
| Search top hit preview | Kept as a non-goal (new behaviour). |
| Menu bar rows bigger | Kept. Approval rows need the full title and the decision pills. A single line would truncate what the owner is approving. |
| Menu bar ⌘O hint | Fixed in slice 10. The hint is shown, and ⌘O now opens the console from the panel. |
| Menu bar "Pick an agent" | Kept. It is a stock borderless menu label, and restyling it as a chip needs a custom menu. Low value: @name covers it. |
| Menu bar Working section | Not in the bed. |
| Foundations / Colours | Match. |
| New agent disabled Create | Fixed in slice 6. |
| Grep gate | Clean. The last hit (`DesktopView.swift` recording label `.red`) is now `Theme.failed`. `Share.swift`'s grouped form and `Color.red` compile only into the share extension (`#if SCHERMES_EXTENSION`). `Bloub/` hex values are the mascot's skin palette, outside the gate, as in the last task. |
