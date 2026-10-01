# Acceptance — redesign-polish

The code is complete and every automated gate is green. What's left needs a human at the real Mac app: the renders
stand in for a running app, and no worker launched the app or drove input.

Build and run: open `apple/` in Xcode (`xcodegen generate` first if new files are missing), run the `Schermes` scheme
on "My Mac" against your daemon. Switch appearance in System Settings > Appearance to test both modes.

## 1. Reads as one whole (the Definition of Done item)
- [ ] In light and dark, compare the window with the canvas `Main` board
      (https://claude.ai/artifact/Ns9Ynh8yTKkCmoPrQESQir). Expected: sidebar, chat and inspector are three floating
      cards on one continuous ground with no hard seam, and the inspector is the 340pt card holding Screen, the goal
      and Routines and triggers. Reference renders: `shots/final/mac-main-agent-{light,dark}.png`.

## 2. Window shell
- [ ] Drag both gutters, then collapse and restore the sidebar (⌃⌘S) and the inspector. Expected: the cards resize,
      nothing shows through the gutters, and the traffic lights stay in the sidebar card.
- [ ] Glass tint and the inactive-window look: click another app. Expected: no panel turns grey or turns into
      system material.

## 3. Settings
- [ ] Press ⌘, with the console open, again with it minimised, and again with it closed. Expected: each time the
      settings sheet appears over the console window (a closed console reopens first). There is no separate
      Settings window.
- [ ] The sidebar gear and Needs you open the same sheet. Esc and the Done pill close it.
- [ ] On the chat capsule, the gear opens the agent settings page and the back pill (⌘[) returns. On that page,
      check that Name and appearance (with Profile inside), Memory and Activity open.

## 4. Sheets and forms
- [ ] Open the page sheets (from the capsule's Routines and Memory, and the sidebar right-click menu), New agent,
      the Model and Server editors, Form for, Send to, Bad reply and About. Expected: a header on the ground (title
      left, pills right) with no toolbar strip, and Esc closes. The editors, Form for, Send to, Bad reply and the
      Memory editor were never rendered, so look at these most closely.
- [ ] Open a few `ValueMenu` pickers (When idle, Settings > Model). Space and the arrow keys should work, and
      VoiceOver (⌘F5) should read the label and value.

## 5. Composer, search, goal, menu bar
- [ ] Composer: type, send with Return and ⌘Return, try the slash palette, the attach menu and stop while busy.
- [ ] Search: open it, type, press Return to ask, then close it with Esc and with a click outside. Open a hit.
- [ ] Goal: the end ticks on the goal outline pill. The Delete and Finish pills work (Delete still asks to confirm).
- [ ] Menu bar panel: ⌘O opens the app as the hint says.

## Placeholder choices to approve
These are dark values the canvas lacks, listed with their contrast in PROGRESS.md (slices 2, 6 and 7):
- the dark panel `#1c1b20` and its border `#222026`;
- the dark composer and chips reuse `Theme.card` dark;
- the search dim is black 40% (light) and 50% (dark);
- the card radius is 18, and labels have a 110pt minimum width;
- the "Ask <agent>" routine message text (slice 3).
