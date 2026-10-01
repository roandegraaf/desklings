# Slice 4: app Settings as a sheet

Renders: `mac-settings-<tab>-{light,dark}.png` (main window, dimmed under the sheet) plus `.sheet.png` (the sheet),
for model, web, notifications, plugins, daemon and about. `ONLY=settings`, bed daemon on 7911, 1440x900 window.
Each dump has the sheet attached (`NSSheetEffectDimmingView`) and all three split items shown.

## Matches (Main's card language)
- The sheet sits over the console window: three cards on the ground behind the dimming, and the sidebar's bottom
  gear is a round secondary pill next to New agent, as in Main.
- Header: "Settings" in `.sectionTitle` ink on the left, a primary ink "Done" pill on the right (Esc dismisses).
- Tab strip: the Rules page's quiet track (ink 5%, r14, 4pt inset) with the picked tab filled in ink, r10. Light and
  dark both read; in dark the picked tab is the light ink bubble.
- Ground: `Theme.ground` sheet background in both modes. No white system toolbar strip, no stock grey Done.
- The slice-1 garbled tab strip (borderless Settings window) is gone along with the window.

## Differs (recorded, next slices)
- Pages keep their grouped-form section fill (`#ecebe7`-ish on ground), stock `(...)` menu buttons on Models and
  Plugins, and duplicate in-page titles ("Models" under the Models tab). This is the audit's "grouped forms" and
  "Settings tabs" gaps, which this slice leaves alone by design.
- Sheet size: 700pt wide (its minimum; AppKit opens a sheet at the minimum), 580 high. At 640 the equal-width tabs
  truncated ("Web s…", "Notific…"). The labels now keep their natural width (`fixedSize`) and the minimum is 700.
- No Mac app-settings board exists, so the header and tab track are borrowed from MacSettings and Rules.

## Found on the way: the split autosave leaked into the owner's defaults
The first renders showed no sidebar card. The owner's `dev.schermes.Schermes` defaults held
`NSSplitView Subview Frames console.split` with frames for a 1200x800 window and the sidebar collapsed (`YES`).
That's `MacSplitTests`' window size, so a test run wrote it after the test's own restore. It would have made the
real app launch with no sidebar. Fix: `MacSplitController` sets no `autosaveName` under `hostingTests`, so tests and
renders never read or write the owner's split. `MacSplitTests`' save and restore is gone. The leaked value was
deleted from the owner's defaults, with a backup in `shots/slice-4/console.split.leaked.txt`. The full test run and the renders now leave the key alone.

## Tests
`SchermesTests/SettingsTests.swift` `SettingsCommandTests`:
- `appMenuHasSettingsWithCommandComma`: the test host's main menu has "Settings…" with ⌘,.
- `settingsCommandOpensTheSheet`: posting `.showSettings` attaches a sheet to an offscreen window hosting
  `settingsSheet`.

## Leftovers and checks
- ⌘, does nothing while the console window is closed: the app lives on in the menu bar extra and only a live `ConsoleView` hears `.showSettings` (the old scene always answered). Reopen the console from the menu bar panel to reach settings. A fix would open the console window first (`openWindow(id: consoleWindowID)`), then post.
- The sheet still presents with the sidebar collapsed (first render pass: split item hidden, `NSSheetEffectDimmingView` present), so ⌃⌘S does not strand it.
