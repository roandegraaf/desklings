# Acceptance checks

The end-to-end checks that automation cannot run, written for the native app (the only client).
`infra/smoke.sh`, `infra/desktop/check.sh` and the daemon's unit tests cover everything else
against the scripted endpoint in `infra/provider-stub.py`. What follows needs something the tree
does not have: a paid search token, a real MCP server, a real model endpoint, a physical iPhone,
an authenticator app or the Unraid box.

These replace the browser-based `hermes-parity` acceptance list
(`docs/slides/_archive/hermes-parity/ACCEPTANCE.md`), which predates the app.

## 0. A stack built from this tree

Rebuilding recreates the agents' Linux users from the database rows. Homes (`/home`), sandbox
layers (`/var/lib/schermes-sandboxes`) and the database (`/var/lib/schermes`) are named volumes and
survive it.

- [ ] `docker compose up -d --build`, then claim a fresh daemon in the app: its setup screen asks
      for a password and the code from `docker compose logs schermes | grep 'first-run setup token'`.
- [ ] In **Settings ▸ Models**, add a provider and a model. **Test** on the model row answers.
      Working looks like: an agent created afterwards interviews you in its thread.

## 1. A real model endpoint

No real OpenAI-compatible endpoint has answered yet; every turn so far came from the stub. See
[configuration § Endpoint notes](configuration.md#endpoint-notes) for vLLM and Ollama.

- [ ] Point the default model at a real endpoint with tool calling (OpenRouter, a vision model).
      Ask an agent to "take a screenshot and tell me what is on your desktop".
      Working looks like: the chat shows a screenshot step and a reply that matches the desktop.
- [ ] Repeat with a Gemini model through OpenRouter and with DeepSeek (thought signatures and
      `reasoning_content` echo). A 400 about a missing signature or reasoning field is a finding.
- [ ] Set **Context window** on a small local model (Ollama with `num_ctx` raised) and run a long
      turn. Working looks like: a compaction notice in the thread, never a hard failure.

## 2. Live web search and fetch (needs a Brave Search token)

Covered against a stubbed endpoint in `daemon/src/web.test.ts`. Untested: Brave answering.

- [ ] In **Settings ▸ Web search**, paste the token into **Search key** and leave **Endpoint**
      empty. Working looks like: after saving, the field's placeholder reads "Stored".
- [ ] Ask a permanent agent: "Search the web for the current Node.js LTS version and give me the
      top three result titles with their URLs." Working looks like: a `web_search` step in the
      chat and real URLs in the reply.
- [ ] Then: "Fetch the first of those URLs and summarise it in two sentences." Working looks
      like: a `web_fetch` step and a summary matching the page. A refusal saying the page was
      unreachable or blocked is a finding.

## 3. A real MCP server round trip

The protocol is covered in `daemon/src/mcp.test.ts` against the SDK's own server. Untested: a
server that starts inside an agent's sandbox and answers.

- [ ] In **Settings ▸ Plugins**, **Add server**: name `fs`, command `npx`, arguments
      `-y`, `@modelcontextprotocol/server-filesystem`, `/tmp` (one per line). The first run pulls
      the package from npm inside the agent's sandbox.
- [ ] With **Test as** on a permanent agent, press **Test** on the row. Working looks like: the
      row lists the server's tools (`read_file`, `list_directory`, …). Note an error verbatim.
- [ ] With two or more agents, pick the second in **Test as** and test again. Working looks like:
      the server ran as that agent (a command that writes into `$HOME` lands in that agent's home).
- [ ] Ask the agent: "Use your fs tools to list /tmp." Working looks like: an
      `mcp__fs__list_directory` step and a reply naming real entries.

## 4. Real devices and accounts

- [ ] **Push cold launch.** With the app force-quit on a real iPhone, let an agent finish a turn.
      Tapping the push opens that agent's thread.
- [ ] **Large share.** Share a ~25 MB file to schermes from another app on a real iPhone. It
      arrives whole in the agent's `~/uploads`, and the thread says so.
- [ ] **TOTP.** In **Settings ▸ Account**, enrol a second factor with a real authenticator app,
      log out and back in with a code, then once with a recovery code. Sharing and notification
      actions keep working with TOTP on.

## 5. The Unraid server

- [ ] Deploy per [deployment § Unraid](deployment.md#unraid), with `--device=/dev/fuse
      --device=/dev/net/tun`. Run `infra/smoke.sh` and
      `docker exec schermes /opt/schermes/infra/desktop/check.sh`; both exit 0. If a sandbox will
      not start, check user namespaces and xattrs on the volume first
      ([architecture § Unraid](architecture.md#unraid-to-verify-user-gated)).
