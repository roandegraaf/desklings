# Progress — settings-hub

## Current state

The settings hub exists and is the only way into the daemon's configuration. The sidebar footer is
one gear. The Plugins category still shows the old JSON box; replacing it is what remains.

Invariants future slices must respect:

- **One category, one page, one Save.** `SettingsCategory` in `apple/Schermes/Views/Settings.swift`
  is the single list of six; `settingsPage(_:session:)` maps a category to its view. Adding or
  reordering a category means editing only those two.
- **A page carries no navigation of its own** — no `NavigationStack`, no Done button, no
  `.frame(minWidth:)`. It is a `Form` with a `.navigationTitle`. The iOS sheet root
  (`SettingsSheet`) and the Mac scene (`SettingsWindow`) own the chrome.
- **A page sends only the fields it owns.** `SettingsForm` has `modelUpdate`, `webUpdate` and
  `pushUpdate` (in `apple/Schermes/Api/SchermesClient.swift`); the two halves a page does not own
  encode to nothing, and `PUT /api/settings` keeps every absent field. Verified end to end: saving
  Web search changed `searchUrl` and left provider, extra body and every push field alone.
- **The Mac has a second scene.** `Session` now lives on `SchermesApp`, not `RootView`, because the
  `Settings` scene needs the same one. Anything a settings page reads from the environment must be
  injected on that scene too — `pushRegistration` is, and it is a singleton, so nothing else had to
  move. `AgentLooks` and `Unread` stay on `RootView`.
- **A settings page cannot assume the console is on screen.** `PluginsPage` loads its own agent list
  for "Test as" rather than being handed one, because the Mac scene is outside `ConsoleView`.
- **Two buttons in one iOS Form row fire together** unless both carry `.buttonStyle(.borderless)`.
  Every button inside a settings Form section has it.
- **A per-server MCP write is blank-keeps-stored, and therefore all-or-nothing per block.** On
  `PUT /api/mcp/servers/:name` an `env` or `headers` entry sent as `""` takes the stored value; a
  key the body leaves out is **removed**. So a client must always send the full key set with
  blanks for the untouched ones. Omitting the `env`/`headers` object entirely is the same as
  sending `{}`: the parser defaults an absent block to empty, so every stored secret is removed. A
  partial object likewise drops every key not in it.
- **Which block the merge fills follows the *stored* transport**, not the body's, so turning a
  stdio server into an http one under the same name inherits no secret.
- **The whole list goes through `parseMcpServers` on every write**, per-server writes included.
  That is what holds an append to `MAX_MCP_SERVERS` and what keeps "can be stored" and "can be
  run" from drifting.

Key files:

- `apple/Schermes/Views/Settings.swift` — the category enum, the iOS sheet, the Mac scene, the
  shared `FieldPage` load/edit/save shell, and the Model, Web search, Notifications, Daemon and
  Plugins pages.
