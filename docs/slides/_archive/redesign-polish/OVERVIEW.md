Completed (pending acceptance: 1 owner sign-off plus runtime checks, see ACCEPTANCE.md)

# Redesign polish: make the Mac app read as one whole

## Goal
The `apply-redesign-canvas` task (archived, `docs/slides/_archive/apply-redesign-canvas/`) styled every screen, but the
owner's review of the real Mac app says it doesn't feel finished. The canvas felt like one whole; the app still shows
seams, stock leftovers and screens that drift from the boards. This task closes that gap, starting from the owner's
three findings and then a board-by-board Mac audit for the "little things".

Canvas: https://claude.ai/artifact/Ns9Ynh8yTKkCmoPrQESQir (Artifact tool, action `read`, `path` =
`project/<Board>.dc.html`; strip `<svg>` blocks with `perl -0pe 's/<svg.*?<\/svg>/<svg\/>/gs'`). Boards: Main,
MacSettings, MacNeedsYou, MacGoal, MacSearch, MacMenuBar, Foundations, Colours, the Flow* boards and the Phone* boards.

## Owner findings (2026-10-01)
1. **Inspector seam.** A hard cut where the right inspector column shows a different background next to the chat panel.
   Cause: `.inspector` in `Views/ConsoleView.swift:258` gets the panel via `.macPanel(Theme.panel, …)`
   (ConsoleView.swift:760-765), but the inspector *column* keeps its own system background around it. In the canvas
   (`Main`, `<aside>`), the inspector is a floating 340pt card at r22, `rgba(255,255,255,0.66)` with a
   `rgba(255,255,255,0.9)` 1pt border, straight on the window ground. Check the left sidebar for the same seam.
2. **Inspector contents.** The app lists six page rows (Profile, Rules, When idle, Routines and triggers, Activity,
   Memory). The canvas inspector shows none: it has the Screen section (state chip, Take control in the agent colour,
   pop-out), the agent's goal with worker rows, and Routines and triggers inline with "Ask <agent> to set one up". Pages
   are reached from the chat header capsule (Routines, Memory, the agent's settings gear) and the agent settings page.
3. **Settings.** App settings live in a separate `Settings` scene (`SchermesApp.swift:125`) and don't match the app.
   The canvas draws settings inside the main window: `MacSettings` replaces the main panel with "<agent>'s settings"
   (Rules matrix, with Routines and triggers and When idle in a side column, plus "Name and appearance" and "Memory"
   buttons). The sidebar's bottom gear opens settings. The owner wants settings inside the app, not as a separate window.

## Scope
- A focus-free way to render the real Mac views (see the first decision below), used for every Mac slice.
- The three findings above, then every gap the board-by-board audit finds: spacing, type, colours, corner radii,
  stock controls (pickers, toggles, steppers, segmented controls, menus), empty states, seams between panels, dark mode.
- Mac first; iPhone/iPad only where the same component is shared or the audit finds an obvious miss.

## Non-goals
- No daemon changes, no new features. Board elements that need new behaviour (Search's Open / Show in thread / Send to,
  "Review payment", elapsed time on working rows) stay out, as in the last task.
- Moving where a screen lives (inspector rows to the header and the settings page, Settings window to in-app) is in
  scope. Every existing page and setting must stay reachable. Removing one is a functional change and needs the owner.
- No commit or push.

## Key decisions & constraints
- **Mac proof is mandatory, not owner-gated.** Last time the Mac sheets were pushed into the owner's sign-off because
  cua-driver couldn't capture the window. That is how these issues got through. Slice 1 builds a render path that
  doesn't need cua-driver or ScreenCaptureKit. Try first: an offscreen borderless `NSWindow` hosting an `NSHostingView`
  of the real view with fixture data, captured with `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`,
  inside `xcodebuild test` (a test that writes PNGs to a path from an env var) or a swiftc probe. `ImageRenderer` skips
  ScrollView content (memory `project_swift_test_gotchas`), so don't use it. It must render the whole Mac shell (split
  view, inspector, panels) in light and dark. If it can't render the shell, report that before building more.
- **Settings in-app:** app settings open as a sheet over the main window (a full settings UI doesn't fit a popover).
  ⌘, keeps working via `CommandGroup(replacing: .appSettings)`, and the `Settings` scene goes. An agent's settings
  become the in-panel page from `MacSettings`. The sidebar gear sits next to the New agent pill, as in `Main`.
- **Tokens, not literals:** colours, radii and fonts come from `Theme` (`Views/Theme.swift`). Reuse `PillButtonStyle`,
  `ThemedForm`, `MacPanel`, `SidebarLabel`, `Font.canvas`, `actionCard`. Dark values the canvas lacks go under
  `Placeholder choices` with their contrast ratio.
- **Keep native behaviour:** sidebar and inspector collapse/resize, ⌘ shortcuts, VoiceOver labels, keyboard focus.
- Never take the owner's focus. Follow `~/.claude/skills/native-app-testing/SKILL.md` and memory
  `project_apple_app_testing_levers`. Other agents may edit this checkout: re-read before editing, never revert
  others' work.

## Building blocks
- `apple/Schermes/Views/ConsoleView.swift` (split view, sidebar, inspector), `Views/Sidebar.swift` (`MacPanel`),
  `Views/Inspector.swift` (`AgentInspector`), `Views/Settings.swift`, `Views/Rules`/`Routines`/`Profile`/`Memory`/
  `Activity.swift`, `SchermesApp.swift` (scenes, commands), `Views/Theme.swift`.
- Last task's notes: `docs/slides/_archive/apply-redesign-canvas/` (`design-gap.md`, `PROGRESS.md` current state,
  `shots/*/NOTES.md`).

## Definition of Done
- [x] A focus-free Mac render path exists, documented in PROGRESS `## Current state`, and renders the full Mac window
      (sidebar, chat, inspector) in light and dark.
- [x] No seam: sidebar, chat and inspector are separate panels on one continuous window ground, in light and dark.
      The inspector matches `Main`'s card.
- [x] Inspector contents match `Main` (Screen, goal, routines inline). Every page that used to be a row is still
      reachable from the header capsule or the agent settings page; any page without a canvas home was decided with
      the owner.
- [x] App settings open inside the main window (sheet), ⌘, works, there is no separate `Settings` window, and the
      agent settings page follows `MacSettings`.
- [x] `shots/audit.md` lists every Mac board with each gap found, and each gap is fixed or has a recorded reason.
- [x] `shots/` holds Mac renders, light and dark, of every board after the fixes, side by side with a matches/differs
      note. This item can't move to `[user-gated]`.
- [x] `grep` finds no hex literals, `Color.blue`/`.red`, `.accentColor`, `.bordered*` or stock `.formStyle(.grouped)`
      outside `Theme.swift` and the share extension.
- [x] `xcodebuild test` passes on macOS and a private iPhone 17 Pro sim; `pnpm check` and `pnpm test` pass.
- [ ] `[user-gated]` The owner runs the Mac app in light and dark and agrees it reads as one whole, like the canvas.

## Open questions
- ~~Activity and Profile have no obvious canvas home.~~ Decided 2026-10-01 (option A): Profile folds into "Name and
  appearance"; Activity is a third pill in the agent settings page header beside "Name and appearance" and "Memory".
