# hermes-parity — acceptance checklist

The task is code-complete: every automation-verifiable line of the Definition of Done is met,
`pnpm -r check` and `pnpm -r test` are green (daemon 171, ui 11) and `infra/smoke.sh` passed
end to end against a throwaway stack built from this tree. What follows needs something nobody
in the tree has: a paid search token, a real MCP server, and a decision about the running
dev stack.

## 0. Rebuild the dev stack (a decision, then one command)

The stack on port 7777 still serves the bundle from before slice 6, so none of the new panels
are visible there yet. Rebuilding it recreates the agent Linux users from the surviving
database rows, and their home directories go with them: memory (`~/memory/`), skills
(`~/skills/`) and anything else on disk. The database (agents, conversations, messages,
settings, schedules) lives on the `schermes-data` volume and survives.

- [ ] Decide whether the current agents' homes are worth keeping. If so, copy them out first
      (`docker compose cp schermes:/home/agent-<name> ./backup-<name>` per agent).
- [ ] Rebuild:
      ```sh
      docker compose up -d --build
      ```
- [ ] Open `http://127.0.0.1:7777`. Working looks like: the **settings** view shows a
      **Search endpoint** and **Search key** field under the provider settings and an
      **MCP servers** panel below it; an agent's pane has a third **schedules** tab beside
      chat and desktop.

## 1. Live web search and fetch (needs a Brave Search subscription token)

Covered against a stubbed endpoint in `daemon/src/web.test.ts` (parser, SSRF guard, clip,
key never leaving the daemon); the smoke asserts the loopback refusal inside the container.
Untested: Brave answering for real. Cost: Brave's free tier covers this many calls.

- [ ] Get a token from the Brave Search API dashboard.
- [ ] In **settings → Search key**, paste the token and save. Working looks like: the field
      empties and shows "stored — type to replace it". Leave **Search endpoint** blank
      (the built-in Brave URL is used).
- [ ] Ask any permanent agent, in its owner thread: "Search the web for the current Node.js
      LTS version and tell me the top three result titles with their URLs." Working looks
      like: the reply lists titled results with real URLs, and the desktop tab's activity shows
      a `tool_call` for `web_search` followed by a `tool_result`.
- [ ] Then: "Fetch the first of those URLs and summarise the page in two sentences." Working
      looks like: a `web_fetch` call and a summary that matches the page. A refusal saying the
      page was unreachable or blocked is a finding, not a pass.

## 2. A real MCP server round trip (needs one server)

The protocol is covered in `daemon/src/mcp.test.ts` against the SDK's own `Server` over an
in-memory transport (real client, real handshake, real `tools/call`). The panel's per-agent
test was driven in a browser against a stdio server that failed to start, so the spawn as the
agent's Linux user and the error path are exercised. Untested: a server that actually starts
and answers.

- [ ] In **settings → MCP servers**, paste into the JSON box and save:
      ```json
      [
        { "name": "fs", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "env": {} }
      ]
      ```
      The stdio server is spawned as the agent's Linux user inside the container, so `npx`
      must be on that user's PATH there (it is in the shipped image) and the first run pulls
      the package from npm.
- [ ] Pick a permanent agent in the **test as** select and press **test**. Working looks like:
      a line listing the server's tools (`read_file`, `list_directory`, ...). An error line is
      a finding; note it verbatim.
- [ ] Ask that agent: "Use your fs tools to list the contents of /tmp." Working looks like: a
      `tool_call` for `mcp__fs__list_directory` in the activity, a `tool_result`, and a reply
      that names real entries.
- [ ] Remember the rule the panel states: a save replaces the whole list and secrets are never
      read back, so editing the list means re-entering every `env` value and header.

## 3. One control never clicked in a browser

Slice 6 verified the **test as** select's non-default option against the daemon (a test as
`alpha` spawns as `agent-alpha`, as `beta` spawns as `agent-beta`) but never clicked it, because
the browser session wedged. What is untested is only the select's `onChange` wiring.

- [ ] With two or more permanent agents, pick the second one in **test as** and press
      **test**. Working looks like: the result line names that agent, and the spawned
      server ran as that agent's user (a stdio command that writes a file into `$HOME` is the
      quickest proof).
