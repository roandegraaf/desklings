# Slice 6 shots: Needs you, Goals, Search, menu bar

Bed: `scratchpad/bed6` (copy of the seeded bed plus one goal, "Lisbon trip, 14 to 18 Oct", led by Mo, with
Pixel as a temporary helper). Mac window 1440x900, the boards' size. iPhone 17 Pro sim, private.

| Shot | Board | Verdict |
|---|---|---|
| `mac-needs-you-light/dark.png` | MacNeedsYou | **Matches**: rounded 34 title + 15 muted summary, white r20 cards (bloub 40, bold 15 headline, muted subline), detail on the agent's soft fill (approvals) or ground, pills right-aligned (secondary / agent / destructive / primary), "Right now" and "Last night" in a 390 aside. **Differs**: the subline is "Agent · state word · time" with the word in Needs you orange or Failed red, not the board's "Rule: … · Ask first" (the daemon sends no rule name; the word keeps "never colour alone"). The board's Scout answer chips are not built (no multiple-choice data on a Needs you item). The title sits ~60pt lower than the board's 32pt padding because of the hidden title bar's safe area (same as slices 2-3). |
| `iphone-needs-you-light/dark.png` | PhoneNeedsYou | **Matches**: round back button with the rounded "Needs you" title beside it, white r20 cards, bloub 34, equal-width 40pt pills. **Differs**: subline as above; "Last night" sits under the cards as on the Mac (the board's one-line rows with one button are the same data, so not rebuilt). |
| `mac-goal-light/dark.png` | MacGoal | **Matches**: lead's tint as the page ground, "Goal · led by Mo · started 29 Sep" in the accent, rounded 34 title, Plan card (22pt marks: green tick, lead colour, empty ring; owner dot + name; hairlines), "Results so far" as white r16 cards with a green soft tile, aside with "Next from you" on the Needs you fill, "On it" (helper chips, "Mo's choice" box, keep link) and the outline "Open Mo's thread". **Differs**: no goal description line (the daemon has none); results are text lines, so tiles show a tick, not a file icon; no "Review payment" button in "Next from you" (the page has no route into Needs you; adding one is a feature); Delete and Finish goal pills stay below "Open thread" (existing actions the board leaves out); the helper's Open pill sits on its name line. |
| `iphone-goal-light/dark.png`, `-bottom` | PhoneGoal | **Matches**: back button + "Goal · led by Mo" + progress ring on one row, rounded 28 title, Next from you, Plan, helpers, tint ground. **Differs**: the same as the Mac. Results are shown here too (the phone board has none, but the data exists). |
| `mac-search-light/dark.png` | MacSearch | **Matches**: panel ground, 20pt field with the `esc` hint, hairlines, amber "Understood as" chips, the top hit on the amber soft fill (r18, 16 bold), "ALSO CLOSE" label, 32pt r9 kind tiles, muted footer. **Differs**: the sheet is 620 wide (system sheet sizing; the content asks for 720 ideal); the top hit has no thumbnail and no Open / Show in thread / Send to buttons (new features; a click on the row still opens the hit). |
| `iphone-search-light/dark.png` | (none; iPhone home search section) | Same `ResultRow` as the Mac: tiles, quoted message snippet, "Message · who · in thread", time. |
| `mac-menubar-light/dark.png` (+ `-panel` crops) | MacMenuBar | Rendered through the DEBUG lever `-schermes.debugOpen menu-bar`, which hosts `MenuBarPanel` in a sheet, since the real `MenuBarExtra` can't be opened focus-free. **Matches**: panel ground, white r12 input with the bubble icon and `⌥Space` mono hint, uppercase section labels, Needs you rows on the soft fill (r12, bloub 26, "**Name** asks…", small pills), Working list, hairline, "Open Schermes" footer. **Differs**: a row with two answers puts them under the text (the board shows one button per row; ours keep Don't / Always allow / Approve); the "Pick an agent" menu stays under the field; working rows show the state word, not elapsed time (the daemon doesn't report when a turn started); no `⌘O` hint (nothing binds ⌘O). The real menu-bar window's chrome is the system's. |
| `iphone-home-goal-card-light/dark.png` | PhoneHome | The goal card now renders (slice 5 had no goal in the bed): white r18, 170 wide, ring + 14 bold title + muted "Mo · 2 of 6". Matches. |

Colour grep (DoD), run from the repo root, finds nothing:

```
grep -rnE '#[0-9a-fA-F]{6}\b|0x[0-9a-fA-F]{6}\b|Color\.(blue|red)|\.(blue|red)\b|accentColor|glassProminent' \
  apple/Schermes/Views | grep -v 'Views/Theme.swift' | grep -v 'BloubColorId\.'
```

Palette ids (`BloubColorId.blue` etc., canvas colours drawn as soft fill + softText) are excluded by the last filter.

Runtime-unverified: the login / connect gate (the sim stays signed in through the Keychain; the classifier
refuses deleting that Keychain item, see memory), the real `MenuBarExtra` window, the iPad Needs you title.
