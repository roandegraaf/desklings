// Builds the schermes qcow2 for Unraid (or any QEMU/KVM host).
//
// The source is Debian's own generic-cloud qcow2 rather than an installer ISO: it is already a
// qcow2, already minimal, and boots straight into cloud-init, which is what lets this template
// bootstrap an SSH login without a 150-line `boot_command` typing at a preseed installer. The
// build seeds cloud-init once over a `cidata` CD, provisions with the same `infra/install.sh`
// the Docker harness and a VPS run, and then wipes the seed back out.
//
// cloud-init stays installed in the shipped image on purpose. Unraid gives a VM no metadata
// service, so it finds no datasource and creates nothing; what it still does on first boot is
// grow the root filesystem into whatever disk size the operator gave the VM, and regenerate the
// SSH host keys this build deletes.
//
// Requires Packer, QEMU and xorriso (or genisoimage) on a Linux host with /dev/kvm. See
// docs/image-build.md.

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

variable "source_image_url" {
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  description = "Debian 13 generic-cloud qcow2 to build on top of."
}

variable "source_image_checksum" {
  type = string
  // Debian republishes `latest` on every point release, so pinning a literal checksum here
  // would break the build every few weeks. Packer fetches the signed-alongside sums file and
  // picks the line matching the image filename.
  default     = "file:https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
  description = "Checksum of the source image, or a file: URL to a sums file containing it."
}

variable "repo_root" {
  type        = string
  default     = ""
  description = "Repository to install. Defaults to the checkout this template lives in."
}

variable "repo_ref" {
  type        = string
  default     = "HEAD"
  description = "Git ref to build. Only committed files reach the image."
}

variable "output_directory" {
  type        = string
  default     = ""
  description = "Where the qcow2 lands. Must not already exist. Defaults to infra/packer/build/output."
}

variable "vm_name" {
  type        = string
  default     = "schermes.qcow2"
  description = "Filename of the produced image."
}

variable "disk_size" {
  type = string
  // Chromium, the apt cycle, Node and one Chromium profile per agent. cloud-init grows the
  // root filesystem to fill this during the build, and again on first boot if the operator
  // gives the VM a larger disk.
  default     = "20G"
  description = "Virtual disk size of the produced image."
}

variable "memory" {
  type        = number
  default     = 4096
  description = "Build-time RAM in MB. Not a property of the produced image."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPUs. Not a property of the produced image."
}

variable "accelerator" {
  type        = string
  default     = "kvm"
  description = "QEMU accelerator. Use \"tcg\" on a host without /dev/kvm; expect a very slow build."
}

variable "headless" {
  type        = bool
  default     = true
  description = "Run QEMU without a display. Packer still exposes the build console over VNC on loopback."
}

variable "console_password" {
  type      = string
  default   = ""
  sensitive = true
  // Empty means the build user's password is locked and the image has no interactive login at
  // all: schermes is reachable over the network and nothing else is. Set this to keep a
  // console account for a VM that never appears on the network. It never enables SSH password
  // authentication, which this build turns back off regardless.
  description = "Password for the `debian` console account. Empty locks the account."
}

local "build_password" {
  // Used once, over the build's own loopback SSH, and revoked by the cleanup provisioner
  // before the image is written. It is never the shipped image's password.
  expression = uuidv4()
  sensitive  = true
}

locals {
  repo_root        = var.repo_root != "" ? var.repo_root : abspath("${path.root}/../..")
  build_dir        = abspath("${path.root}/build")
  output_directory = var.output_directory != "" ? var.output_directory : abspath("${path.root}/build/output")
  source_tarball   = abspath("${path.root}/build/schermes-src.tar.gz")
}

source "qemu" "schermes" {
  iso_url      = var.source_image_url
  iso_checksum = var.source_image_checksum
  // The source is a bootable image, not an installer: clone and resize it rather than booting
  // an ISO and typing at a preseed.
  disk_image = true
  // A backing file would leave the artifact depending on the Debian image still being on disk.
  use_backing_file = false

  output_directory = local.output_directory
  vm_name          = var.vm_name
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"

  accelerator = var.accelerator
  memory      = var.memory
  cpus        = var.cpus
  headless    = var.headless

  // The only datasource this image will ever see. It exists to hand Packer an SSH login;
  // everything it sets is undone before the image is written.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: schermes-build\nlocal-hostname: schermes\n"
    "user-data" = <<-EOF
      #cloud-config
      hostname: schermes
      users:
        - default
      chpasswd:
        expire: false
        users:
          - name: debian
            password: ${local.build_password}
            type: text
      ssh_pwauth: true
    EOF
  }

  ssh_username = "debian"
  ssh_password = local.build_password
  // cloud-init has to bring up the network, grow the root filesystem and write the password
  // before sshd will take this. Generous because a `tcg` build does all of that in software.
  ssh_timeout = "20m"

  shutdown_command = "sudo -n shutdown -P now"
}

