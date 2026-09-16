> Completed 2026-09-14 (pending acceptance: 1 item, see ACCEPTANCE.md)

# Settings hub and a real plugin editor

## Goal
The console's sidebar currently ends in four exits (a Plugins row, Log out, About, a gear) for
what is one thing: the daemon's configuration. Collapse them into one Settings entry with
categorized pages, following the platform's own conventions on each OS. Replace the Plugins
screen, a read-only list plus an empty "retype every server, secrets included" JSON box, with a
per-server editor. That needs the daemon to accept one server at a time, so the daemon changes too.

## Scope
- Sidebar footer keeps only the gear (and ⌘, on the Mac). Plugins, About and Log out move inside Settings.
- macOS: a native `Settings` scene (its own window, categories as toolbar tabs, opened by ⌘, and the app menu's Settings… item). The Mac's About item keeps opening the About sheet.
- iOS: a sheet with a grouped list of categories, each pushing its page in a `NavigationStack`.
- Categories, same on both platforms:
  - Model: base URL, model, API key, extra request fields, Test connection
  - Web search: endpoint, key
  - Notifications: APNs key ID, team ID, bundle ID, `.p8` key, sandbox, registered devices, Send test push
  - Plugins: the MCP servers
  - Daemon: address, Use a different daemon, Log out
  - About: version, avatar credit and licence (the existing `AboutView` content)
- Each page saves its own fields with its own Save. The daemon's `PUT /api/settings` already keeps any field that is absent, so a page sends only what it owns.
- Daemon: per-server MCP routes. `PUT /api/mcp/servers/:name` upserts one server; a blank secret value keeps the stored one (the provider key's behaviour). `DELETE /api/mcp/servers/:name` removes one. `GET` and the test route stay. The replace-all `PUT /api/mcp/servers` may stay for `smoke.sh`.
- Plugins page: one row per server (name, transport, command or url, which secret names it carries, last test result), Test per row, Delete with confirmation (on iOS also as a swipe action), tap or Edit opens the editor, an Add button in the toolbar.
- Server editor sheet: name, transport picker (stdio / http), command and args or url, env or headers as editable key-value rows where a stored secret shows as "Stored" and blank keeps it. Cancel and Save.
- The Add path also accepts a pasted JSON snippet in the `{"mcpServers": {"name": {...}}}` shape every MCP README uses, and the bare `[{...}]` array the daemon speaks; parsing fills the structured form, nothing is saved until Save.

## Non-goals
- No new settings. Only the fields that exist today move.
- No redesign of Routines, Activity or Memory; those stay on the agent.
- No change to how secrets are stored or that they are never echoed back.
- No web UI; the SwiftUI app is the only client.
- No per-agent plugins; the server list stays owner-wide.

## Key decisions & constraints
- Follow the HIG, not a custom look: on the Mac the standard Settings window with toolbar tabs; on iOS a grouped list with disclosure rows, 44pt rows, semantic colors and text styles, SF Symbols, `.confirmationDialog` before a permanent delete, `.swipeActions` for delete, sheets for the focused edit task with Cancel and Save.
- The Mac `Settings` scene lives outside `RootView`, which owns the `Session`. Lift the session (and `PushRegistration`) into the `App` so both scenes share one; `AboutView` already handles an absent session and the pattern is documented there.
- ⌘, currently lives on the sidebar gear via `keyboardShortcut`; the `Settings` scene provides it on the Mac, so the gear there opens the window (`SettingsLink`). On iOS the gear sets the sheet.
- Settings pages load from the daemon on appear and are unedited until it answers, as today.
- Upsert semantics on the daemon: the stored list is one encrypted blob, so an upsert reads it, replaces or appends by name, and writes it back through the same `parseMcpServers` the loader uses. Merging blank secrets with the stored spec happens before the parse, so a spec that can be stored is still a spec that can run.
- `McpServerSummary` gains nothing secret, but it does have to gain `args`: `summarise` joins `[command, ...args]` into one display string, so as it stands the editor cannot round-trip a stdio server's arguments out of a `GET`. Corrected after slice 2. Make `command` the bare executable, add `args: string[]`, and let the client join the two for display. The secret key names it already has; a stored value is represented in the form as the empty string and rendered as "Stored".
- Keep the existing `mcpServers(fromDraft:)` parser in the client and extend it to accept the `mcpServers` object shape.
- Existing tests stay green: `daemon` (`pnpm test`), `apple/SchermesTests` (`xcodebuild test`), `infra/smoke.sh` if it exercises the replace-all route.
- Ponytail rules apply: no abstractions beyond the pages, fewest files, delete `PluginsView`'s JSON box rather than hiding it.

## Preconditions & external dependencies
None. A running daemon for a manual check is the existing local test bed.

## Building blocks
- `apple/Schermes/Views/Settings.swift`: split into a hub plus one view per category; the field code moves, it does not get rewritten.
- `apple/Schermes/Views/About.swift`: becomes the About page, still usable as the Mac's About sheet.
- `apple/Schermes/Views/ConsoleView.swift`: the sidebar footer and the `panel` sheet enum shrink to Settings only.
- `apple/Schermes/SchermesApp.swift`: the `Settings` scene on macOS, shared session.
- `apple/Schermes/Api/SchermesClient.swift` and `Types.swift`: `putMcpServer`, `deleteMcpServer`, the extended draft parser, a client-side `McpServerDraft` for the editor.
- `daemon/src/app.ts`, `daemon/src/mcp.ts`, `daemon/src/api.test.ts`: the two routes and their tests, blank-keeps-stored merge.
- `shared/src/index.ts`: any new wire shape.
- `docs/architecture.md`, `docs/configuration.md`, `apple/README.md`: the route list and the settings description.

## Definition of Done
- [x] The sidebar footer shows only the gear; no Plugins row, Log out or About in the sidebar.
- [x] macOS: ⌘, and the app menu open a `Settings` window with the six categories as toolbar tabs; the About menu item still opens the About sheet.
- [x] iOS: the gear opens a sheet listing the six categories; each pushes its page.
- [x] Model, Web search and Notifications pages each save only their own fields and show the same test buttons as before; the daemon receives no field a page does not own.
- [x] Daemon page shows the address, Use a different daemon and Log out; both work.
- [x] `PUT /api/mcp/servers/:name` upserts one server and a blank secret keeps the stored value; `DELETE /api/mcp/servers/:name` removes one; both covered in `api.test.ts`, including a 400 on a bad spec and a 404 on deleting an unknown name.
- [x] Plugins page: add a server through the structured editor, edit it without retyping its secrets, test it, delete it after a confirmation; iOS also deletes by swipe.
- [x] Pasting a `{"mcpServers": {...}}` README snippet into Add fills the editor form; a unit test in `SchermesTests` covers both accepted shapes and one rejection.
- [x] The old JSON "Replace the list" box is gone.
- [x] `pnpm -r check`, `pnpm -r test` and `xcodebuild test` pass; `infra/smoke.sh` still passes if it touches MCP routes.
- [x] Docs list the new routes and describe Settings as categorized. [ ] `[user-gated]` A look at both platforms confirms the pages read as native.

## Open questions
None.
