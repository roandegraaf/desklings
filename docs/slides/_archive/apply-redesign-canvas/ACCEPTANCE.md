# Acceptance: apply-redesign-canvas

The code is complete and verified: macOS tests (208) and iPhone 17 Pro sim tests (207) pass, as do `pnpm check` and
`pnpm test`. iPhone renders of every screen are in `shots/`. What follows is for the owner, because the Mac app could
not be rendered focus-free (cua-driver `ax_window_unresolved` and a ScreenCaptureKit failure, slices 7 and 8).
Compare each screen against the canvas: https://claude.ai/artifact/Ns9Ynh8yTKkCmoPrQESQir

Build and run a Debug build from Xcode (`apple/`, scheme `Schermes`), once in Light and once in Dark appearance.

## Before you start
- [ ] Check the `dev.schermes.Schermes` defaults for leftovers from the test launches (`defaults read dev.schermes.Schermes`).
      The lever launches shared this domain, so any debug keys or server address there can be removed. Expected: your
      real server address, `https://desklings.servertj.nl`.

## Mac (light and dark)
- [ ] **Login gate:** sign out (or run with an empty Keychain entry). Expected: the canvas gate on the warm ground,
      ink pill button, no system blue.
- [ ] **Shell overall:** no title bar, warm ground, three rounded panels. Collapse the sidebar, resize the window, and
      try ⌘N, ⌘K, ⌘, and ⌘[. Expected: everything still works.
- [ ] **Settings window (⌘,):** every tab uses the themed form (card rows on the warm ground), not stock grouped grey.
- [ ] **Chat sheets:** hover a message in an agent's chat and open "Send to…" (Forward), "Restore to this message"
      (Restore) and "Bad reply" (Feedback). Click the agent's name in the header (Agent look). Expected: themed sheets with
      pill buttons.
- [ ] **FormSheet:** Needs you, then "Fill in…" on a form item.
- [ ] **In-chat action cards:** a trigger proposal and a form card. Expected: a white r20 card with a thin border in the
      agent's colour. The pills size to their labels; this is the one Mac layout no one has seen yet.
- [ ] **Day divider:** today's messages are headed by a hairline "Today" divider.
- [ ] **New agent in dark:** ⌘N in dark mode.
- [ ] **Menu bar panel:** open the menu bar item. Only its content is styled; the frame is the system's.

## iPhone (light and dark)
- [ ] Home: tinted agent cards, rounded "Agents" title, bottom search and an ink "+". A failed agent keeps its body
      with X eyes.
- [ ] With the software keyboard up, the bottom bar stays usable. At a large Dynamic Type size, the cards and title don't
      clip. VoiceOver reads the card rows sensibly. None of these were checked at runtime.

## Placeholder choices to review
Dark values the canvas doesn't define were picked for 4.5:1 contrast. They are listed under **Placeholder choices** in
the slice entries of `PROGRESS.md` (slices 1-6). Accept them or name new values.

## Known differences that need no action
Every "differs" in `shots/slice-*/NOTES.md` has a reason. The main ones:
- Board features that would be new behaviour were not built: Search's Open / Show in thread / Send to, the goal page's
  "Review payment", and elapsed time on working rows.
- On iOS 26 the settings button sits in the bar above the title.
- On iPhone, pushed pages put their rounded title beside the back button.
- The iOS share extension keeps the stock form, because it compiles without the app theme.