- `apple/Schermes/Views/About.swift` — `AboutPage` (the category) and `AboutView` (the same page as
  the Mac app menu's About sheet, which needs no session).
- `apple/Schermes/SchermesApp.swift` — the lifted session and the `Settings` scene.
- `apple/Schermes/Views/ConsoleView.swift` — the one-gear footer; `SettingsLink` on the Mac, a sheet
  on iOS.
- `apple/Schermes/Api/SchermesClient.swift` — `SettingsForm` and its three per-page updates.
- `daemon/src/mcp.ts` — `parseMcpServers` and `withStoredSecrets`, the blank-keeps-stored merge.
- `daemon/src/app.ts` — the MCP route group: `GET`, the replace-all `PUT`, the per-server
  `PUT`/`DELETE`, and the per-agent test route.

## Slice 1: The settings hub and its categorized pages

- Shipped: one Settings entry point with six categories on both platforms. The sidebar footer lost
  its Plugins row, Log out and About and is now only the gear; on macOS that gear is a
  `SettingsLink` into a real `Settings` scene (⌘, and the app menu's Settings… item come free, and
  the categories are toolbar tabs), on iOS it opens a sheet whose grouped `List` pushes each page.
  `SettingsView` was split into per-category pages sharing one `FieldPage` shell, each with its own
  Save that sends only its own fields. The Daemon page took the address and "Use a different daemon"
  off the About sheet and gained Log out. `PluginsView` became `PluginsPage` and loads its own
  agents. `AboutView` became `AboutPage` plus a thin sheet wrapper.
- Key decisions:
  - `SettingsForm.update` is gone, replaced by `modelUpdate` / `webUpdate` / `pushUpdate`. Nothing
    sends all three halves at once any more.
  - `FieldPage` is the one shared abstraction: three near-identical load/edit/save copies would have
    been worse. It takes a `KeyPath<SettingsForm, DaemonSettingsUpdate>` and an `afterSave` hook the
    two pages with test buttons use to clear a stale result.
  - `PluginsPage` fetching its own agents crossed the slice's "don't touch PluginsView's internals"
    boundary. It had to: the Mac's Settings scene has no agent list to hand it, and passing an empty
    one would have silently disabled Test on the Mac.
  - The Mac About sheet no longer shows the daemon address; that content is the Daemon page's now,
    as the OVERVIEW specifies.
  - `Settings` cannot be a postfix `#if` on the `WindowGroup` chain — it needs its own statement
    level `#if os(macOS)` in the `SceneBuilder`, or the compiler rejects the body.
- Files this slice touched: `apple/Schermes/Api/SchermesClient.swift`,
  `apple/Schermes/SchermesApp.swift`, `apple/Schermes/Views/About.swift`,
  `apple/Schermes/Views/ConsoleView.swift`, `apple/Schermes/Views/Settings.swift`,
  `apple/SchermesTests/SettingsTests.swift`. Everything else dirty in the working tree — the daemon,
  `shared`, `docs`, `infra` — predates this task and was not authored here.
- Notes / leftovers: the Plugins category still hosts the old read-only list plus the "Replace the
  list" JSON box. Slices 2 and 3 replace it with per-server routes and a structured editor; nothing
  in the hub needs to change for that beyond swapping `PluginsPage`'s body.
- Runtime-unverified: everything macOS. The Mac `Settings` window, its toolbar tabs, ⌘,, the app
  menu's Settings… item and the About item were built and compile but were never opened — launching
  the Mac app risks a foreground grab and a `SecurityAgent` panel on the owner's working machine.
  The Apple docs confirm a `TabView` inside a `Settings` scene is the documented way to make
  sections, but the rendering itself needs one look. On iOS, Log out was not pressed; "Use a
  different daemon" next to it was, and both are the same two-line handler as before.

## Slice 2: Per-server MCP routes on the daemon

- Shipped: `PUT /api/mcp/servers/:name` upserts one server and `DELETE /api/mcp/servers/:name`
  removes one (404 on an unknown name). The upsert reads the encrypted row, replaces or appends by
  name, and writes the whole list back through `parseMcpServers`. A secret sent blank keeps its
  stored value through `withStoredSecrets` in `daemon/src/mcp.ts`, merged before the parse. The
  replace-all `PUT`, the `GET` and the per-agent test route are untouched. No client work.
- Key decisions:
  - **Zero new wire shapes.** The request body is untyped exactly as the replace-all route's is,
    the per-server `PUT` answers with `McpServerSummary[]` like its sibling so a client refreshes
    in one round trip, and `DELETE` answers `{ ok: true }` like every other delete in the API.
    Nothing to mirror in `Types.swift`, so the app stayed untouched.
  - **The whole resulting list is parsed, not just the one server.** That is the only thing that
    enforces `MAX_MCP_SERVERS` on an append and rejects a duplicate name; a single-entry parse
    would have let a ninth server in.
  - **The name in the path wins** over any `name` in the body (`{ ...body, name }`).
  - The merge field comes from the **stored** transport, so a body that switches stdio to http
    finds nothing to inherit and stores what it was sent.
  - An unreadable `mcp.servers` row reads as no servers, so an upsert onto it appends to an empty
    list. That is the loader's documented behaviour and the replace-all route already had it; no
    guard was added.
- Files this slice touched: `daemon/src/mcp.ts`, `daemon/src/app.ts`, `daemon/src/api.test.ts`,
  `shared/src/index.ts` (a doc comment only), `docs/architecture.md`, `docs/configuration.md`.
- Notes / leftovers:
  - Three stale claims were corrected while passing: `docs/configuration.md` and the
    `McpServerSummary` comment in `shared/src/index.ts` both said changing one server means
    sending every secret again, and `docs/architecture.md` still described the settings screen as
    one flat owner-wide screen rather than the categorized hub slice 1 shipped.
  - **`summarise` joins `command` and `args` into one string**, so a client cannot round-trip a
    stdio server's args out of a `GET`. `OVERVIEW.md` claims the editor already has what it needs;
    it does not. Slice 3 has to widen `McpServerSummary`. `OVERVIEW.md` has been corrected.
  - `infra/smoke.sh` never touched the MCP routes, so nothing there needed checking.
- Runtime-unverified: nothing. Both routes are covered by `daemon/src/api.test.ts`, and the
  headers half of the merge was mutation-checked (breaking it fails the test).

## Slice 3: The client's side of the per-server MCP API

- Shipped: `McpServerSummary` now carries a stdio server's `command` and `args` apart, so the
  editor can read arguments back out of a `GET`. `McpServerDraft` in
  `apple/Schermes/Api/SchermesClient.swift` is the editor's model and encodes to exactly what
  `PUT /api/mcp/servers/<name>` wants; `putMcpServer` and `deleteMcpServer` call slice 2's routes.
  `mcpServers(fromDraft:)` now returns `[McpServerDraft]` and accepts both the daemon's bare array
  and the `{"mcpServers": {…}}` object every MCP README prints. No UI: `PluginsPage` still has its
  JSON box, now saving through drafts.
- Key decisions:
  - **The draft always encodes the full secret block, an empty one as `{}`.** Blank keeps, absent
    removes, so an encoder that skipped an empty dictionary would make "delete the last secret row"
    a silent no-op in the editor slice. Mutation-checked: skipping it fails
    `aStoredSecretGoesOutBlankRatherThanBeingLeftOut`.
  - Only the half the transport uses is encoded, never both blocks.
  - **The parser refuses an entry that is both stdio and http, or neither.** A draft holds one
    transport, so mapping such an entry would have to drop half of it silently where the daemon
    answers 400. Everything else a draft *can* represent is left to the daemon to judge — the name
    charset, the url scheme, `MAX_MCP_SERVERS` — so client and daemon cannot drift.
  - `SchermesError` gained `notServers(String)`. Reusing `notJSON` would have prefixed a structural
    complaint with "that is not JSON: ".
  - **Sorted where the source has no order, not where it does.** The `mcpServers` object's keys and
    every `env`/`headers` block are sorted by name; the bare array keeps the owner's order, which is
    what the replace-all box sends.
  - `saveMcpServers` takes `[McpServerDraft]` rather than `JSONValue`, so the JSON box keeps working
    with a one-line change and there is one parser rather than two. Side effect: the box now also
    accepts the README object shape.
- Files this slice touched: `shared/src/index.ts`, `daemon/src/app.ts`, `daemon/src/api.test.ts`,
  `docs/configuration.md`, `apple/Schermes/Api/Types.swift`,
  `apple/Schermes/Api/SchermesClient.swift`, `apple/Schermes/Views/Settings.swift`,
  `apple/SchermesTests/SettingsTests.swift`, `apple/SchermesTests/TypesTests.swift`,
  `apple/README.md`.
- Notes / leftovers:
  - `ServerRow` would have started printing a bare executable without its arguments, so
    `McpServerSummary.detail` (in `Settings.swift`) rejoins them for display. The next slice's rows
    can keep using it.
  - `theServerBoxGoesOutAsTypedSecretsIncluded` was rewritten rather than deleted: it now pins that
    typed secrets survive the draft round-trip verbatim, which is the invariant it always guarded.
  - `docs/configuration.md` no longer claims a stdio server's `command` and `args` "come back
    joined". The box still starts empty, because secrets are still never read back.
  - `infra/smoke.sh` has no MCP routes, confirmed by grep.
  - One stale claim corrected in passing: `apple/README.md` still described the old sidebar —
    provider and web search behind the gear, the MCP servers behind a Plugins row, About under
    the agent list carrying the daemon address. Slice 1 shipped the change that made it wrong.
    The root `README.md` says nothing about settings and needed nothing.
- Runtime-unverified: nothing new on screen. `pnpm -r check`, `pnpm -r test` (209), `xcodebuild test`
  on macOS (105) and an iOS simulator build all pass. The app was not launched; this slice adds no
  view.

## Slice 4: The Plugins page's real editor

- Shipped: the "Replace the list" JSON box is gone and `PluginsPage` is a per-server screen. One
  row per server carries its name, transport, `McpServerSummary.detail`, the secret names it
  holds, its last test result, and three buttons — Test, Edit, Delete — with an Add row under the
  list; on iOS a swipe deletes as well. Both delete paths go through one `.confirmationDialog`.
  `ServerSheet` is the editor: name, a stdio/http picker, command and one-argument-per-line or
  url, and key-value rows where a stored value shows as "Stored" and blank keeps it. Add also
  takes a pasted snippet. Saving goes through `putMcpServer`, whose answer is the whole list, so
  nothing reloads. The client's replace-all `saveMcpServers` is deleted; the daemon's route stays.
- Key decisions:
  - **Add is a row in the Form, not a toolbar item.** `NEXT_SLIDE.md` asked for a toolbar button.
    A page owns no chrome (slice 1's invariant), and on the Mac a `ToolbarItem` inside a `Tab` of
    the `Settings` scene competes with the tab bar that *is* that window's toolbar — which cannot
    be checked from here, since the Mac app's login screen is not reachable in the background. A
    row needs no `#if` and renders where Test, Save and Log out already do.
  - **An existing server's name is read-only.** The name is the route's path, so editing it would
    store a second server under the new name and leave the first one standing. Not a rename, a
    silent duplicate, and nothing on the daemon can catch it. Add still types a name freely, and
    an empty one is refused in the sheet rather than sent as a different URL.
  - **The transport picker clears the secret rows in its own `set`, not in `onChange`.** An
    `.onChange(of: draft.transport)` also fires when a pasted snippet sets the transport, and it
    runs *after* `fill()` has assigned the rows — so pasting an http server filled its
    Authorization row and then silently emptied it. Caught in the simulator, not by a test.
  - **`SecretRow` is the sheet's own type, not `McpServerDraft.Secret`.** `ForEach` over a binding
    needs stable identity, and giving `Secret` a `UUID` would have changed its synthesized `==`,
    which three existing tests compare on. The row also carries `stored`, which the wire shape has
    no place for: it is what tells an empty field to read "Stored" rather than "Value".
  - **A snippet holding anything but one server is refused.** `mcpServer(fromDraft:)` in
    `SchermesClient.swift` wraps the array parser for a sheet that edits one; filling from the
    first entry would drop the rest without saying so. A free function rather than view-local
    logic, so the message is pinned by a test.
  - Every button in a server row is `.borderless`, per the invariant. With three of them in one
    row it is load-bearing, and tapping each one separately in the simulator confirmed it.
- Files this slice touched: `apple/Schermes/Views/Settings.swift`,
  `apple/Schermes/Api/SchermesClient.swift`, `apple/SchermesTests/SettingsTests.swift`,
  `docs/configuration.md`, `apple/README.md`.
- Notes / leftovers:
  - One stale claim corrected: `docs/configuration.md` still said the owner's panel is "a JSON
    textarea on the settings screen" that starts empty. It is a form now.
  - A `.borderless` button in a Form hit-tests its label, not its row. Nothing to fix — it is how
    the style works — but it means an `idb ui tap` at the AX frame's centre misses, and a tap
    needs `--duration 0.12` to land reliably at all.
  - The iPhone 17 Pro simulator still remembers `127.0.0.1:7791` and an owner password for a
    daemon and data dir that were both deleted at the end of this slice. It will open on "Could
    not connect"; point it at a fresh daemon and set a password again.
- Runtime-unverified: everything macOS, still. The Mac `Settings` window, its tabs and this sheet
  inside it were never rendered; the login screen cannot be answered from the background. On iOS
  the whole slice was driven against a local daemon in the simulator: add through the structured
  editor, add through a pasted README snippet, edit a command without retyping its token (the
  daemon's decrypted row still read `TOKEN: secret1` afterwards), an http server with a header
  saved and read back, Test, both delete paths and their confirmation, Cancel, the empty-name
  refusal and the two-server snippet refusal. `pnpm -r check`, `pnpm -r test` (209),
  `xcodebuild test` on macOS (106) and an iOS simulator build all pass.
