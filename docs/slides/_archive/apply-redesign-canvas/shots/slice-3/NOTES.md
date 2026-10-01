# Slice 3 shots: matches / differs

Rendered 2026-10-01 against a cloned bed daemon (`s3bed`; Mo's first two messages backdated a day and two assistant
lines added, so a day divider and the "New" divider show). Mac: lever app at 1440x900, background launch, screenshots
downscaled to 1568 px wide. iPhone: private iPhone 17 Pro sim (iOS 26.5). Board: `Main.dc.html`.

| Screen | Matches | Differs (and why) |
|---|---|---|
| `mac-chat-light.png` | Header in the chat panel: bloub 44, name rounded 22 bold, 13pt semibold state line; context pill h36 r18 (card 72%, card 95% border) with a 20pt ring and "62%"; one capsule (r22, padding 4, soft shadow) holding four 36pt icons: Routines and triggers, Memory, settings, inspector toggle, the toggle filled with Mo's soft colour and softText. Owner bubble with the 6pt bottom-trailing tail. Day divider is hairline, label, hairline (12pt semibold muted). Inspector: "Screen" rounded 16 bold, thumbnail on the dark r14 bezel with an r8 inner screen, full-width agent "Take control" pill plus a round secondary pop-out, then white r14 cards on the panel: Now / Runs as / Model, and one card per page with a 30pt r9 soft icon tile. | The header starts below the window's toolbar strip (the sidebar toggle lives there), so it sits about 26pt lower than the board's 16pt top padding; the strip above is filled with the thread tint. Mo is `failed` in the bed, so the bloub is the bare "!" (failed bloubs are slice 5) and there is no PAUSED chip: Mo's only Needs you item is a failure, which isn't the agent waiting on the owner. The bed has no VNC, so the thumbnail shows the socket error instead of a screen. The board's inline goal and routine list sections aren't in the app: the inspector keeps its page list (Profile, Rules, When idle, Routines, Activity, Memory) as cards. Day label is the date ("30 Sep 2026"), not "Today". |
| `mac-chat-dark.png` | Same layout on the dark tokens; active toggle on the dark soft fill; bezel `#2a2640` on panel `#1c1b20`. | This launch kept the saved 250pt inspector width (the ideal is now 340; it applies once the inspector is reopened, as in the light shot), so page details wrap and the Model menu truncates. The pills use card `#232127` at 72% (no canvas dark value). |
| `mac-inspector-paused-light.png` | Juno has a pending approval: PAUSED chip (`needsYouSoft` / `needsYou`, 11 bold, r9) next to "Screen", and a 2pt `needsYouTile` ring around the bezel. "Take control" in Juno's bubble colour. | Saved 250pt inspector width, as above. The trigger card in the chat still uses system grey: chat cards are outside this slice. |
| `iphone-chat-light.png` | Owner bubble tail bottom-trailing; "1 Oct 2026" hairline divider; "New" divider: one leading rule in the agent accent at 45%, "New" 12 bold in the accent at the trailing end. iOS toolbar (glass pill, "More" menu with ring) unchanged. | The rule is the accent text colour at 45%, not the board's bubble-derived `#c9b6f7`; close but a step darker. |
| `iphone-chat-dark.png` | Same, dark tokens. Captured live after flipping appearance, so the New divider is the same session's. | As light. |

Checked live on the Mac (background AX presses on the Juno window): the inspector toggle hides and shows the inspector
(label flips Hide/Show inspector); Routines and triggers opens the agent pages sheet on that page; Memory opens it on
Memory; the settings button is a menu with Profile, Rules, When idle, Name and appearance and Export as Markdown; the
name and bloub are a button ("Change its name and appearance"). The agent pages sheet shows the new page header (round
back button, rounded 16 bold title, no bar).

Runtime-unverified: pressing Export as Markdown from a background menu press showed no share picker (the item is there
and enabled; the picker likely needs an active window). Take control and the pop-out button were not pressed (the bed
has no desktop).
