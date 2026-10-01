# Slice 5: the agent settings page (MacSettings, owner option A)

Renders (bed daemon on 7911, agent `juno`, which has a proposed trigger and two pre-approved entries):
- `mac-settings-agent-{light,dark}.png`: 1440x900, the board's size.
- `mac-settings-agent-narrow-{light,dark}.png`: 1000x680, the app's default window.
- `mac-look-{light,dark}.png` + `.sheet.png`: Name and appearance, now holding the profile.
- `mac-main-agent-{light,dark}.png`: the chat after the change (gear, export, inspector routines).

Levers: `-schermes.debugOpen agent-settings:<name>` and `look:<name>`.

## Matches MacSettings
- The page takes the main panel; the inspector is shut, as on the board.
- Header: 48pt bloub, 28pt rounded "Juno's settings", a 13pt muted "tagline · runs as agent-juno" subtitle, and
  secondary 36pt pills on the right. Option A: "Name and appearance", "Memory" and **"Activity"** are the pills.
- Rules: an 18pt rounded title with the muted line, the uppercase 11pt column words ("On its own / Pre-approved /
  Ask first / Hand to you"), white r16 rows on the ground with a 400pt four-segment track (picked level in the
  agent's bubble, Hand over in ink), the locked "Always yours" row and the soft-agent "Pre-approved:" strip with
  "Edit list".
- Right 380pt column: a white r20 "Routines and triggers" card (cards on the ground at r14, soft "Ask Juno to set
  one up") and a white r20 "When idle" card (On checkbox, condition checkboxes, hairline, Daily budget / Model /
  Runs as label + bold value, the footer line).
- Dark: same layout on the dark tokens; ground cards inside white (dark card) cards still read.

## Differs (recorded)
- A round back pill (⌘[) before the bloub returns to the chat. The board has no back control; the app needs one.
- The agent's own model sits in the subtitle as a bold value with a chevron ("Default (Sim Local)"). The board has
  no agent-model control on this page; When idle's "Model" row is the idle model, so the agent model can't share
  that label.
- When idle keeps the app's extra controls: "Model calls per pass" (stock stepper), the paused banner when
  paused, and From/To hour menus instead of fixed text. The footer adds "Hours are on the daemon's clock."
- The board's Routines footer ("Nothing to configure here") is left out: the cards open the routines page, where
  schedules can be paused and deleted, so that line would be untrue.
- Checkboxes render grey/inactive: the render window is never key (render-path limitation, as in every slice).
- Narrow (1000pt window): the column stacks under Rules. The tracks still fit (board label ideal width 150pt);
  narrower still, each row falls back to its level menu and the column header hides with it.
- The tagline comes from the profile's first line, so it keeps its full stop ("Weekly reports.").
- The chat header capsule now reads Routines, Memory, gear, **Export**, inspector toggle (five icons vs the board's
  four). Export used to sit only in the gear menu, and the gear now opens the page.
- Name and appearance shows the profile Markdown as is, including its own `# Juno` heading under "Profile".

## Reachability (every former page)
| Page | Where |
|---|---|
| Profile | Name and appearance (settings pill; the chat header's name; sidebar right-click "Name and appearance…"); also the "Profile, routines and activity…" sheet (right-click) |
| Rules | Settings page, left; sidebar right-click "Rules…" |
| When idle | Settings page, right card; sidebar right-click "When idle…" |
| Routines and triggers | Chat header capsule (bolt); inspector cards; settings page card (cards open the routines page) |
| Activity | Settings page header pill; right-click "Profile, routines and activity…" overview |
| Memory | Chat header capsule (book); settings page header pill |
| Name and appearance | Settings page header pill; the chat header's name; sidebar right-click |
| Model picker (agent's) | Settings page subtitle; the page sheet's overview (right-click "Profile, routines and activity…") |
| Export as Markdown | Chat header capsule icon (was in the gear menu) |

## ⌘, with the console window closed (orchestrator addendum)
`SettingsCommand` (Settings.swift) sets `SettingsRequest.pending`, brings back a hidden or minimised console window
or opens one (`openWindow(id: consoleWindowID)`), then posts `.showSettings`. A live console clears the flag when it
gets the notification. A console that mounts later (window just opened, or still at the login gate) presents the
sheet on appear. Test: `settingsCommandWithTheConsoleClosedOpensItAndTheSheet` (injected window lookup and opener,
so the test never opens a window or activates the app). The menu bar panel has no Settings entry (grep: no `SettingsLink`, no other `.showSettings` poster), so the app menu's Settings… is the only path outside the console. The suite is `.serialized`, and each test detaches its
host on close, because a closed window keeps its host subscribed.

## Found on the way
- **AttributeGraph "Cycle detected" (10 per mode).** Logged for every full page in the detail pane: Needs you,
  Goal and the settings page alike, but 0 for the chat. Bisected: it stays with the settings page emptied, so it
  comes from the shell (`pickedPage` shutting the inspector), not this slice. Left as is; worth a look in the
  shell slice.
- The inspector's routines block moved verbatim into `RoutinesSummary` (Routines.swift) so the page can reuse it;
  `mac-main-agent` shows the inspector unchanged.
