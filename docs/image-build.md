# Building the image

`infra/packer/schermes.pkr.hcl` turns this repository into a qcow2 you can import as an Unraid
VM, or run on any QEMU/KVM host.

## What has actually been run

Be clear about this before you rely on it. On the development Mac this template was written on,
`packer init`, `packer fmt -check` and `packer validate` all pass, and the `git archive` step
that assembles the source tarball was run and its output inspected. **`packer build` has never
been executed.** It cannot be: it needs QEMU and `/dev/kvm`, which means a Linux host, and macOS
is neither. Nothing below the "Build it" heading has been observed working end to end.

The pieces it is assembled from are not new, which is the reason for the confidence that
remains. `infra/install.sh` is the same script the Docker harness runs on every build, and it
has been run twice in a row inside a Debian 13 container with the sources present, exiting 0
both times. What Packer adds is getting Debian booted, the
repository onto the disk, and the machine cleaned up afterwards.

## Prerequisites

A Linux host with:

- Packer 1.11 or newer, and `packer init infra/packer/` run once to fetch the QEMU plugin
- QEMU (`qemu-system-x86_64`, `qemu-img`) and read/write access to `/dev/kvm`
- `xorriso` or `genisoimage`, which Packer shells out to for the cloud-init seed CD
- `git`, because the source tarball comes from `git archive`
- Roughly 25 GB free, and outbound access to `cloud.debian.org` and `deb.debian.org`

Without `/dev/kvm` you can pass `-var accelerator=tcg` and the build will run in software
emulation. An apt cycle and a Chromium install under TCG is measured in hours, not minutes.

## Build it

```sh
packer init infra/packer/
packer validate infra/packer/
packer build infra/packer/
```

The image lands at `infra/packer/build/output/schermes.qcow2`. Packer refuses to start when the
output directory already exists, so remove it between builds.

Useful variables, all with defaults:

| Variable           | Default                                | Why you would change it                        |
| ------------------ | -------------------------------------- | ---------------------------------------------- |
| `repo_ref`         | `HEAD`                                 | Cut an image from a tag rather than your branch |
| `disk_size`        | `20G`                                  | More room for agent Chromium profiles           |
| `accelerator`      | `kvm`                                  | `tcg` on a host with no KVM                     |
| `console_password` | empty                                  | Keep a console login for recovery               |
| `output_directory` | `infra/packer/build/output`            | Write the artifact somewhere else               |
| `source_image_url` | Debian 13 generic cloud, amd64         | Pin a specific Debian point release             |

**Only committed files reach the image.** The source tarball comes from `git archive`, which is
what keeps `node_modules` and any local database out of it — the `file` provisioner
has no ignore list and a plain directory upload would send all of them over SSH. The cost is
that uncommitted work is invisible. A guard in the first provisioner checks the tarball contains
`daemon/package.json` and stops the build in seconds if the ref you chose does not, rather than
failing fifteen minutes later inside pnpm.

## How it works

The source is Debian's own generic-cloud qcow2, not an installer ISO. It is already a qcow2,
already minimal, and boots into cloud-init — which is what lets the build get an SSH login
without a long `boot_command` typing at a preseed installer.

1. `git archive` writes the source tarball on the build host.
2. QEMU boots the Debian image with a `cidata` CD attached. The seed sets the hostname and gives
   the `debian` user a password generated fresh for this build, used once over loopback SSH.
   cloud-init also grows the root filesystem into `disk_size` here.
3. The tarball is uploaded and extracted to `/opt/schermes`. That path is not a preference: the
   sudoers rule `install.sh` writes names `/opt/schermes/infra/desktop/create-agent-user.sh`
   literally, and `config.ts` resolves the desktop scripts relative to the daemon's own source
   path.
4. `infra/install.sh` runs, exactly as it does in the Dockerfile and on a VPS. It installs
   packages, Node 24, pnpm, uv, the users and sudoers rules, the systemd unit and the daemon's
   dependencies.
5. A cleanup pass revokes everything the build knew: the SSH key and password, cloud-init's
   password-authentication drop-in, the seed state, the SSH host keys, the machine id, the apt
   lists and the logs.

cloud-init stays installed on purpose, and here the reasoning outruns the evidence — flagged,
because the rest of this page is careful about that. Unraid gives a VM no metadata service, so
cloud-init should find no datasource and create nothing, while still doing two things worth
keeping: growing the root filesystem into whatever disk the operator gave the VM, and
regenerating the SSH host keys the build deletes. **Neither has been observed.** Both are the
documented behaviour of cloud-init's `growpart` and `ssh` modules under a `None` datasource, not
something this project has watched happen, and neither can be settled in the Docker harness,
because `install.sh` installs `openssh-client` and not the server. Treat them as expectations to
confirm on the first real VM.

The caveat runs the other way too: boot this image somewhere that *does* have a metadata service
and cloud-init will apply it.

Deleting the host keys is the safe direction to be wrong in. If regeneration turns out not to
happen, sshd refuses to start and the machine has no SSH, which is survivable — schermes does
not use SSH, and the alternative is every VM from this image sharing one host key. If you do
want SSH and it did not happen, `ssh-keygen -A` from the console fixes it in one command.

## First boot

The image ships claimed by nobody. There is no owner password, no provider settings, and no
interactive login unless you built with `console_password`.

1. Import the qcow2 as an Unraid VM, give it a bridged NIC, boot it.
2. It takes a DHCP lease and systemd starts `schermes.service` on port 7777.
3. Open `http://<vm-ip>:7777`. The UI is a first-run gate: set the owner password.
4. Open settings and store the provider base URL, model and API key.
5. Create an agent.

Step 3 is the security boundary and it is worth being plain about. The daemon binds `0.0.0.0`
because a VM is reached from another machine, so between boot and step 3 **whoever reaches the
port first becomes the owner**. The window is closed rather than guarded: setup succeeds exactly
once and every later attempt is refused, which `infra/smoke.sh` asserts. Boot the VM on a
network you trust and claim it promptly. See the [security model](architecture.md#security-model).

There is no console login by default: the build user's password is locked and its authorized
keys are gone. If you want a recovery account on a VM that might never appear on the network,
build with `-var console_password=...`, which sets a password on the `debian` user. It does not
re-enable SSH password authentication.
