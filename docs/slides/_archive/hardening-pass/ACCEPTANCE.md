# Acceptance — hardening-pass

The code is done and the automated gates pass (pnpm check, pnpm test with 482 daemon tests, smoke.sh,
check.sh, and the xcodebuild macOS and iOS test suites). These items need a human, real hardware or a paid endpoint.

## User-gated Definition of Done items

- [ ] **Sandbox on Unraid.** On the server: `docker compose up -d --build`, then `infra/smoke.sh`, then
  `docker compose exec schermes /opt/schermes/infra/desktop/check.sh`. Passing means both exit 0.
  The compose file needs `devices: /dev/fuse, /dev/net/tun` and that is the part most likely to differ
  from Docker Desktop. If either check fails, look first at `newuidmap` setcap, fuse-overlayfs and pasta in the logs.
- [ ] **A real OpenAI-compatible endpoint, with a tool call and a screenshot.** Add the model in the app
  (Settings ▸ Models), then send an agent "take a screenshot, then run `uname -a`, then tell me both".
  Passing means the reply contains both results, and `docker compose logs -f schermes | grep -i "provider returned"`
  shows no 400. Cost is a few cents.
- [ ] **A second provider family completing a multi-step tool turn.** Use the same prompt and send two turns
  in one thread. Pick one:
  - Gemini through OpenRouter (`https://openrouter.ai/api/v1`; check the exact model id on openrouter.ai/models);
  - DeepSeek (`https://api.deepseek.com`, `extraBody` `{"thinking":{"type":"enabled"}}`);
  - a local vLLM or Ollama model set up as in `docs/configuration.md` (Ollama needs `OLLAMA_CONTEXT_LENGTH=32768`
    and `contextWindow: 32768` on the model).
- [ ] **Push cold launch on a real iPhone.** Force-quit the app, get an agent to message you, and tap the
  notification. Passing means the app opens on that agent's chat.
- [ ] **A ~25 MB share from the share extension on a real iPhone.** Share a file of about 25 MB to Schermes from
  Files or Photos. Passing means it shows up in the agent's thread and the extension isn't killed for memory.
- [ ] **TOTP with a real authenticator app.** Go to Settings ▸ Account ▸ Two-factor sign-in, enter your password,
  scan the QR code, enter a code and save the recovery codes. Then sign out and back in with an authenticator
  code, and once with a recovery code (it works only once).

## Runtime-unverified (seen only in tests, never on screen or live)

- [ ] On a real agent desktop, ⌘V pastes the Mac clipboard and ⌘C copies back. Watch for the macOS 26
  pasteboard-privacy prompt the first time the app reads the clipboard during a key press.
- [ ] iOS: the `PasteButton` in the desktop's glass bar, and ⌘V from a hardware keyboard.
- [ ] Kill the daemon while the app is open. The offline banner should show in the Mac detail column, on the
  iPad and in the menu bar panel. Tap "Retry now" after restarting the daemon and it should clear.
- [ ] Polling slows down when the Mac window is covered (watch the daemon's request log).
- [ ] Chat: scroll to the top of a long thread with the daemon down, and the "Couldn't load older messages /
  Retry" row should appear.
- [ ] Settings ▸ Account layout (Mac at 760 pt and iOS), the QR legibility, and the number fields on a real
  keyboard and on the number pad.
- [ ] The cleartext-HTTP warning shows on connect, on sign-in and in Settings when the server URL is `http://`.
- [ ] The "screenshot expired" placeholder in a chat once retention has pruned an image.
- [ ] On a phone that already has the old Keychain item, the session survives the move to `ThisDeviceOnly`.
- [ ] The share extension's shared cookie store on a real device (simulators have no app group).
- [ ] An app-side VNC view of a sandboxed agent desktop.

## Owner calls (decisions, not checks)

- [ ] TigerVNC `SendPrimary` is probably on, so selecting text on the agent may overwrite your Mac clipboard
  while the desktop is held. Adding `-SendPrimary=0` to `infra/desktop/start-desktop.sh` would stop that.
- [ ] `daemon/src/goals.ts:249` deletes a temporary helper's agent row even when its Linux user couldn't be
  removed. Decide whether to keep the row for a retry.
- [ ] The placeholder copy and the tuning numbers are listed under `Placeholder choices:` in each `PROGRESS.md` slice entry.
  Examples are the login backoff (5 free, 1 s base, 5-minute cap), the compaction reserves and the banner wording.
