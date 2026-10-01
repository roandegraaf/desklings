# Schermes for iOS and Mac

A native SwiftUI app that talks to the schermes daemon's HTTP API. One target builds for both
iOS 26 and macOS 26 and every view is shared; the split view is a sidebar on a Mac and an iPad,
and its own screen on an iPhone.

## Targets

| Target | Platform | Sources | What it is |
| --- | --- | --- | --- |
| `Schermes` | iOS and macOS, one target | `Schermes/` | The app. On the Mac it also carries the menu bar extra and the "Send to Schermes…" Service. |
| `SchermesWidgets` | iOS | `SchermesWidgets/`, plus `AgentActivity.swift`, `Bloub/Skins.swift`, `Bloub/Tables.swift` | The Live Activity: lock screen and Dynamic Island views of an agent's turn. |
| `SchermesShare` | iOS | `SchermesShare/`, plus `Share.swift`, `Session.swift`, `Api/SchermesClient.swift`, `Api/Types.swift` | The share sheet's "Schermes" entry. |
| `SchermesTests` | iOS and macOS | `SchermesTests/` | Swift Testing, hosted in the app. |

Both extensions are embedded in the app with `destinationFilters: [iOS]`, so the Mac app ships
neither. They compile a handful of app files by path rather than the app's views, which is why the
widget repeats the app's state words and the share sheet draws no bloub and no `Theme` colours. The
share extension builds with `SCHERMES_EXTENSION`, which leaves out the app-only device
registration.

The two Mac-only pieces live in the app target:

- **Menu bar extra** (`Views/MenuBar.swift`, scene in `SchermesApp.swift`): a bell with the Needs
  you count, and a panel with a quick-message field (`@name message` picks the agent), the Needs you
  items and the agents working now. Only yes/no answers are given in place; everything else opens
  the console window. It polls on its own, because the console window can be closed while the
  extra lives on. ⌥Space opens it from any app through a Carbon hot key (no Accessibility
  permission); a test run skips registering it, and a clash with Alfred or Raycast fails silently.
- **Services** (`ShareService` in `Share.swift`, `NSServices` in `project.yml`): "Send to
  Schermes…" takes text, a URL or a file from any app and opens the same `SendToSheet` the iOS
  share extension shows. A new Service entry may need a relaunch, or
  `/System/Library/CoreServices/pbs -update`, before the menu shows it.

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

Signing is automatic on the owner's paid team (`DEVELOPMENT_TEAM` in `project.yml`, applied to
every target), which is what a device build, push and the app group need. The first device build
registers everything with Apple and makes the profiles:

```sh
xcodebuild -scheme Schermes -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

That one build registers three App IDs (`dev.schermes.Schermes`, `.Widgets`, `.Share`), the push
capability on the app, and the App Group `group.dev.schermes` on the app and the share extension.
Nothing needs clicking in the developer portal first.

A clone without that team still builds for the simulator and this Mac: put
`CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "-"` and an empty `DEVELOPMENT_TEAM` back under
`signing` in `project.yml`.

### Device builds only

Entitlements are applied to `iphoneos` builds only (`CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]`),
because a restricted entitlement needs a provisioning profile, and a Mac app that carries one
without a profile does not launch. So:

| File | Entitlements |
| --- | --- |
| `Schermes/Schermes.entitlements` | `aps-environment`, App Group `group.dev.schermes` |
| `SchermesShare/SchermesShare.entitlements` | App Group `group.dev.schermes` |
| `SchermesWidgets` | none: a Live Activity needs only `NSSupportsLiveActivities` in the app's `Info.plist` |

The simulator and the Mac build get no push token and no app group. Everything that needs either
is therefore checked on a physical iPhone, by the owner: remote and actionable push, the Live
Activity started and updated over APNs, and the share extension (its login hand-off goes through the
group). The Live Activity's views can still be looked at on a simulator with the DEBUG launch
argument `-schermes.debugActivity YES`, which starts a local one with made-up content.

**The app group.** The share extension has no `Session` and cannot see the app's container, so the
iPhone app shares two things with it through `group.dev.schermes`:

- the daemon address, mirrored into the group's `UserDefaults` suite on every connect
  (`Session.storeAddress`);
- a second Keychain copy of the owner password with the group as its access group, added beside
  the app's own item rather than in its place (`Keychain.save`, `Keychain.shareWithExtension`).
  Signing out clears both.

The extension reads the address, logs in with that copy on a 401 and keeps its own cookie after that
(`StoredDaemon` in `Share.swift`). In a simulator build the group add fails quietly, the extension
finds no address, and it says "Open Schermes and sign in first." The Mac never touches a group
container, since one it is not entitled to can raise a privacy prompt; its Service runs inside the
app and uses the ordinary defaults.

## A daemon to talk to

`docker compose up -d` in the repository root gives one on `http://127.0.0.1:7777`. On first
launch the app asks for that address, then for the owner password — which it sets if the daemon
has no owner yet, and checks if it has.

