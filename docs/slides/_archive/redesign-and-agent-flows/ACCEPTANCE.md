# Acceptance: redesign and agent flows

Every automatable Definition of Done item is verified in code. `pnpm check` and `pnpm test` pass (306 passed, 0 failed). What is left needs the owner, a device, or a real server.

## 1. User-gated Definition of Done items

- [ ] **Design matches the canvas, on both platforms, light and dark.**
  1. Build and run on the Mac: `xcodebuild -scheme Schermes -destination 'platform=macOS' build`, then open the app. Also build and run on an iPhone.
  2. Switch the system appearance between Light and Dark.
  3. Compare these screens against the redesign canvas: sidebar, chat, Needs you, goal page, agent settings (Rules, When idle, Routines and triggers), and the iPhone Agents home.
  4. Working: surfaces are warm, not system grey. The chat background is the agent's tint, the owner's bubble is flat, and titles are in SF Rounded. The Mac sidebar staying on system glass is deliberate.
- [ ] **Live Activity on a device, including the Dynamic Island.**
  1. The first device build registers the capabilities: `xcodebuild -scheme Schermes -destination 'generic/platform=iOS' -allowProvisioningUpdates build`. Install it on an iPhone with a Dynamic Island.
  2. The daemon needs an APNs key: set `SCHERMES_APNS_KEY_FILE` (and `SCHERMES_APNS_KEY_ID` when the file is not named `AuthKey_<KEYID>.p8`), then restart it.
  3. Sign in on the phone, lock it, and give a permanent agent a multi-step goal from the Mac.
  4. Working:
     - An activity starts without opening the app, through push-to-start.
     - It shows the agent, the goal or turn title, steps "n/m", and the state.
     - It updates as `update_goal` steps complete, and shows "Needs you" when an approval arrives.
     - It ends about 15 minutes after the turn.
     - The Island's compact and expanded views both render.
- [ ] **Share extension on a device.**
  1. Use the same `-allowProvisioningUpdates` device build, since the App Group `group.dev.schermes` only exists on device builds. Sign in inside the app first.
  2. Share each of these to "Schermes": a Safari link, a Notes text, a Files document and a Photos image. Pick an agent or a goal and type an instruction.
  3. Working:
     - The agent gets a message with the instruction and the link or quoted text.
     - Files land in the agent's `~/uploads`, and the message names the path.
     - A goal target goes to its lead and mentions the goal.
     - Signing out of the app makes the extension say "Open Schermes and sign in first."
- [ ] **A live IMAP mailbox triggers an agent.**
  1. Ask an agent to watch a mailbox and accept its `propose_trigger` card.
  2. Choose "Enter login…" and type a real IMAP login (use an app password where the provider needs one).
  3. Turn the trigger on and send the mailbox a mail.
  4. Working:
     - Within the check interval (5 min by default), a "Trigger N fired" row with sender, subject and date appears, and the agent takes a turn.
     - A wrong password brings the login item back into Needs you with the server's refusal.
     - The login never shows up in the transcript.
- [ ] **End-to-end run on the owner's server with a real model endpoint.**
  1. Deploy this build and put a real model in Settings ▸ Models as the default.
  2. **Form flow:** have an agent hit a login page. It should call `request_form`. Fill it from Needs you on the phone. Working: the fields are filled, and the password never appears in the chat or the model requests.
  3. **Payment approval from the lock screen:** have an agent reach a spend step (spend money is Ask first). Working: a push with Approve / Don't arrives, and answering from the lock screen resolves it without opening the app.
  4. **Overnight trigger and digest:** leave a trigger on and idle work enabled overnight. Working: in the morning, "Last night" on Needs you lists the fired turn and each idle output. Agents whose pre-check found nothing show "didn't run, 0 tokens".

## 2. Pre-merge check

