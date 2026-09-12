# Acceptance — apple-app

The app is code-complete. Both destinations build with zero compiler diagnostics, and 83 tests pass
on each (verified at `/complete`, 2026-09-11, after slices 10 and 11 fixed the gaps two independent
reviews found). What follows is what only the owner can check. Items 1 and 2 are the Definition of Done's
`[user-gated]` items; items 3–9 were never exercised at runtime by automation.

## Before you start

- **Remove a leftover Keychain item.** Slice 9's Mac test login left one behind, because the
  permission classifier refused the delete:
  `security delete-generic-password -s dev.schermes.owner -a password` → "password has been deleted"
  (or "could not be found", if the new build already removed it).
- **Harness:** `docker compose up -d` in the repo root → `http://127.0.0.1:7777`.
- **Mac app:** `cd apple && xcodegen generate && open Schermes.xcodeproj`, destination "My Mac",
  then ⌘R.

## 1. Physical iPhone, a real turn `[user-gated]`

1. Signing: in Xcode, Schermes target → Signing & Capabilities → Automatic, and pick your team (a
   free personal team works). For it to survive `xcodegen generate`, set `DEVELOPMENT_TEAM` on the
   **target** in `apple/project.yml`, not the project.
2. Reach the harness from the phone. The compose file publishes on `127.0.0.1` only, so forward
   it for the test: `brew install socat`, then
   `socat TCP-LISTEN:7780,fork,reuseaddr TCP:127.0.0.1:7777`. Allow incoming connections if macOS
   asks. Keep the phone on the same Wi-Fi.
3. In the app, connect to `http://<mac-ip>:7780`, where `<mac-ip>` is `ipconfig getifaddr en0`.
   Allow Local Network access when iOS asks. The app declares no `NSLocalNetworkUsageDescription`,
   so if no prompt appears and connecting times out, check Settings → Privacy & Security → Local
   Network first.
4. Gear → Provider: set a real OpenAI-compatible base URL, model and key. The stub in
   `infra/provider-stub.py` answers instantly, so with it the avatar never visibly thinks.
5. Ask an agent for something that needs its computer or terminal, e.g. "take a screenshot of
   example.com in the browser" or "run `uname -a` in the terminal".

**Expected:** the chat's avatar goes idle → `thinking` while the reply streams, with the live row
and its reasoning shown above the composer (never seen before: the stub was too fast). It then
holds `orbit` (computer) or `comet` (terminal) for the whole tool call instead of settling after a
few seconds, and settles when the turn ends. A reply that has both text and a tool call shows its
text bubble and a one-line call under it. The screenshot renders inline.

Also on the phone: open the desktop, Take control, and two-finger tap on it → a right click lands on
the agent's screen (the Simulator cannot synthesise that gesture). Stop `socat` with Ctrl+C afterwards.

## 2. A day of use `[user-gated]`

Use the app as your only client for a day. Note every time you reach for the web UI at
`http://127.0.0.1:7777`. **Expected:** the note is empty, or it becomes the next task.

## 3. The Mac app, live — settings, plugins, routines

Never driven on the Mac: seeding its Keychain and defaults was refused, and a background click could not flip a switch.

- ⌘, (or the gear): change the model → Save → close and reopen, and the new value is there. The key
  fields say "Stored" or "Not set" and never show a key. Save with the key blank → still "Stored".
- Plugins row: paste a stdio MCP server JSON (type the quotes by hand) → Save → pick an agent under
  "Test as" → each server gets "N tools: …" or an error line.
- Routines (inspector, or the chat toolbar's clock button): add `*/15 * * * *` with a prompt → it
  reads "Every 15 minutes". Flip its switch off → the web UI shows it paused, and flipping it back
  resumes it. Right-click the row → Pause/Resume works. Two-finger swipe left → Delete removes it.

## 4. The Mac with Reduce Transparency and Reduce Motion

System Settings → Accessibility → Display.
- **Reduce transparency on:** the composer pill, the inspector's badge and the desktop's capsules
  draw as solid surfaces and stay legible, in light and in dark.
- **Reduce motion on:** avatars keep morphing, blinking and drifting, but orbit rings and decor hold
  still. A held tool state plays its clip once and does not loop, by design.

Turn both back off.

## 5. The Mac's key-window look

Every Mac capture was of a background window. With the app frontmost, check:
- Sidebar row names draw at full strength, not lighter than their previews.
- The desktop sheet's Back and Take control buttons are not dim.

If either still looks dim in the key window, that's a bug. If it's only dim in a background window,
that's macOS's normal inactive-window look.

## 6. Resizing the Mac window with the pointer

Every resize so far went through the Accessibility API's frame setter. With the inspector open,
drag the window's corner down as far as it goes toward 800x600.

**Expected:** it stops around 797 pt wide at the default sidebar, nothing clips or overlaps, and the
sidebar doesn't collapse on its own. Known limit: a sidebar dragged wider raises that minimum past 800.

## 7. Control through the inspector, and its reconnect

- Click the inspector's desktop thumbnail → the full desktop opens on the same connection. Take
  control, click and type → both land on the agent's screen. Return control → further input does
  nothing.
- `docker compose restart` → the thumbnail drops, then reconnects within about 5 s of the daemon
  being back.

## 8. The held avatar at frame rate

The loop that holds `comet` and `orbit` was proven by tests and measurements; nobody watched it run.
In a debug build, the **States** button under the agent list → "Run them" loops both.
**Expected:** the loop's seam doesn't jar: no visible skip in the orbit's rings or the comet's ribbons.

## 9. The remaining corners

- An iPad (or iPad simulator) in landscape: three columns, and the inspector looks intentional in
  light and in dark.
- On the Mac, open a worker thread (the reason replaces the composer) and a group thread.
- **Upgrading from a pre-slice-10 build:** the Keychain password is now stored once per daemon, and
  the old unscoped one is not migrated. The first expired session after upgrading asks for the
  password once, then never again.

## Optional — the `Raw` decoder against a real server

TigerVNC always picks ZRLE, so `Raw` is proven by fixtures only. To exercise it, drop ZRLE from
`encodingsMessage` in `apple/Schermes/Vnc/RfbClient.swift` for one run, open a desktop, then put it back.

## Worth knowing

**The daemon's session cookie crosses ports on one host.** Cookies are keyed by host, not port
(RFC 6265), so two daemons on the same host (say the harness on `:7777` and a dev daemon on
`:7791`) receive each other's session cookie. Different hosts never do. Nothing was changed. The
practical effect is a silent re-login when switching between two daemons on one machine. If you
want them isolated, clear the old host's cookies when the daemon changes: a few lines in
`Session.swift`.

**A send can skip rows the poll hasn't fetched yet (follow-up).** `send()` in
`apple/Schermes/Views/ChatView.swift` merges the message it just created, which moves the poll's
cursor (the newest id it holds) past any rows written in the up-to-2 s since the last poll. Those
rows, such as a tool call or a screenshot mid-turn, or another agent's line in a group thread, don't
show until the thread is reopened. The web UI's send doesn't merge; it waits for the poll, so it
doesn't have this. The fix is to fetch from the pre-send cursor after a send instead of merging.
That touches the send path slice 11 just changed, so it wants a test of its own.