## App Transport Security

`NSAllowsArbitraryLoads` is on, and that is deliberate. The daemon speaks plain HTTP by design;
TLS belongs to a reverse proxy in front of it, not inside it. Without this the app could not reach
a daemon on `http://127.0.0.1:7777` or on a LAN address at all. A bare domain typed into the
connect screen gets `https://` on its own; an IP, a single-label name or a `.local` name gets
`http://`. The https path is unaffected by this setting.

## Session and password

The daemon's session cookie carries an expiry, so `HTTPCookieStorage` writes it to disk and a
relaunch is still logged in. The owner password goes to the Keychain under the daemon's address, so
it is only ever sent back to the daemon it was set on, and one 401 on any guarded
request spends it once to log back in and retries that request. A second 401 shows the login
screen. Auth routes never take that path: `POST /api/auth/login` answers 401 for a wrong password,
and retrying it would loop.

## What the chat offers

A reply renders as Markdown, with fenced code in a box that copies; long-press or right-click a
bubble to copy it. The paperclip attaches a photo or a file: an image goes inline on the message and
the agent sees it; any other file is uploaded into the agent's `~/uploads` and the message names
where it landed. A file an agent names in a reply, `~/workspace/report.xlsx` or its full path, is shown
where it is named: on a line of its own as a card with its type, an image as the picture itself,
inside a sentence as a link with the file's name. A tap opens a Markdown, HTML, SVG, code or text
file as an artifact: a pane beside the chat on a Mac and an iPad, a sheet on a phone, with a
rendered preview, its source, copy and save. Anything else opens in Quick Look. The arrow saves a
file to Downloads on a Mac and through the Files sheet on a phone. On a Mac an image can also be pasted into the composer or dropped on the chat. The red stop button, or Escape, ends the agent's turn. The More menu on a
phone, or the toolbar on a Mac and an iPad, exports the loaded thread as Markdown and opens the
agent's pages (profile, rules, when idle, routines and triggers, activity, memory); the memory page
rewrites `MEMORY.md`. The sidebar's "Search or ask" field asks the daemon (`POST /api/search`),
which reads the question with the default model into filters over messages, files and screenshot
text, and falls back to plain words without one. On a Mac, a turn that ends or a Needs you item
that arrives while the app is not in front becomes a notification, and the badge counts unread
threads and Needs you items.

## Push notifications

The daemon pushes over APNs when an agent finishes a turn or asks for something, so a phone hears
about it with the app closed. The app asks for notification permission, registers for remote
notifications, and hands the device token to the daemon (`POST /api/devices`) together with
its bundle id, team id and `aps-environment`, read off its own embedded provisioning profile, so
the daemon's push settings fill themselves in; "Send test push" proves the path. Only a **device build signed by a real team** gets a token: the
`aps-environment` entitlement in `Schermes/Schermes.entitlements` is applied to `iphoneos` builds
only (`CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` in `project.yml`), because it needs a provisioning
profile, which the team's automatic signing supplies for a device. The simulator and the Mac
build register no token, so on them the Settings screen shows why under Devices and the daemon
has nobody to push to.

**Environment.** The daemon keeps one APNs gateway for all devices, and the last build to register
picks it: a profile saying `development` (every Xcode device build) switches it to the sandbox,
`production` to the live gateway. A build with no embedded profile reports `production`. An Xcode
build and a TestFlight build on two phones therefore cannot both be pushed to at once.

**Actionable push.** A push about a Needs you item carries its id and a category, registered at
launch by `PushCategory` in `Notifier.swift`:

| Category | Buttons |
| --- | --- |
| `needs.approval` | Approve (unlocked device only), Don't |
| `needs.delete` | Keep it, Delete it (destructive, unlocked device only) |
| `needs.yours` (passwords and security) | I'll do it, Don't |
| `needs.watch` (a hand-over) | Watch (opens the app) |
| `needs.open` (everything else) | Open (opens the app) |

