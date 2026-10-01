# Slice 7: composer capsule, worker chips, tool-run cards (Main)

Renders (bed copy of slice 6's on 7911, plus two busy task workers under Juno inserted after boot:
`hotel-scout` thinking, `train-finder` using_computer; boot repair fails any busy worker, so they go in
while the daemon runs): `mac-main-agent-*` (Juno), `mac-main-mo-*` (Mo), light and dark.

## Matches
- **Composer (Mac):** Main's capsule: max 760 centred (the chat's reading width), r26 continuous,
  `Theme.card` 86% fill, `Theme.card` 95% 1pt border, shadow black 8% blur 28 y 8 (`floatingCard`, ChatView).
  Round 36pt attach button on ink 6% with an ink paperclip; text at 15pt (`Font.canvas`); padding 6/6/6/8.
- **Placeholder:** "Message Juno, or / for commands". Honest: `SlashCommand.offered(in:)` is non-empty for
  an agent and a shared thread. A worker thread (no commands) shows no composer anyway, and the placeholder
  drops the suffix whenever nothing is offered. VoiceOver label is "Message Juno" (no suffix).
- **Worker chips (Mac):** white 80% capsule chips (r16, 32pt, white 95% border, shadow 6% blur 14 y 4) in a row
  over the composer: 20pt bloub, bold name, state line. Falls back to a column when the row doesn't fit.
- **Tool runs (Mac):** white r16 card with the ink 8% border, max 640, label left, chevron right, 13pt
  semibold secondary; the expanded steps sit inside the card.
- Send, stop, attachments strip, slash palette, Return/Shift-Return/⌘Return, focus: untouched code paths.

## Differs (recorded)
- Main's tool card says "Worked for 3 min · 4 steps" with a green check. The app keeps its summary
  ("Called propose_trigger", "Ran 1 shell command") and wrench: elapsed time is new behaviour (non-goal).
- Main's chip status is the worker's activity text ("Holding two hotels near Baixa"); the app shows the state
  word (Thinking, Using the computer). No activity text exists per worker without daemon work.
- Dark: the composer card is `Theme.card` dark at 86% on the dark chat panel, so its edge is faint (no canvas
  dark value; see Placeholder choices in PROGRESS).
- The chips and composer overlay the scrolled chat (as the glass did); the "Today"/"Idle work" lines can sit
  behind the chips mid-scroll.
- iOS keeps its glass composer; only the placeholder text is shared ("Message X, or / for commands").
