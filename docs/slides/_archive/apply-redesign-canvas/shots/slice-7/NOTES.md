# Slice 7 shots: proof sweep (gate and sheets)

Bed: `scratchpad/bed7` (copy of bed6; Juno's IMAP trigger set back to `proposed` and its "is on" line removed;
a pending `request_form` call plus form row added to Scout's thread so Needs you offers "Fill in…"). Daemon on
127.0.0.1:7871. Private iPhone 17 Pro sim (iOS 26.5), deleted afterwards. Boards: `FlowTriggers`, `FlowSignIn`,
`FlowForward`, `FlowRestore`, `Foundations`. There is no board for the login gate, Feedback, Agent look or the
iOS Settings list: those are checked against the Foundations tokens.

| Shot | Board | Matches | Differs (why) |
|---|---|---|---|
| `iphone-connect-light/dark` | (Foundations) | Ground fill, schermes bloub 112, rounded bold title, muted callout, solid r12 field (panel fill, ink 12% border), full-width primary pill (disabled = ink at 40%). | — |
| `iphone-login-light/dark` | (Foundations) | Same as connect; "Use a different daemon" link under the pill. Fresh sim, empty Keychain, so the gate shows with only `-schermes.serverAddress`. | — |
| `iphone-settings-sheet-light/dark` | (Foundations) | The iOS `SettingsSheet` list: one white (dark: card) r-card of rows on the ground, canvas palette soft tiles with softText glyphs, ink "Done" confirm pill. | — |
| `iphone-trigger-proposal-light/dark` | FlowTriggers | **Fixed this slice**: the card is now white r20 (dark: card) with a 1.5pt border in the agent's bubble colour at 45% and a soft shadow, where it used Liquid Glass r22. Delete (secondary) and Turn on (primary ink) now have equal width at regular height, as the board's Change / Turn it on. The day divider reads "Today". | The header keeps the state-coloured "Trigger · Mailbox" caption instead of the board's soft tile + "New trigger · from Ledger": the colour is the proposed / on signal. No When / Then / Limit rows: the daemon sends one reason line, so rows would be new content. The red line is the bed's real `last_error`. |
| `iphone-form-card-light/dark` | FlowSignIn | Same `actionCard` treatment for the form card and the fired webhook card (white r20, agent border). | Fill in… stays a small ink primary pill with "Use the agent's screen" beside it; the board has a full-width pill in the agent colour. Kept the slice-1 kind mapping (fill = primary), applied app-wide. The fields live in the sheet, not inline (existing flow). |
| `iphone-needs-you-form-light/dark` | PhoneNeedsYou | The form item card: bloub, bold headline, "Scout · Needs you · form" subline, detail on the ground, equal-width pills. | As slice 6 (subline wording). |
| `iphone-form-sheet-light/dark` | FlowSignIn | Themed form on the ground: origin row with a lock and mono URL, reason, white field rows, toggles, uppercase muted headers, "DO THESE ON THE AGENT'S SCREEN" section, confirm "Fill" pill. | Fields are form rows (label + inline field), not the board's stacked label over r12 inputs, and there is no SMS-code suggestion row (iOS fills one-time codes from the keyboard, so there is nothing to draw). Restructuring every form row would rewrite `ThemedForm`, which slice 4 settled. |
| `iphone-message-menu-light` | FlowRestore / FlowForward | The long-press menu: Copy, Send to…, Restore to this message, glyphs in the agent accent. | The system context menu, so it keeps iOS chrome. |
| `iphone-restore-light/dark` | FlowRestore | Panel sheet, rounded 22 bold "Restore to this message?", muted count line, white r-card with the "Put the files back too" switch and its reason, Cancel (secondary) and Restore (destructive) equal width at the bottom. | The switch is a system toggle (the board draws a checkbox). In the bed it is off and disabled, because there is no file snapshot. |
| `iphone-forward-light/dark` | FlowForward | Ground sheet, Cancel / "Send to" / Send confirm pill, uppercase "SEND TO" header, agent rows with bloub, rounded bold name and tagline, picked row checked, the note header follows the pick ("TO LEDGER"). | The board puts the agent list inside the long-press menu and the note in a floating card on the target's soft colour. That is a different flow (menu → floating composer), not a restyle, so the sheet stays. The picked row shows a checkmark rather than a 2pt ring in the agent colour. |
| `iphone-feedback-light/dark` | (Foundations) | "Bad reply" sheet on the ground: Cancel / title / Send confirm pill, one white r-card text field, muted footer. | — |
| `iphone-agent-look-light/dark` | (Foundations) | Identity-tint ground, bloub preview, rounded title2 name, mono "Runs as" line, shape and colour pickers with the picked one ringed, Reset (secondary) and Done (primary) pills. **Fixed this slice**: the "Shape" / "Colour" labels use `Theme.muted` instead of the system `.secondary`. | — |

## Mac
- **Gate:** not rendered. Launching the lever without `-schermes.debugPassword` (which is how the gate is reached)
  was refused by the auto-mode classifier, so it was not retried. `Entry.swift` is shared code and the iPhone shots
  cover it. The owner can see it at sign-off.
- **Sheets:** one launch with the slice 2-6 recipe (`debugPassword` + `debugOpen agent:juno`) was allowed, but
  cua-driver returned `ax_window_unresolved` with no screenshot (the known failure in memory). Not escalated to the
  foreground. So the Mac Forward, Restore, FormSheet, Feedback, Agent look and trigger card renders are
  Runtime-unverified, and so is the Mac New agent in dark.
- **The real Mac `Settings` window:** can't be opened focus-free (`openSettings()` can activate the app). Its pages
  are the same views the `settings` lever sheet hosts, rendered in slice 4 (`mac-settings-light/dark`). This is a
  harness limit, not a gap.
- Mac-only code change this slice: the trigger proposal pills `.fixedSize()` on macOS, so they hug their labels
  instead of stretching across the unbounded chat column (unseen; compiled and tested).

## Audit: "differs" across `shots/*/NOTES.md`
Every entry has a reason. Resolved since they were written:
- slice 1: every row deferred to slices 2, 3, 5 and 6, which shipped and rendered them.
- slice 3: "trigger card in the chat still uses system grey" → `actionCard` (this slice). "Day label is the date,
  not Today" → `DaySeparator` uses relative date formatting ("Today", "Yesterday", then the date; this slice).
  "Mo is failed, so the bare !" → slice 5 failed bloub.
- slice 5: the title-to-strip and strip-to-card gaps (about 14 / 18pt against the board's 14 / 14) are the system
  `List` section spacing on the home list, which `NavigationLink` rows need (slice 5 kept them for push and back).

Greps (from the repo root), run 2026-10-01 after the last edit:
- Colour grep over `apple/Schermes/Views` (minus Theme.swift and `BloubColorId.`): no hits.
- `grep -rnE '\.bordered(Prominent)?\b' apple/Schermes`: no hits.
- `grep -rn 'formStyle(.grouped)' apple/Schermes`: `Views/Theme.swift` (`ThemedForm`) and `Share.swift:118` (the
  extension branch, which has no Theme) only.
