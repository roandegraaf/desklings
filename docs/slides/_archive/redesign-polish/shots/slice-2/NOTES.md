# Slice 2: no seam (owner #1), renders vs `Main`

Renders: `mac-{main-agent,main-mo,main-bare,needs-you,goal,search}-{light,dark}.png` with a `.views.txt` dump each,
plus `.sheet.png` for search, page-rules and new-agent (sheets now present from inside the hosted panes; all
six pages, new agent and search attached a sheet in both modes in a scratch run).
`main-bare` is Juno with the inspector toggled off (`-schermes.debugOpen bare:juno`, new DEBUG lever).

## What failed on the way (why the split view is now our own)
1. **SwiftUI.** `.containerBackground(_, for: .navigation)` / `.navigationSplitView` are iOS/watchOS only:
   the build fails with `'navigation' is unavailable in macOS`. No other macOS column-background modifier.
2. **AppKit behind `NavigationSplitView`.** An `NSViewRepresentable` that walks to both `NSSplitView`s can hide
   `NSSplitDividerView` and `_NSSplitViewShadowView` (private class names, dump showed them `hidden`), but
   `NSGlassEffectView` stays in both columns. `NSSplitViewItem.behavior` is read-only and macOS 26 has no
   public switch for the sidebar/inspector glass. Setting the glass `style = .clear` / `tintColor = .clear` leaves the view in
   the tree, still composited by the window server (the renderer can't see it, so a render would look clean
   while the real app keeps the seam).
3. **Built:** `MacSplit` (`Views/Sidebar.swift`), an `NSSplitViewController` with three *default* items
   (no glass), on macOS only. iOS keeps `NavigationSplitView` unchanged.

## View dumps (all 12)
`grep -cE 'NSGlassEffectView|NSSplitDividerView|_NSSplitViewShadowView'` → **0** in every dump (slice 1: 2 glass,
2 dividers, 2 shadows). Panes (`_NSSplitViewItemViewWrapper`):
- inspector shown (main-agent, main-mo): `10 | 292 | 10 | 768 | 10 | 340 | 10` = 1440.
- inspector shut (main-bare, needs-you, goal): `10 | 292 | 10 | 1118 | 10`, inspector collapsed off the edge.

## Matches `Main`
- One `Theme.window` ground, 10pt round the window, 10pt gutters, three r22 cards: sidebar 292, chat, inspector 340.
- No divider line, column shadow or grey column edge, in light and dark.
- Sidebar and inspector fill: white 66% (`Theme.card.opacity(0.66)`), white 90% 1pt border, shadows
  0 1 2 and 0 12 32 at 6% (SwiftUI radius 1 / 16).
- Traffic lights on the sidebar card. Chat header 16pt into its card (Main's `padding: 16px 20px 10px 24px`).
- The gutter is the split view's divider (10pt, draws nothing): drag it to resize, drag past the minimum to collapse.

## Fixed on the way
- With no thread picked, the empty states shrank the chat ground and the inspector card to their own size (a split
  item doesn't stretch content like a `NavigationSplitView` column): both panes now take a max frame first
  (`mac-search-*`).

## Differs
- Traffic lights sit at (19, 19) in the window, i.e. 9pt inside the card. Main has (29, 27). They come from the
  macOS unified-toolbar title bar (an empty `NSToolbar`); moving the buttons by hand is fragile, left.
- Sidebar search row starts about 62pt from the window top against Main's 51: the `List` adds its own top inset
  on top of the 41pt padding. Small; left for the sidebar pass.
- The inspector card has the two-layer shadow too (NEXT_SLIDE asked for it; Main's `<aside>` has none).
- Inspector contents, composer, sheets: later slices (unchanged here).
- Renderer limits as before: controls draw inactive (grey traffic lights, grey switches).

## Dark values (placeholder, no canvas value)
`Theme.card` dark `#232127` at the same opacities over `Theme.window` dark `#0f0e12`:
panel `#1c1b20` (exactly the old `Theme.panel` dark), border `#222026`. Panel vs window 1.12:1 in both modes
(same as light); ink on panel 15.2:1 dark, 17.3:1 light. The dark border is barely visible, like the light one.
Shadow is black 6%, invisible on the dark ground.