- [ ] Re-run `xcodebuild test -scheme Schermes -destination 'platform=macOS'`. It was last green in slice 33 (204 tests). Slice 35 ran only the iOS suite (203) and a macOS build. Run the iPhone 17 simulator suite once more too if Swift files changed since.

## 3. Runtime-unverified items

### Look
- [ ] Mac chat header: the context meter shows a percentage next to the inspector button. Compare it with the iPhone More ring on the same agent.
- [ ] Group thread: the group pill and group rows show each member's name beside their bloub.
- [ ] iPad: the sidebar, chat, Needs you, goal page and sheets lay out like the Mac, with no clipped rows.
- [ ] Dark mode on the iPhone: the Needs you strip and page, the idle pages and the trigger cards are readable, with no grey slabs.

### Needs you and approvals
- [ ] Mac sidebar: the "Needs you" row shows the same count as `GET /api/needs-you`, and the wide page shows "Right now" with the busy agents.
- [ ] An `action` approval card shows Approve / Don't. "Always allow" appears only for an origin or recipient approval, and pressing it adds to the pre-approved list.
- [ ] Retry on a failure item starts a new turn and removes the item.
- [ ] Answering an agent's question in the chat removes its item on the other device within one poll.

### Push
- [ ] A real APNs push arrives for approvals, deletes (Keep it / Delete it), passwords (I'll do it / Don't) and hand-overs (Watch).
- [ ] Approve from the lock screen with the app killed. The item resolves, and an unreachable daemon posts "Your answer did not reach the daemon".

### Live Activity
- [ ] Covered by user-gated item 2. Also check that an update token registered after a turn ended gets an immediate end.

### Menu bar (macOS)
- [ ] Clicking the bell shows the panel with the Needs you count. ⌥Space opens it from any app.
- [ ] The quick field takes focus while another app is active. "@name message" goes to that agent, and a plain message goes to the picked agent.
- [ ] Approve / Don't answer in place. Open brings back a closed console window on that agent.
- [ ] "Working now" lists busy agents.

### Share
- [ ] iOS share sheet: covered by user-gated item 3.
- [ ] macOS Service: in Safari or Finder, use Services ▸ "Send to Schermes…". A relaunch or `/System/Library/CoreServices/pbs -update` may be needed first. The Send to window opens and the item reaches the agent.

### Recovery
- [ ] Browser watchdog: on the Debian image, freeze Chromium (`kill -STOP` its pid). It is restarted once on its own. A second hang shows the chat card and a Needs you item with Restart browser, Restart desktop and retry, and Look at the screen. Each button works and the item clears.
- [ ] Mac: the retry card counts attempts and offers Retry now and Use backup model. The key-refused card opens Settings on the Models tab.

### Hand-over
- [ ] Mac: the chat card's "Take the screen" opens the desktop window, and "Give it back" in the toolbar posts a line and resumes the agent.
- [ ] iPhone: "Take the screen" from the Needs you card behaves the same.
- [ ] This works against a real Xvnc desktop, not just the test bed.

### Forms
- [ ] On a real Chromium on Xvnc, fill a form, including a React-controlled input. The values stick and nothing is submitted.
- [ ] A page with a cross-origin iframe (for example an embedded payment field) lists that field under "Use the agent's screen".
- [ ] One-time codes: check whether a code typed on the screen appears in later screenshots. The redaction covers only tool text.
- [ ] Mac form sheet: fields, lock icon, "Saved for this site" and the Remember toggle. On a device, password-manager autofill offers the username, password and one-time code.
- [ ] The in-memory secret-redaction list is now keyed by agent id. It was keyed by name, so renaming an agent dropped it; this is fixed in `forms.ts`, `app.ts` and `loop.ts`. To verify: fill a form, rename the agent, and check that the typed secret is still hidden in its tool rows. The list still resets when the daemon restarts (a known, accepted ceiling).

