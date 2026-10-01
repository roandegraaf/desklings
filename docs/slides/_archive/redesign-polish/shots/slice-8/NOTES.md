# Slice 8: search floating panel (MacSearch)

Renders: `mac-search-light.png`, `mac-search-dark.png` (lever `search:invoices`, bed on 7911). The panel is an
overlay now, so it is in the main window PNG; there is no `.sheet.png`.

## Matches
- Free-floating panel, max 720x650, r26 continuous, 100pt from the top, centred, over a dimmed window with a big
  soft shadow (black 35%, blur 80, y 30).
- Panel fill `Theme.panel` (#fbfaf7 light, the board's colour); header row 18/22 padding, 20pt query, "esc" hint,
  hairline under the header; footer line with the hairline above.
- Light dim: black 40% over the window ground gives ~#8f8d88; board's flat ground is #8f8a82.
- The query shows plain text with the caret at the end (no selected box).
- Understood-as chips, amber top hit (r18), "Also close" rows: unchanged and matching as before.

## Differs (recorded)
- The board draws only the dim colour behind the panel; the app dims the real console (sidebar, chat, inspector
  visible through the dim). The traffic lights stay undimmed (window chrome draws above content).
- Top hit: no document thumbnail and no Open / Show in thread / Send to pills (new behaviour, non-goal).
- Dark: no canvas value; black 50% dim and a hairline border on the panel (see PROGRESS Placeholder choices).
