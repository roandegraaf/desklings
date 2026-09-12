# Acceptance checklist — schermes-mvp

The code is complete and every automation-verifiable item on the Definition of Done was checked
against the source, the unit tests (97 daemon + 9 ui, 0 failing), `./infra/smoke.sh` and
`infra/desktop/check.sh` at completion time. What is left is what only you can run: a real model,
a real VM and a real image build. Tick each one off here.

## 1. One end-to-end run against a real OpenAI-compatible endpoint

Everything so far has hit `infra/provider-stub.py`. `openAiProvider` in `daemon/src/provider.ts`
has never seen a real response, and its 180 s timeout has never fired.

1. `docker compose up -d --build`, open `http://127.0.0.1:7777`, set the owner password.
2. Settings: base URL, model name and API key. The model must support tool calling and vision.
3. Create an agent, send it: "Open Chromium, go to example.com and tell me the page heading."
4. Watch the agent view: the live desktop should show Chromium opening; the chat should show a
   screenshot and a final answer naming "Example Domain".
5. Then: "Run `uname -a` in the terminal and paste the output." Expect a `tool` result and an
   answer quoting the kernel line.
6. Confirm the key never appears: `docker compose logs schermes | grep -c '<first 8 chars of key>'`
   must print 0, and `GET /api/settings` must show `apiKeySet: true` and no key.

Expected cost: one short run is a handful of vision calls, well under a dollar on any mainstream
endpoint. Note in PROGRESS.md which endpoint and model you used.

## 2. `install.sh` on a fresh Debian 13 VM (not Docker)

The script has only run inside a container, where systemd is not pid 1. Adoption of running
Xvnc processes under a real `systemctl restart`, the systemd unit itself, `pnpm install --prod`,
and `create-agent-user.sh` under a real sudo have never been observed.

1. Fresh Debian 13 amd64 VM, root shell, outbound network.
2. `git clone <repo> /opt/schermes && /opt/schermes/infra/install.sh` (as root). Expect exit 0.
3. Run it a second time. Expect exit 0 and no changes (idempotence).
4. `systemctl start schermes && systemctl status schermes` shows active.
5. `SCHERMES_URL=http://127.0.0.1:7777 /opt/schermes/infra/smoke.sh` exits 0.
6. `/opt/schermes/infra/desktop/check.sh` exits 0 (only `:7777` bound off loopback).
7. Create two agents in the UI, then `systemctl restart schermes`. Both desktops must still be
   there afterwards (adoption, not respawn): `pgrep -a Xvnc` before and after shows the same
   pids.

## 3. Packer template builds a qcow2

`packer build` has never been executed; `packer fmt -check` and `packer validate` pass on the
Mac. Needs a Linux host with QEMU and `/dev/kvm` (see `docs/image-build.md`).

1. **Commit first.** The build reads `git archive HEAD`; uncommitted work is invisible to it and
   a guard stops the build if `ui/package.json` is missing from the ref. As of completion, git
   HEAD is at slice 5 and slices 6 to 12 are uncommitted.
2. On the Linux host: `packer init infra/packer/ && packer validate infra/packer/ && packer build infra/packer/`.
3. Expect `infra/packer/build/output/schermes.qcow2`. Remove that directory between builds.
4. Two cloud-init behaviours the template relies on were reasoned, not observed: the seed
   ISO being honoured by Debian's generic-cloud image, and the build user's SSH key being
   accepted on first boot. If the build hangs waiting for SSH, that is where to look.

## 4. Deployed and verified on the Unraid VM

1. Import the qcow2 from step 3 as an Unraid VM with a bridged NIC, boot it.
2. Open `http://<vm-ip>:7777` promptly: until the owner password is set, whoever reaches the
   port first owns the instance (`docs/image-build.md`, First boot).
3. Set the password, store provider settings, create an agent, repeat the step 1 conversation.
4. Reboot the VM. The agent, its conversation and the settings must all be there afterwards.

## Ceilings worth knowing before you rely on it

Recorded decisions, not defects, but they shape what "Take control" means:

- `run_command` is not gated by take-control, and `DISPLAY` is exported into every command, so
  a model that shells out to `xdotool` can drive the desktop while you hold it
  (`daemon/src/loop.ts`, `docs/architecture.md` Human takeover).
- Returning control does not restart the agent's turn; your next message does.
- A worker's report that arrives while the parent's process is at the loop cap is logged and
  left for the parent's next turn or the boot repair, not delivered immediately
  (`daemon/src/loop.ts`, `start()`).
- Never run in a browser: two simultaneous noVNC viewers, session expiry, a group of three
  agents, two live workers at once.