Yes and no answer through `POST /api/needs-you/:id/action` from the background, on a client of its
own built off the stored address, since a background launch has no `Session`. "Always allow" is
never offered on a lock screen. A failed answer comes back as a local notification.

**Live Activity.** While a permanent agent runs a turn, the daemon starts, updates and ends a Live
Activity on the phone over APNs (goal title, steps done, a Needs you count, the state). The app
hands the daemon its push-to-start token and each running activity's own token
(`POST /api/live-activities`, `LiveActivityTokens` in `Notifier.swift`) from launch on, because a
push-to-start wakes the app in the background. The payload's shape is `AgentActivity.swift`, shared
with `SchermesWidgets`, and `AgentActivityTests.swift` pins it against the daemon's JSON.

The APNs key itself comes from the developer portal, once per team: Certificates, Identifiers &
Profiles ▸ Keys ▸ add a key with **Apple Push Notifications service (APNs)** enabled and download
the `AuthKey_<KEYID>.p8` (it can be downloaded only once). Put its path and id in the daemon's
`.env` as `SCHERMES_APNS_KEY=/path/to/AuthKey_<KEYID>.p8` and `SCHERMES_APNS_KEY_ID=<KEYID>`,
restart the container, install on the phone, allow notifications, and press "Send test push" in
Settings ▸ Notifications. That screen also takes a pasted key for a daemon nothing can be mounted
into.

## Deleting things

Right-click (or long-press) an agent in the list for its name and appearance, its pages, its rules,
what it does when idle, and **Delete**; a shared thread and a task worker have a Delete of their own. Every one of them asks
first and says what goes with it. `DELETE /api/agents/:name` takes the agent's workers, its threads,
its routines and its history; its Linux user and home stay, because that is the agent's work and no
button here is worth destroying it. The daemon stops the desktop before it drops the row, so the
display number can be handed out again. Either delete is refused with a 409 while a turn is running.

Agents can ask for the same two deletions through the `request_deletion` tool, and nothing happens
until the owner answers: the request stands in `approvals` and appears under Needs you (and as a
push) with **Delete it** and **Keep it**. Either answer drops the request and writes the outcome back into
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
- `Schermes/Session.swift` owns the server address, the Keychain password and the auth state, and
  on iOS mirrors the address and a password copy into the app group.
- `Schermes/Notifier.swift` is local notifications, push registration (`PushRegistration`), the
  actionable categories, the background relay that answers them, and the Live Activity tokens.
- `Schermes/Share.swift` is shared by the app and `SchermesShare`: the shared item, the message it
  becomes, the upload name, `StoredDaemon`, `SendToSheet`, and the Mac `ShareService`.
- `Schermes/AgentActivity.swift` is the Live Activity's attributes and state, compiled by the app
  and `SchermesWidgets`; the widget's views are `SchermesWidgets/AgentActivityWidget.swift`.
- `Schermes/Views/` is the connect and login screens, the agent list, the chat, an agent's
  routines (schedules) and activity feed, and the settings: one gear opening
  six categories — Models, Web search, Notifications, Plugins (the MCP servers), Daemon and About.
  Models is the daemon's model registry (`/api/models`): every provider entry, which one is the
  default and which the backup, a Test per entry, and each agent can be given its own on its
  overview. The app no longer reads or writes the provider fields of `/api/settings`.
  On the Mac that gear sits under the agent list as a `SettingsLink` into a real `Settings` scene,
  which brings ⌘, and the app menu's Settings… item with it; on iOS it is in the bottom bar beside
  the search field and opens a sheet. A stored key is never shown, and a
  blank key field keeps the stored one. Plugins edits one MCP server at a time in a sheet, which
  also takes a pasted `{"mcpServers": {…}}` README snippet to fill itself from. On macOS and regular width an inspector
  column shows the picked agent's live screen as a thumbnail over an overview — its state, the
  user it runs as, its model, and the pages (profile, rules, when idle, routines and triggers,
  activity, memory; a task worker gets no rules or idle page), each pushed on its own so only the
  page on screen polls; the
  full desktop it opens (its own resizable, full-screen-capable window per agent on the Mac) shares
  the thumbnail's connection through `Desktops`, so Xvnc only ever sees one viewer.
  Compact width reaches the same screens from the chat's toolbar instead. The About page carries
  the version and bloub's licence, which its terms require to travel with the app; the Mac's own
  app menu opens the same content as a sheet through a notification, because an `@State` on the
  `App` driving a sheet inside the `WindowGroup` stopped the window being made at all.
