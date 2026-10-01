# Slice 6: sheet chrome and grouped forms on the Mac

Renders (bed daemon on 7911, agent `juno`), light and dark, each with `.sheet.png` (the sheet alone) and
`.sheet.views.txt` (the sheet window's view tree, new in `MacRenders.swift`):
- `mac-page-{profile,rules,when-idle,routines-and-triggers,activity,memory}-*`: the page sheets.
- `mac-new-agent-*`: New agent.
- `mac-settings-{model,web,notifications,plugins,daemon,about}-*`: the Settings tabs.
- `mac-look-*`: Name and appearance (its own pill footer, checked for a stray toolbar or stock Done: none).

## Proof: no toolbar strip
`grep NSToolbar *.sheet.views.txt` finds nothing in any of the 28 sheet dumps. Each sheet window keeps an
`NSTitlebarContainerView`, but it is 0pt tall (every sheet window has one). Before this slice the page sheets
had a white `NSToolbarView` strip with a centred "Juno" and a grey Done at the bottom (`shots/slice-1`).

## Matches (MacSettings card language, slice 4's header)
- **Header:** every Mac sheet uses `SheetHeader`: the title on the left in `.sectionTitle`, pills on the right,
  all on `Theme.ground`. Esc is Done (or Cancel), and Return is Save/Send/Fill where there is one. The Settings
  sheet uses the same view now.
- **Page sheets:** one row. The overview shows the agent's title; a page shows the round back pill (⌘[) and
  the page title, then Done. The second strip ("Juno" over "‹ Rules") is gone.
- **Duplicate titles dropped:** "Rules" under Rules, "Profile" under Profile, "Models" under the Models tab.
  The look sheet's bare profile keeps its own "Profile" label.
- **Grouped forms:** on the Mac, `ThemedForm` lays out its own sections as white r18 cards with the ink 8%
  border and hairlines between rows, on the ground. The headers keep `formHeader()`, the footers are muted
  footnotes, and an empty section draws no card. This covers Rules, When idle, Routines, Profile and Memory, every
  Settings tab, and the Model/Server/Form/Send to/Bad reply sheets. Dark uses the dark card token.
- **New agent:** the header has "New agent" and a Cancel pill. Create is a regular trailing pill. Disabled, it
  is the pill style's 0.4 opacity: a faded pill, not a full-width slab. It already used 0.4; the slab came from
  `.large` at full width.
- **Rules in the page sheet** keeps the four-segment track: the sheet minimum went from 680 to 720pt, because the
  card insets (20 + 16 per side) left 608pt for a 612pt row (200 label + 12 + 400 track), which made it fall back
  to level menus.
- **Plugins "Test as"** is the settings page's label + bold value menu (the `AgentModelRow(bare:)` pattern).
- **Models tab `(...)`:** it holds the row actions (Edit, Make default, backup, Delete), not a value, so it
  became a round secondary pill with `ellipsis`, next to the Test pill.

## Differs (recorded)
- Pickers inside the cards (Idle From/Until/Model in the sheet, Model/Server editor pickers) stay stock pop-up
  buttons. SwiftUI has no public custom `PickerStyle`; the settings page's label + bold value
  menus (`valueMenu`, `AgentModelRow(bare:)`) are per-call-site views. Converting each picker is a follow-up.
- Text field columns don't line up across rows. Each field starts after its own label (Web search: "Endpoint"
  vs "Key"); the native grouped form aligned them.
- `LabeledContent` values draw in ink rather than the grouped form's secondary grey. The style can't tell a
  plain value from a control, and muting would grey out interactive content too.
- When idle in the sheet keeps the switch layout. The settings page has the board's checkbox card
  (`IdleSettingsView(card:)`). Its stepper row now shows the value beside the stepper, not beside the label.
- Activity is a `List`, not a form, so it stays a full-bleed list under the new header.
- Memory says "could not read memory" in the bed (no agent home on this Mac), as in slice 1, so the editor
  (`TextEditor` on a white card, possibly edgeless) was never rendered.
- Controls render inactive or grey: the render window is never key (render-path limitation).
- Not rendered (no lever): Model/Server editor sheets, Form for, Send to, Bad reply, About from the app menu.
  They use the same `sheetChrome`.

## Mechanism (for the next slice)
- `Theme.swift`: `ThemedForm` on the Mac = `Form` + private `CardFormStyle` (`ForEach(sections:)` +
  `ForEach(subviews:)`) + `CardRowLabeled` / `CardRowToggle` (label left, control right; bare control under
  `labelsHidden()`). iOS is unchanged (`.grouped` + `listRowBackground`).
- `formLabel(_:)` keeps a bare `TextField`'s label on the Mac rows (Routines Cron, Plugins Arguments).
- `sheetChrome(_:confirm:confirmDisabled:cancel:onConfirm:)`: a header on the Mac, `NavigationStack` +
  toolbar on iOS. `SheetHeader` (Mac) is the row itself.
- Probe: macOS 27 has no API to recolour the grouped form's section box. `listRowBackground`,
  `backgroundStyle` and `containerBackground` all leave it grey, hence the custom style.
