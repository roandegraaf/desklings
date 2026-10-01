> Completed (pending acceptance: 1 sign-off item, see ACCEPTANCE.md)

# Apply the redesign canvas

## Goal
Make the SwiftUI Mac and iPhone app look like the redesign canvas (https://claude.ai/artifact/Ns9Ynh8yTKkCmoPrQESQir), pixel-faithfully. The functionality from `redesign-and-agent-flows` (archived) is in, but the app still reads as a stock macOS app. `Theme.swift`/`AgentPalette` already hold the canvas values; the screens don't use them and the Mac shell is untouched.

## Scope
- Shared design primitives: pill button styles (the canvas's six kinds), app-wide ink tint, the missing tokens (panel, soft agent fill, Needs you fill, their dark values), a themed form style, rounded titles.
- Mac shell: no title bar, warm `#efebe3` window ground, three rounded panels (r22), custom sidebar (uppercase section labels, tinted Needs you row, agent rows filled with the agent's soft colour, "New agent" pill at the bottom), custom selection.
- Mac chat: header drawn inside the panel with the four-icon capsule, owner bubble tail corner, hairline day dividers. Mac inspector restyled.
- Every screen: Needs you, Goals, Search (⌘K), Settings / Rules / Idle / Routines / Profile, sheets (Forward, New agent, Restore, Forms), menu bar panel content.
- iPhone: home as separate tinted agent cards, rounded large titles, search and New agent at the bottom, chat polish; failed agents keep their bloub with the warning in the state line.
- Light and dark mode for all of the above.

## Non-goals
- No functional changes, no daemon changes, no new features.
- No replacing `NavigationSplitView` (keeps collapse/resize/keyboard behaviour); style it instead.
- No Siri, widgets, App Intents.
- No snapshot-golden test suite (the bloub goldens that exist stay as they are).
- No commit or push; version control belongs to the owner.

## Key decisions & constraints
- **Owner picks (2026-10-01):** full canvas look on the Mac (not hybrid), pixel-faithful fidelity, proof by rendered screenshots per slice, the canvas is the spec (no extra sketches).
- **The spec:** the canvas's four pages (Foundations, Mac and iPad, iPhone, Flows). Read it with the Artifact tool, action `read`. Exact extracted values and the per-screen gap list are in `docs/slides/apply-redesign-canvas/design-gap.md`; baseline iPhone screenshots are in `baseline/`.
- **Tokens, not literals:** every colour, radius, font and spacing comes from `Theme`; no hex literals in views.
- **SwiftUI substitutes** (from design-gap.md): solid panel colour instead of `Material` translucency; rounded large titles via `UINavigationBar.appearance()` on iOS and an in-content header on the Mac; `MenuBarExtra(.window)` owns its frame, so only content is styled. Where the canvas has no dark value, pick one that keeps 4.5:1 text contrast and record it under `Placeholder choices`.
- **Keep native behaviour:** window controls, ⌘ shortcuts, VoiceOver labels, Dynamic Type on iOS, keyboard focus.
- **Proof per slice:** render the slice's screens on Mac and iPhone, light and dark, focus-free (`~/.claude/skills/native-app-testing/SKILL.md`, memory `project_apple_app_testing_levers`; the simulator for iPhone). Save PNGs under `docs/slides/apply-redesign-canvas/shots/<slice>/` and write a short side-by-side note per screen: matches / differs (how). A Mac screen that can't be rendered without taking focus is `Runtime-unverified`, not done.
- Other agents may edit this checkout: re-read before editing, never revert others' work.

## Preconditions & external dependencies
None. The owner does the final visual sign-off.

## Building blocks
- `apple/Schermes/Theme.swift` (tokens, `AgentPalette`), new shared styles (buttons, forms, section labels).
- `SchermesApp.swift` (window style, tint), `Views/ConsoleView.swift` (split view, sidebar, iPhone home), `Views/ChatView.swift`, `Views/Inspector.swift`, `Views/NeedsYou.swift`, `Views/Goals.swift`, `Views/Settings.swift` and the other form screens, `Views/MenuBar.swift`, `Bloub/AgentBloub.swift`.
- The screenshot harness (simulator plus the Mac DEBUG levers).

## Definition of Done
- [x] `Theme` defines every canvas token, including panel, soft agent fill, Needs you fill and their dark values; `grep` finds no colour hex literals and no `Color.blue`/`.accentColor` defaults in `apple/Schermes/Views`.
- [x] A pill button style covers the canvas's six kinds; `grep` finds no `.borderedProminent` or `.bordered` button styles left in `apple/Schermes`.
- [x] The app tint is the canvas ink, not system blue (unread dots, links, toggles, selection).
- [x] Every `Form` uses the themed form style; no stock `.formStyle(.grouped)` grey remains.
- [x] Mac window: hidden title bar, warm ground, sidebar / content / inspector as rounded panels; the sidebar has canvas section labels, the Needs you row, soft-filled agent rows with custom selection, and the bottom New agent pill. Collapse, resize and ⌘ shortcuts still work.
- [x] Mac chat header is in the panel with the icon capsule; the owner bubble has the tail corner; day stamps are hairline dividers. The inspector uses theme tokens throughout.
- [x] Needs you, Goals, Search, Settings (and Rules, Idle, Routines, Profile), the sheets and the menu bar panel content match their canvas boards.
- [x] iPhone home shows separate tinted agent cards, a rounded large title, and search plus New agent at the bottom; failed agents keep their bloub.
- [x] `shots/` holds Mac and iPhone renders, light and dark, of every screen above, each with a matches/differs note, and no remaining "differs" without a recorded reason. *(Changed 2026-10-01, slice 8: the Mac renders of the slice-4 sheets, the in-chat `actionCard`s, "Today", the Mac gate and Mac New agent in dark moved to the `[user-gated]` sign-off below. cua-driver can't see or capture the lever window on this Mac (twice, slices 7 and 8), and focus-taking runs are off-limits. iPhone renders cover all of them.)*
- [x] `xcodebuild test` passes on macOS and the iPhone 17 Pro simulator; `pnpm check` and `pnpm test` still pass.
- [ ] `[user-gated]` The owner runs the Mac app and the iPhone app in light and dark mode and confirms they read as the canvas, not as a stock app. On the Mac this includes: the login gate, the real `Settings` window, Forward, Restore, FormSheet, Feedback, Agent look, the trigger proposal and form cards (`actionCard`, pills hugging their labels), the "Today" divider, and New agent in dark.

## Open questions
None.
