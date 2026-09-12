# Schermes for iOS and Mac

A native SwiftUI app that talks to the schermes daemon's HTTP API. One target builds for both
iOS 26 and macOS 26 and every view is shared; the split view is a sidebar on a Mac and an iPad,
and its own screen on an iPhone.

## Build and run

The Xcode project is generated, never committed. `project.yml` is the source of truth.

```sh
cd apple
xcodegen generate
open Schermes.xcodeproj          # or build from the command line:

xcodebuild -scheme Schermes -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Schermes -destination 'platform=macOS' build
xcodebuild test -scheme Schermes -destination 'platform=macOS'
```

Needs Xcode 26 with the iOS 26 simulator runtime, and XcodeGen on `PATH`
(`brew install xcodegen`). No Swift packages: everything is URLSession, SwiftUI and Swift Testing.

If `name=iPhone 17` is not among your simulators, create it once:

```sh
xcrun simctl create 'iPhone 17' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

Signing is ad-hoc (`CODE_SIGN_IDENTITY = "-"`, manual) so a fresh clone builds for the simulator
and this Mac with no Apple account. Running on a physical iPhone needs a real team: pick one under
Signing & Capabilities in Xcode, or set `DEVELOPMENT_TEAM` in `project.yml`.

## A daemon to talk to

`docker compose up -d` in the repository root gives one on `http://127.0.0.1:7777`. On first
launch the app asks for that address, then for the owner password — which it sets if the daemon
has no owner yet, and checks if it has.

## App Transport Security

`NSAllowsArbitraryLoads` is on, and that is deliberate. The daemon speaks plain HTTP by design;
TLS belongs to a reverse proxy in front of it, not inside it. Without this the app could not reach
a daemon on `http://127.0.0.1:7777` or on a LAN address at all. The connect screen says to use
`https://` for anything off the local network, and that path is unaffected by this setting.

## Session and password

The daemon's session cookie carries an expiry, so `HTTPCookieStorage` writes it to disk and a
relaunch is still logged in. The owner password goes to the Keychain under the daemon's address, so
it is only ever sent back to the daemon it was set on, and one 401 on any guarded
request spends it once to log back in and retries that request. A second 401 shows the login
screen. Auth routes never take that path: `POST /api/auth/login` answers 401 for a wrong password,
and retrying it would loop.

## Deleting things

Right-click (or long-press) an agent in the list for its appearance, its routines and activity, and
**Delete**; a shared thread and a task worker have a Delete of their own. Every one of them asks
first and says what goes with it. `DELETE /api/agents/:name` takes the agent's workers, its threads,
its routines and its history; its Linux user and home stay, because that is the agent's work and no
button here is worth destroying it. The daemon stops the desktop before it drops the row, so the
display number can be handed out again. Either delete is refused with a 409 while a turn is running.

Agents can ask for the same two deletions through the `request_deletion` tool, and nothing happens
until the owner answers: the request stands in `approvals` and appears at the top of the agent list
with **Delete it** and **Keep it**. Either answer drops the request and writes the outcome back into
the thread the agent asked in, which starts a turn so the agent reads it. An agent may ask to delete
itself.

## Layout

- `Schermes/Api/Types.swift` mirrors `shared/src/index.ts` one to one — same names, same fields,
  same optionality. When `shared` changes, this changes in the same commit.
- `Schermes/Api/SchermesClient.swift` is the HTTP client: cookies, the `{error}` envelope, and
  401 raised as its own case.
- `Schermes/Api/Thread.swift` holds the paging and merge helpers: the rules for stitching an
  `?after=` page onto what is already on screen, and for pairing a tool row with its assistant
  message across a page boundary. It was ported from the web UI that has since been removed, so
  this is now the only implementation of those rules.
- `Schermes/Api/Readable.swift` says a cron expression in words (croner's dialect, since that is
  what the daemon parses with) and turns an execution event into a sentence. A cron it cannot
  say exactly reads as nothing rather than as a guess.
- `Schermes/Session.swift` owns the server address, the Keychain password and the auth state.
- `Schermes/Views/` is the connect and login screens, the agent list, the chat, an agent's
  routines (schedules) and activity feed, and the settings: the provider and web search behind
  the gear under the agent list, the MCP servers behind the Plugins row above it. A stored key is
  never shown, and a blank key field keeps the stored one. On macOS and regular width an inspector
  column shows the picked agent's live screen as a thumbnail over its routines and activity; the
  full desktop it opens borrows the thumbnail's connection, so Xvnc only ever sees one viewer.
  Compact width reaches the same screens from the chat's toolbar instead. `About` under the agent
  list — and the Mac's own app menu, through a notification, because an `@State` on the `App`
  driving a sheet inside the `WindowGroup` stopped the window being made at all — carries the
  version, the daemon, and bloub's licence, which its terms require to travel with the app.
- `Schermes/Bloub/` is the avatar: the engine port, the `Canvas` view, the agent-state table and
  the local identity store.
- `Schermes/Assets.xcassets/AppIcon.appiconset` is one bloub on a dark tile, rendered at 1024 by
  `ImageRenderer` over the engine itself rather than drawn by hand, and downsampled for the Mac's
  sizes. The engine is a pure function of time, so re-rendering it gives the same picture.

In the composer, Return sends and Shift+Return is the newline. A vertical `TextField` takes Return
as a newline by default, so `onKeyPress` answers it — both ways, because returning `.ignored` does
not hand the press on to the field, it drops it, which was measured rather than assumed. The shift
branch therefore writes its own `\n`, on the end of the draft: a `TextField` binding is the whole
string and says nothing about the cursor. That is a hardware keyboard only, which is where
Shift+Return exists; an iPhone's software keyboard still inserts a newline and sends with the
button. ⌘Return sends too.

## The avatar

Each agent is a bloub: a body that morphs with what the agent is doing, blinking and drifting when
it is not. `BloubEngine.sample(_:)` is a pure function of time, so a frozen board cell and a
running avatar draw the same picture and the whole thing is testable without a view.

`AgentState` maps onto a bloub state through one table in `Schermes/Bloub/AgentBloub.swift`.
bloub plays `comet` and `orbit` once, but an agent holds a tool state for as long as the tool runs,
so `BloubPlayer` loops a measured stretch of each clip (`heldLoop`) while the state lasts, except
under Reduce Motion. Shape and colour are the agent's identity; the daemon has no field for either, so they live in
`UserDefaults` keyed by the agent's name, with a deterministic default read off a hash of that
name — an agent seen for the first time already looks like itself, and still does after a
relaunch. Pick them when creating an agent, or tap the pill in its chat to change them.

Two colours are drawn off bloub's palette. bloub paints on a light page only; here `ink` on a dark
ground and `cream` on a light one would all but vanish, so on that ground they are drawn as a light
grey and a sand (`BloubColorId.rgb(dark:)` in `Schermes/Bloub/BloubView.swift`). The engine and its
goldens are untouched.

In a debug build the **States** button under the agent list opens a board of all fifteen states
side by side over any shape and colour, which is how the port gets eyeballed.

`SchermesTests/BloubGoldens.swift` holds reference values produced by running bloub's own
TypeScript engine at the ported commit. The tests assert the Swift port against them — body
outlines, eye transforms, orbit geometry and the whole eye-offset table — so a drift in the port
fails a test instead of quietly changing the face.

## Credits

The avatar is a Swift port of [bloub](https://github.com/jeremy-prt/bloub) by Jérémy Perret, at
commit `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`.

```
MIT License

Copyright (c) 2026 Jérémy Perret

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
