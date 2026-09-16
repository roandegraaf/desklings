# Acceptance — settings-hub

Everything automation can verify is green (`pnpm -r check`, `pnpm -r test` 209, `xcodebuild test`
on macOS 106, iOS simulator build). iOS was driven end to end in the simulator against a local
daemon. **The Mac app was never on screen**: the workers could not get past the Mac login screen
from a background session, and launching it would have grabbed your focus. That is the one item
left.

## 1. `[user-gated]` The Mac Settings window reads as native

Build and run the Mac app from Xcode (`apple/Schermes.xcodeproj`, scheme `Schermes`, My Mac), log
in to a daemon, then:

- [ ] Press ⌘, — a `Settings` window opens with six toolbar tabs, each with an SF Symbol: Model,
      Web search, Notifications, Plugins, Daemon, About. The app menu's **Settings…** item opens the
      same window. The sidebar's gear (bottom of the agent list, the only control there) opens it too.
- [ ] Each tab is a plain `Form` with a title and no Done button or nested navigation chrome. The
      window resizes sensibly per tab (no clipped content, no giant empty pane).
- [ ] App menu > **About Schermes** still opens the About sheet, and the About *tab* in Settings
      shows the same content.
- [ ] Model tab: change one field, Save, reopen — only that field changed on the daemon
      (`GET /api/settings` or the daemon log). Test button still works.
- [ ] Daemon tab shows the address, **Use a different daemon** (returns to the connect screen) and
      **Log out**.
- [ ] Plugins tab: **Add server** opens a sheet *inside the Settings window*, not a detached window.
      Add a stdio server (command plus one argument per line), Save; the row appears with Test, Edit,
      Delete. Edit it, change only the command, Save — the stored secret survives (the row still lists
      the secret name, and the sheet shows "Stored"). Delete asks for confirmation first.
- [ ] Paste a README snippet of the shape `{"mcpServers": {"files": {"command": "npx", "args": ["x"]}}}`
      into the Add sheet's paste field — the form fills itself. A snippet with two servers is refused
      with a message.

Expected: it looks like any other Mac app's Settings window. If anything renders wrong, note which
tab and run `/implement settings-hub` with the observation; the invariants at the top of
`PROGRESS.md` say which file owns what.

## 2. iOS spot check (optional — already driven in the simulator)

- [ ] Gear in the sidebar footer opens a sheet listing the six categories; each pushes its page;
      Done dismisses.
- [ ] Plugins page: swipe left on a server row shows Delete, which asks for confirmation.