### Teach a skill
- [ ] On the server image (scrot and ImageMagick present), "Show how" produces screenshots and a contact sheet in `~/recordings/<stamp>/`.
- [ ] A real password field is recorded as a secret with no screenshot.
- [ ] With a real model, the agent writes a `SKILL.md` and offers a routine.
- [ ] Mac toolbar: Show how, the Secret toggle and "Stop and hand over".

### Feedback
- [ ] Mac: the hover thumbs and the "Bad reply" sheet work. The reason appears under `## Feedback` in the agent's `MEMORY.md`.

### Idle work
- [ ] An idle note row ("Idle work · time") and the idle turn render quietly in the owner's chat.
- [ ] The hour pickers and the model picker in "When idle" save, and "Agent's own" clears the model.
- [ ] Mac: the context menu "When idle…" opens the page.

### Triggers
- [ ] A check-command trigger runs under real `sudo`/`timeout` on Linux and fires only when the output changes.
- [ ] The Mac inspector lists triggers under "Routines and triggers".
- [ ] The webhook URL and secret copy buttons put the right text on the clipboard. Delete on the card works.
- [ ] The folder and command "Test it" texts read right. The cards work in dark mode.

### Goals
- [ ] A worker helper gets its own second Xvnc on the lead's user and it stops when the goal finishes. A temporary helper gets a real Linux user that is removed afterwards.
- [ ] Mac: the sidebar Goals section with rings, the goal page, and the inspector's goal section. The iPad layout too.
- [ ] Finish or Delete while a temporary helper is running shows the daemon's refusal in place.

### Search
- [ ] Mac ⌘K: opening a message hit scrolls to it, and opening a file hit shows Quick Look.
- [ ] With a real model, a question shows "understood as" chips (kind, agent, dates) instead of "Plain text search".

### Restore, forward, new agent
- [ ] The Restore / Retry sheet on Mac and iPad, with a real file list and the can't-undo box (after a mail send or a filled form). "Put the files back too" restores the files.
- [ ] "Send to…" on a file card and in the Mac hover actions opens the sheet. The file reaches the target's `~/uploads`.
- [ ] New agent from a description with a real model fills the name, label, look, rules and routine. The same sheet works on Mac and iPad.

## 4. Placeholder choices to review

- [ ] **Theme dark values:** secondary `#cfcbd6`, needsYou `#f5a55a`, failed `#ff8a80`, retrying `#e8c35a`, done `#5fd39a`.
- [ ] **State words and icons:**
  - Idle, Thinking, Using the computer, Using the terminal, Ready (`waiting_for_user`), Waiting for …, Failed, Done.
  - Done is green, while the canvas shows it muted.
- [ ] **Tagline:** it comes from the profile's first line of prose.
- [ ] **Context meter:** a plain `ellipsis` in the iPhone ring; the Mac meter has no capsule; the ring track is ink at 12%.
- [ ] **Category words:** browse, run a command, write files, delete files, send a message, spend money, install software, share something outside, change a password or security setting.
- [ ] **Needs you copy:**
  - Titles "Asks to …" and "Could not finish its turn".
  - Strip "N things need you"; the page subtitle; the Last night empty state.
  - Card colours `#ffffff` / `#232127`, strip `#fbd9b4` / `#4a2c10`.
  - No elapsed time on "Right now" rows.
- [ ] **Rule defaults:**
  - On its own: browse, run commands, write files.
  - If pre-approved: send messages.
  - Ask first: delete, spend, install, share outside.
  - Hand to you: passwords.
  - Write files and share outside are guesses; the canvas does not show them.
- [ ] **Rules page:** the row hints, the footers, the `checkmark.shield` icon, the pre-approved prompt "flytap.com or someone@example.com".
- [ ] **Model recovery copy:** "<model> is busy. Trying again in N s, attempt X of 5". "<model> refused its key" reads oddly for a model named "Refused".
- [ ] **Browser watchdog:** its copy, and the 5 s probe.
- [ ] **Hand-over:** "<Agent> asks you to take the screen", "Take the screen" / "Give it back", a 400-character reason cap.
- [ ] **Forms:**
  - Daemon copy: the filled line "… Password (hidden). Nothing was submitted", `[hidden]` as the redaction mark.
  - Limits: 50 fields, 2,000 characters per value.
  - Sheet copy: "Fill in…", "Use the agent's screen", "Saved for this site", " *" as the required mark.
