# Slice 2 shots: matches / differs

Rendered 2026-10-01 at 1440x900 pt against a cloned bed daemon (agents mo, ledger, scout, juno, pixel; 4 Needs
you items; no goals, helpers or shared threads in the bed). Mac lever app, background launch, screenshots
downscaled to 1568 px wide. Board references: `Main.dc.html`, `MacNeedsYou.dc.html`.

| Screen | Matches | Differs (and why) |
|---|---|---|
| `mac-chat-light.png` | No title bar; `#efebe3` window; sidebar, chat and inspector are r22 panels with 10pt window padding and 10pt gutters; traffic lights sit on the sidebar panel. Sidebar: "Search or ask ⌘K" field row (ink 6%, r10); Needs you row on `#fdeedd` with an orange r10 tile and an ink count capsule; uppercase 11pt AGENTS label; agent rows with bloub 34, rounded 15 bold names, 12pt state line, count capsule in each agent's bubble colour; Mo picked = violet soft fill r14, no system highlight; ink "New agent" pill h40 plus round Settings button at the bottom. Chat panel on Mo's tint. | Sidebar is 240pt, not 292: the window kept its saved column width (ideal is now 292). The state line says "Needs you" without the board's "· payment": the daemon's item titles are full sentences and truncated to nothing. The chat header pill, the toolbar icons floating at the panel's top, the date capsule and the inspector content are slice 3. The board's Goals and Messages sections don't show because the bed has no goals or shared threads. |
| `mac-chat-dark.png` | Same layout. Panels `#1c1b20` on window `#0f0e12`; soft fill and state colours follow the dark palette. | As light. The panel vs window contrast is low, as chosen in slice 1 (placeholder). |
| `mac-needs-you-light.png` | Same shell; the page sits on ground in its panel, no inspector. The picked Needs you row deepens to `#fbd9b4`. | Page content (title, cards) is slice 6. |
| `mac-needs-you-dark.png` | As light. | As light. |

Also checked live: the sidebar toggle (background AX press) collapses the sidebar and brings it back. With the
sidebar hidden, the chat panel takes the width and the traffic lights sit on it. Sidebar rows are now AX buttons
labelled with name, state and count, and the picked row carries the selected trait. AX press on Needs you
switched the detail.
