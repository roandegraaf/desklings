# schermes

A single self-hosted Linux machine that runs persistent AI agents. Each agent gets its own
Linux user, X display, browser and terminal, and you drive and watch all of them from one web
UI. Point it at any OpenAI-compatible model endpoint and the agents work.

MIT licensed. One repository. No Kubernetes, no container per agent, no cloud account.

## Status

Early. The desktop foundation works: `install.sh` provisions a Debian 13 host, and several
agents run concurrent Xvnc desktops with their own Chromium profiles, controllable through
xdotool and observable through scrot. The daemon, HTTP API and UI are not built yet.

## Try the dev harness

Requires Docker. The container is a real Debian 13 host provisioned by the same
`infra/install.sh` that a VM or VPS would run.

```sh
docker compose build
docker compose up -d
docker compose exec schermes /opt/schermes/infra/desktop/check.sh
```

The check creates three agents, gives each a desktop and a Chromium profile, types a URL into
each browser, captures a screenshot per desktop, verifies a cookie survives a Chromium
restart, and verifies nothing listens outside loopback. It is safe to run repeatedly.

## Layout

```
infra/install.sh                     idempotent Debian 13 provisioning
infra/desktop/create-agent-user.sh   create agent-<name>, home, workspace, uploads, profile
infra/desktop/start-desktop.sh       spawn or adopt an agent's Xvnc display and window manager
infra/desktop/check.sh               runnable check for the whole desktop foundation
docs/architecture.md                 decisions, with requirement / recommendation / deferred tags
```

## Deploying to a real machine

Install Debian 13, copy this repository to `/opt/schermes`, and run `infra/install.sh` as
root. The script is idempotent, so re-running it after an update is the upgrade path.
