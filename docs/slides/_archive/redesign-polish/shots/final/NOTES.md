# Final Mac renders (slice 10, 2026-10-01)

All 74 PNGs come from one `renderMacScreens()` run with no `ONLY` filter, against the bed at 127.0.0.1:7911. Front-app
polls: 0. `goal`, `menu-bar` and `page-activity` were rendered again after this slice's small fixes. Board values come from the
canvas HTML (`project/<Board>.dc.html`, copy in the f7fe680c scratchpad `canvas/`). Light and dark exist for every
render: `mac-<name>-light.png` / `-dark.png`, plus `.sheet.png` where the screen opens a sheet.

| Board | Renders | Verdict |
|---|---|---|
| Main | `mac-main-agent-*`, `mac-main-mo-*`, `mac-main-bare-*` | Matches |
| MacSettings | `mac-settings-agent-*`, `-narrow-*`, `mac-look-*`, `mac-page-*` (sheets), `mac-settings-<tab>-*` | Matches |
| MacNeedsYou | `mac-needs-you-*` | Matches, with 2 recorded differences |
| MacGoal | `mac-goal-*` | Matches, with 2 recorded differences |
| MacSearch | `mac-search-*` | Matches, apart from the top-hit preview (a non-goal) |
| MacMenuBar | `mac-menu-bar-*` | Close, with 2 recorded differences |
| (no board) New agent | `mac-new-agent-*.sheet.png` | Follows PhoneNewAgent / the sheet header |

## Main
- **Matches:** three floating cards on one ground, light and dark, with no seam. Traffic lights sit in the sidebar
  card. The sidebar has search, Needs you, Goals, Agents with helper rows, and the New agent pill + gear. The header
  shows the bloub, the name with its state, the budget ring and the 5-icon capsule. Tool runs are white r16 cards. The
  composer is a floating capsule ("Message Mo, or / for commands"). The inspector has Screen (PAUSED chip, Take
  control in the agent colour, pop-out), the goal with worker rows, and Routines and triggers with "Ask Mo to set one up".
- **Differs:**
  - The header says "Failed" while the sidebar says "Needs you" (see audit).
  - Main's `<aside>` has no shadow; the app's inspector card has the two-layer 6% shadow (slice 2).
  - The tool-run label is the app's summary, not "Worked for 3 min" (elapsed time is a non-goal).

## MacSettings
- **Matches:** "Juno's settings" header with back pill, subtitle (tagline · runs as · model menu) and the Name and
  appearance / Memory / Activity pills. Rules are white rows on a four-segment track, with column words, the locked
  "Always yours" row and the Pre-approved strip with "Edit list". The right 380pt column holds Routines and
  triggers plus When idle (checkboxes, bold value rows). The page stacks below 1000pt (`-narrow`). App settings are a sheet over
  the main window, with a header, tab track and card forms.
- **Differs:**
  - The selected segment still says "Own / Ask / Hand over"; the column header carries the board's words.
  - "Model calls per pass" keeps a native stepper.
  - Daily budget is a field, not a plain value.

## MacNeedsYou
- **Matches:** the 34pt rounded title and subline, white cards with a 40pt bloub, the detail fill, trailing pills,
  and the Right now / Last night side cards.
- **Differs:** no "Watch screen" link and no "Rule: Spending money · Ask first" subline (both new behaviour, see audit).

## MacGoal
- **Matches:** the lead line, 34pt title, Plan card (step marks, owner dots), Results so far, Next from you, On it,
  the keep link and the outline "Open Mo's thread". Delete and Finish goal are now secondary pills, so the thread
  link reads as the main action.
- **Differs:**
  - Result tiles are a green tick, not a file-kind tile (the daemon's results carry no kind).
  - Faint vertical ticks show at both ends of the outline pill. They were already in the slice-1 render, and every
    other outline pill renders clean, so this is likely a `cacheDisplay` artefact. Check it on the real app.

## MacSearch
- **Matches:** the floating 720pt r26 panel 100pt from the top over a dimmed window. Query in plain text,
  "Understood as" chips, the top hit on the soft amber card, "Also close" rows and the footer line. The dark render matches too.
- **Differs:** no top-hit preview or Open / Show in thread / Send to pills (non-goal).

## MacMenuBar
- **Matches:** the quick field with the ⌥Space hint, the Needs you rows on the soft card with pills, and "Open
  Schermes" with its ⌘O hint (added this slice, with a working ⌘O).
- **Differs:**
  - Rows wrap to two lines with pills under them. The board uses 13pt single-line rows.
  - "Pick an agent" is a stock borderless menu label.
  - The Working section isn't in the bed.