build {
  sources = ["source.qemu.schermes"]

  // Runs on the build host, before anything is uploaded. `git archive` is what keeps
  // node_modules and the local database out of the image: the file provisioner has no
  // ignore list, and a plain directory upload would send every one of them over SSH.
  provisioner "shell-local" {
    inline = [
      "mkdir -p ${local.build_dir}",
      "git -C ${local.repo_root} archive --format=tar.gz --prefix=schermes/ -o ${local.source_tarball} ${var.repo_ref}",
      // Uncommitted work is invisible to `git archive`, and a ref missing the daemon
      // fails fifteen minutes later inside install.sh's pnpm install. Fail here instead.
      "tar -tzf ${local.source_tarball} | grep -qx 'schermes/daemon/package.json' || { echo 'ref ${var.repo_ref} has no daemon workspace: commit it, or pass -var repo_ref=<ref that has it>' >&2; exit 1; }",
    ]
  }

  provisioner "file" {
    source      = local.source_tarball
    destination = "/tmp/schermes-src.tar.gz"
    // The provisioner above writes it. Without this, `packer validate` fails on a clean
    // checkout because it stats the source before anything has run.
    generated = true
  }

  // `/opt/schermes` is not a preference. The sudoers rule install.sh writes names
  // /opt/schermes/infra/desktop/create-agent-user.sh literally, and config.ts resolves the
  // desktop scripts relative to the daemon's own source path.
  provisioner "shell" {
    execute_command = "sudo -n bash -eux '{{ .Path }}'"
    inline = [
      "install -d -m 0755 /opt/schermes",
      "tar -xzf /tmp/schermes-src.tar.gz -C /opt/schermes --strip-components=1",
      "rm -f /tmp/schermes-src.tar.gz",
      // The single provisioning path: packages, Node, pnpm, uv, users, sudoers, the systemd
      // unit and the daemon's dependencies. Nothing here duplicates it.
      "/opt/schermes/infra/install.sh",
      "systemctl is-enabled schermes.service",
    ]
  }

  // Everything this build knew, unlearned. Ordered so that sudo still works for
  // `shutdown_command` afterwards: cloud-init's own NOPASSWD rule for `debian` survives, which
  // is also what makes `console_password` a usable recovery account.
  //
  // Unverified ordering, and the one place a first real build is most likely to trip: this
  // revokes the SSH credentials Packer is connected with, and `shutdown_command` runs after it.
  // It is fine while the communicator reuses the session it already authenticated, and fails at
  // the very last step if it ever reconnects. If that happens, move the two revocation lines
  // into a `systemd` oneshot that runs on first boot instead.
  provisioner "shell" {
    execute_command = "sudo -n bash -eux '{{ .Path }}'"
    inline = [
      // The build login. Revoked either way; only the console account is optional.
      "rm -f /home/debian/.ssh/authorized_keys",
      // Base64 so an arbitrary password cannot break out of the quoting, and so it never
      // becomes a shell word. Not `environment_vars`: reaching those from a script running
      // under sudo needs `sudo -E`, which the cloud image's sudoers does not grant SETENV for.
      "set +x; pw=$(printf %s '${base64encode(var.console_password)}' | base64 -d)",
      "if [ -n \"$pw\" ]; then printf 'debian:%s\\n' \"$pw\" | chpasswd; else passwd -l debian; fi",
      "unset pw; set -x",
      // cloud-init wrote this to accept the build password over SSH. The shipped image is
      // key-only, whether or not a console password was set.
      "rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf",
      // Forget the seed, so first boot is a fresh instance that grows the disk and regenerates
      // the host keys deleted below rather than replaying this build.
      "cloud-init clean --logs --seed",
      // Every VM from this image would otherwise share one host key. Deleting them fails
      // closed: if regeneration ever did not happen, sshd refuses to start, and schermes does
      // not need SSH.
      "rm -f /etc/ssh/ssh_host_*",
      // A cloned machine-id would make two VMs from this image collide on DHCP leases.
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",
      "find /var/log -type f -exec truncate -s 0 {} +",
      "rm -f /root/.bash_history /home/debian/.bash_history",
    ]
  }
}