- `Schermes/Bloub/` is the avatar: the engine port, the `Canvas` view, the agent-state table and
  the local identity store.
- `Schermes/Assets.xcassets/AppIcon.appiconset` is one bloub on a dark tile, rendered at 1024 by
  `ImageRenderer` over the engine itself rather than drawn by hand, and downsampled for the Mac's
  sizes. The engine is a pure function of time, so re-rendering it gives the same picture.
- `SchermesTests/` is the one test target, run on both platforms. Wire types are pinned in
  `TypesTests`, the palette and state words in `ThemeTests`, the Live Activity JSON in
  `AgentActivityTests`, the share message and file names in `ShareTests`, the menu bar's
  `@name` parsing in `QuickMessageTests`.

Where the newer screens live, in `Schermes/Views/` unless named otherwise:

| File | Holds |
| --- | --- |
| `Theme.swift` | The design system: `Token` light/dark pairs, `Theme` grounds, ink and state colours, `AgentPalette` (each agent's tints, derived from its bloub colour and pinned by goldens), the state line and the context-fullness ring and meter. |
| `NeedsYou.swift` | The Needs you page, card and iPhone strip, fed by `/api/needs-you`: approvals, questions, failures, hand-overs, forms, goals. Also the "Right now" busy rows the menu bar reuses. |
| `Rules.swift` | An agent's rules: one level per category, pre-approved targets, passwords always the owner's. |
| `Settings.swift` | Settings, including the Models page and its edit sheet. |
| `Forms.swift` | A web form an agent asks the owner to fill: the sheet with native fields and the chat card. |
| `ChatView.swift` | Besides the chat: thumbs up/down with the `FeedbackSheet`, and the retry, hand-over and stuck-browser cards. |
| `Idle.swift` | "When idle" settings and the "Last night" panel of what idle work did. |
| `Triggers.swift` | Proposed and live triggers: the chat card, the rows, and the list inside Routines. |
| `Goals.swift` | Goals: the sidebar rows and cards, the goal page, helpers drawn under their lead. |
| `Search.swift` | The search answer: what the question was read as, and the hits. |
| `Restore.swift` | The rewind sheet that shows which files come back and what cannot be undone. |
| `Forward.swift` | "Send to…" on a message or a file card, to another agent. |
| `NewAgent.swift` | A new agent from a description: the daemon suggests a label, tagline, look, rules and a routine, all editable before Create. |
| `MenuBar.swift` | The Mac menu bar extra and the ⌥Space hot key. |
| `Vnc/DesktopView.swift` | The agent's screen, including "Show how" (teach a skill): recording the owner's input, the Secret toggle and "Stop and hand over". |
| `Notifier.swift` (app root) | The actionable push categories. |

In the composer, Return sends and Shift+Return is the newline. A vertical `TextField` takes Return
as a newline by default, so `onKeyPress` answers it — both ways, because returning `.ignored` does
not hand the press on to the field, it drops it, which was measured rather than assumed. The shift
branch therefore writes its own `\n`, on the end of the draft: a `TextField` binding is the whole
string and says nothing about the cursor. That is a hardware keyboard only, which is where
Shift+Return exists; an iPhone's software keyboard still inserts a newline and sends with the
button. ⌘Return sends too.

A draft that starts with `/` opens the command list above the composer (`Views/Commands.swift`),
the way a Telegram bot's does: letters narrow it, ↑↓ move the picked row, Tab and Return complete
it, and a row answers a tap. A command with nothing to fill in runs the moment it is completed;
`/remember` is put in the composer for its note. Only a whole name counts when the draft is sent,
so a path like `/home/agent-x/report.md` goes to the agent as words. The commands are the chat's
own buttons and pages by name — `/new`, `/compact`, `/stop`, `/retry`, `/undo`, `/remember`,
`/interview`, `/screen`, `/profile`, `/routines`, `/activity`, `/memory` — and a shared thread
offers only the first five. Matching ignores case because the iPhone capitalises the first letter
of whatever is typed.

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
