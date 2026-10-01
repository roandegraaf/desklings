# Slice 5: iPhone home

Bed: Mo and Pixel failed, Scout busy (thinking), Ledger and Juno each with one pending approval. Private
iPhone 17 Pro sim (iOS 26.5), compared against canvas board `PhoneHome` and the `Foundations` state specimens.

## iphone-home-light.png / iphone-home-dark.png
- Matches: left-aligned large title "Agents" in SF Rounded bold (largeTitle); round settings button; Needs you strip
  (unchanged, plus an inner chevron); one r20 card per agent filled with its `AgentPalette.tint`, bloub 48, rounded bold
  name + tagline, state line, last line; count capsule in the agent's bubble colour (Ledger amber, Juno blue) for
  pending items; ink unread dot otherwise; no separators, 8pt between cards; busy halo on Scout with the accent
  "Thinking"; bottom bar = search capsule (card 86%, white border, soft shadow, h52) + ink round "+" (52).
- Matches: failed agents keep their body with X eyes, face near-frontal like the Foundations specimen, and the
  warning in the state line ("Failed", failed colour).
- Differs: the settings button sits in the navigation bar row above the title, not beside it (iOS 26 large title
  placement; no API puts a bar item on the title's line).
- Differs: the state line with pending items reads "Needs you" (no " · payment" detail), as on the Mac sidebar
  (slice 2 placeholder).
- Differs: no goal cards in the bed, so the goal row (white r18) is not in the shot; the code path is unchanged
  apart from its insets.
- Differs: the X eyes are holes showing the paper colour (light), not the canvas's dark strokes, consistent with how
  every other bloub eye is drawn in the app.
- Differs: gap title to strip and strip to first card is the List's (about 14 / 18pt), canvas 14 / 14.

## iphone-home-search-dark.png
- Typing filters the cards (only Scout left), Return runs the search and shows the "Search" section; the clear (x)
  button empties the field and drops the answer. Same behaviour as the old `.searchable` field.

## ipad-split-light.png
- iPad (regular width) keeps the split view: Search ⌘K row, Needs you row with badge, plain agent rows, toolbar
  `+`, bottom gear, chat and inspector. Failed agents there also show the X-eyed bloub (shot taken before the
  failed face was turned near-frontal, so its crosses still sit at the rest gaze's angle).

Also checked: tapping a card pushes its chat, the back button pops to the home.
