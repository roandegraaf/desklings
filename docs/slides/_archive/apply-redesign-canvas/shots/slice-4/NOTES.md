# Slice 4 shots: forms and sheets

Bed daemon on 127.0.0.1:7797 (copy of `scratchpad/bed`). iPhone 17 Pro sim (iOS 26.5), Mac lever app
(`SchermesLever4`, background only). Boards: `PhoneRules`, `PhoneNewAgent`, `MacSettings`, `Foundations`.

| Shot | Board | Matches | Differs (why) |
|---|---|---|---|
| iphone-rules-light / -dark | PhoneRules | Warm ground, white (dark: card `#232127`) rows in one rounded card, uppercase muted "RULES" label, level word coloured by level (agent accent / needs-you / ink), lock + "Always yours", ink "Done" pill. | Sheet header is "Mo" + page header "‹ Rules" (existing navigation) instead of bloub + "Mo's settings"; chevron is up/down (it is a menu) not right; no "Automations" card (those are the inspector's page list). |
| iphone-new-agent-light / -dark | PhoneNewAgent | Agent-tint ground, "Cancel · New agent" header, rounded bold question, white r18 description field, full-width ink Create pill at the bottom, footnote centred. | Bloub preview, name field and look picker stay in the sheet (board shows the suggestion card instead; that appears after Suggest, as a white r20 card). |
| mac-settings-light / -dark | (app Settings; Foundations form specimen) | Warm ground, rounded 16 bold section title, pill buttons (Test, Add model). Shown as the DEBUG sheet (`-schermes.debugOpen settings`), which hosts the same page view as the `Settings` scene. | Section fill is the system's translucent fill over the ground (`#efede8` light), not white: macOS grouped `Form` ignores `listRowBackground` (probed per Group, Section and row) and has no section-background API. White cards would mean rewriting every form as custom layout. |
| mac-rules-sheet-light / -dark | MacSettings (Rules column) | 4-level segmented pills per row: quiet track, picked level in the agent bubble, "Hand to you" in ink; Own / Pre-approved / Ask / Hand over; locked row with "Always yours". | Rows sit in one form section rather than separate r16 cards with an uppercase column header; the routines / idle aside of the board is not on this page (separate pages). Sheet toolbar "Done" is the system button. |
| mac-inspector-rules-light / -dark | MacSettings / PhoneRules | Inspector at 340: the compact level menu row (as PhoneRules), themed ground, rounded titles. | Same Mac section-fill limit as above. |
| mac-inspector-rules-narrow-dark | — | A narrow (saved) inspector stacks the level under the name instead of squeezing the name to a word a line (was the pre-slice behaviour). | — |
| mac-new-agent-light | PhoneNewAgent | Same as iPhone on the Mac sheet. | — |

Verified separately: two pill-styled buttons in one iOS Form row fire only the tapped one (swiftc probe on
the sim, idb tap on the left button printed only LEFT; a tap on the row's blank area fired nothing), so the
Memory, Profile and server-row pills keep the single-fire behaviour `.borderless` gave.

Runtime-unverified: the real Mac `Settings` window with its tab chrome; the iOS `SettingsSheet` list with the
soft category tiles; the Mac "Send to Schermes…" window (now themed). Also Forward, Restore/Rewind, Forms (FormSheet), Feedback, Agent look and the trigger
proposal sheets were built and themed but not opened in a render (they need a message, a form request or a
proposal in the bed and a context-menu / swipe press).
