# Slice 1 shots: matches / differs

Rendered 2026-10-01 against a cloned bed daemon (agents mo, ledger, scout, juno, pixel). iPhone 17 Pro
simulator at 3x; Mac lever app at 1x. Board references: Foundations "Buttons", MacNeedsYou,
PhoneNeedsYou, PhoneChat.

| Screen | Matches | Differs (and why) |
|---|---|---|
| `iphone-needs-you-light.png` | Pills: Don't / Keep it / Open secondary (ink 6%), Approve agent bubble (Juno blue `#2f76c0`), Delete it destructive `#b3261e`, Retry primary ink; h40 r20 14 semibold as PhoneNeedsYou | Large title is SF Pro, not Rounded; card headers not rounded. Slice 6 (Needs you) and slice 5 (rounded titles). |
| `iphone-needs-you-dark.png` | Same kinds; primary is light ink with dark text; secondary is ink 6% | Destructive in dark is `#ff8a80` with dark text: the canvas has no dark board, chosen for 4.5:1 (see Placeholder choices). |
| `iphone-chat-light.png` | Idle Send is the secondary circle with a muted arrow, as PhoneChat draws it; thread tint and bubble unchanged | Bubble tail corner, date capsule instead of hairline divider. Slice 3 (chat). |
| `iphone-chat-dark.png` | Same as light | Same as light. |
| `mac-needs-you-light.png` | Pills h36 r18 13 semibold, same kinds as above; unread dots are ink, no longer system blue | Window shell, sidebar, title bar still stock. Slice 2. |
| `mac-needs-you-dark.png` | As light; unread dots light ink | As light. |
| `mac-chat-light.png` | Idle Send secondary circle; unread dots ink | Toolbar header, inspector unstyled. Slices 2 and 3. |
| `mac-chat-dark.png` | As light | As light. |

Every "differs" above belongs to a later slice's scope; none is a slice-1 defect.
