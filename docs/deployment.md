# Deployment

Two supported paths onto real hardware. Both end with the same machine, because both run
`infra/install.sh` and that script is the only provisioning path there is.

- **Unraid, or any QEMU/KVM host** — import the qcow2 the Packer template builds. See
  [building the image](image-build.md).
- **A VPS or any Debian 13 box** — install Debian, copy the repository, run the script.

For local development on macOS, use the Docker harness instead: [development](development.md).

## VPS or bare Debian 13

```sh
git clone <this repository> /opt/schermes
/opt/schermes/infra/install.sh          # as root
systemctl start schermes
```

`/opt/schermes` is not a preference. The sudoers rule the script writes names
`/opt/schermes/infra/desktop/create-agent-user.sh` literally, and the daemon resolves the
desktop scripts and the built UI relative to its own source path. Install it somewhere else and
agent creation fails at the first `sudo`.

The script needs root, an amd64 or arm64 Debian 13 ("trixie"), and outbound access to Debian's
mirrors, `nodejs.org` and `astral.sh`. It installs the desktop stack (TigerVNC, Openbox, tint2,
PCManFM, LXTerminal, Chromium, xdotool, scrot, xclip), Node 24, pnpm, uv, the `schermes` service
user and the `agents` group, two sudoers rules, the systemd unit, the daemon's dependencies, and
the UI build. Expect several minutes and a few GB, most of it Chromium.

Then confirm it:

```sh
systemctl status schermes
SCHERMES_URL=http://127.0.0.1:7777 /opt/schermes/infra/smoke.sh
/opt/schermes/infra/desktop/check.sh
```

Open `http://<host>:7777`, set the owner password, store the provider settings, create an agent.

## Upgrading

Re-running the script is the upgrade path. It is idempotent by design: every step checks before
it acts, so a second run installs nothing it already installed and re-runs only the parts that
are cheap.

```sh
git -C /opt/schermes pull
/opt/schermes/infra/install.sh
systemctl restart schermes
```

Migrations are committed under `daemon/migrations/` and applied on boot, so there is no separate
migration step. The daemon runs from TypeScript source — Node 24 strips the types on load — so
there is no build step for it either. The UI does have one, and `install.sh` runs it.

A restart is safe by construction. Desktops are spawned detached with `setsid` and are adopted
rather than respawned by the daemon that comes back; an agent caught mid tool call has that call
marked interrupted and answered, and is left waiting for you rather than resuming on its own.

## What to back up

`/var/lib/schermes` — the whole directory, and both of the things in it matter:

- `schermes.db` — owner, sessions, settings, agents, conversations, messages, events.
- `master.key` — 0600, owned by `schermes`. Without it the encrypted API key in the database
  cannot be decrypted. Backing up the database alone is not a backup.

Agent home directories under `/home/agent-*` are deliberately outside it. They hold workspaces,
uploads and Chromium profiles. Back them up if the work in them matters; a restore without them
rebuilds the Linux users and desktops from the surviving agent rows, with empty homes.

`/srv/schermes/shared` is the group-writable cross-agent directory and is not in either.

## TLS

schermes speaks plain HTTP on one port and will not grow TLS. Put a reverse proxy in front of
it. The proxy has to forward WebSocket upgrades, because the desktop stream is a WebSocket on
that same port.

```caddyfile
schermes.example.com {
	reverse_proxy 127.0.0.1:7777
}
```

Caddy forwards upgrades without being asked. With nginx, set `Upgrade` and `Connection` headers
on the location, and raise `proxy_read_timeout` — an idle desktop stream is a long-lived socket.

Once a proxy terminates TLS, bind the daemon away from the world. It listens on `0.0.0.0`, so
use a firewall rule, or run it on a host whose only open port is the proxy's.

## Exposure

One port is exposed and everything else is loopback. Per-agent VNC servers bind `127.0.0.1` on
`5900 + display` and are reachable only through the daemon's proxy, which checks the session
cookie and the input-ownership state before it pipes a byte.

`infra/desktop/check.sh` asserts this: it enumerates every listening socket and fails if
anything but the web port is bound outside loopback. Run it after any change to the stack.

Do not put schermes on the public internet without a proxy that authenticates in front of it.
Agents have passwordless sudo on this machine — that is the product, not an oversight — so the
owner password is the only thing between a visitor and root. See the
[security model](architecture.md#security-model).