- [ ] **Feedback:** "Good reply" / "Bad reply", "What was wrong with it?", the memory line format with a 120-character excerpt.
- [ ] **Idle defaults:** off, all four conditions, 200,000 tokens a day, 20 turns, 01:00–06:00.
  - Hours are daemon-local time, so likely UTC in a container.
  - Files count as stale after 30 days; the memory threshold is 8,000 bytes.
- [ ] **Idle copy:**
  - The note wording, a 2,000-character note cap, and the back-off reason "The owner dismissed 3 notes in a row."
  - The digest labels ("Tidied its memory", "Suggests a routine", "Noticed something", "Proposes a cleanup").
  - The `moon.zzz` icon; memory diffs show 8 lines.
- [ ] **Trigger defaults:** 6 fires an hour, a check every 5 min, 30 s check timeout, 64 KB webhook body, 4,000-character excerpt, 50 files listed.
- [ ] **IMAP defaults:** port 993, INBOX, 20 messages, 300 characters per header, the title "Needs the login for <mailbox> on <host>".
- [ ] **Trigger app copy:** "Trigger · <kind>", "Enter login…", "Test it: …", "Waiting for it to fire…". Icons `bolt` and `bolt.badge.clock`. The header is needsYou while proposed and done when on.
- [ ] **Goal limits:** 10 open goals per lead, 30 steps, 50 results, 10 next items, 6 helpers per goal. Also the `describeGoal` layout and "Next from you: <title>".
- [ ] **Goal app:**
  - Copy: "Goal · led by X", "Plan · n of m", "Helper with its own screen" / "Temporary agent".
  - Step icons; blocked uses needsYou; dashes are 4/3 at 1.5 pt.
- [ ] **Search:** chips on 14% retrying amber, the kind symbols, "Nothing found.", the iPhone prompt "Search or ask".
- [ ] **Snapshots and restore copy:**
  - Snapshots are stored in `~/.schermes-snapshots`.
  - The restore line wording and the can't-undo texts.
  - "Files put back" with `arrow.uturn.backward`.
  - The list is capped at 6 with "and N more"; the red fill is 0.12.
- [ ] **Forward:** "Send to…" with `arrowshape.turn.up.right`, "Forwarding this to you.", "Forwarded from something I wrote earlier", "There is no other agent to send this to."
- [ ] **New agent:**
  - The fallback label "Helper" and "What should it help you with?".
  - The rules summary line and "First routine" / "Leave out".
  - The footer about the desktop starting in the background; the button "Create <Name>".
- [ ] **Push buttons:** Approve/Don't, Keep it/Delete it, I'll do it/Don't, Watch, Open.
- [ ] **Live Activity:** dismissal 15 min after the turn, 5 s throttle, the start alert "Started working.".
  - "Needs you" is system orange, because the extension has no `Theme`.
  - The lock screen background is black at 55%.
- [ ] **Menu bar:**
  - Icons `bell` / `bell.badge.fill`; the panel is 380 pt wide with a list up to 480 pt.
  - Prompt "Message, or @name message", and the "Nothing is waiting on you." / "Nothing is running." states.
- [ ] **Share:**
  - Title "Send to Schermes"; default instruction "Have a look at this."; fallback file name "shared".
  - The picker has no bloub, and errors are plain red: the extension compiles neither.
- [ ] **Teach a skill:**
  - Copy: "Show how", "Secret", "Stop and hand over", the sidebar "Showed how it's done".
  - Limits: 12 shots, 200 steps, 30 min, a 700 ms shot delay.
