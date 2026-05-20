# Single-USB Install: Ubuntu 24.04 + Host Setup Scripts

How to ship `setup-docker.sh`, `setup-laptop.sh`, and the `phases/` tuning
together with the OS install onto one USB stick. Two delivery formats are
covered: raw shell scripts and a pre-built OCI image.

## Approaches at a glance

| # | Method                         | When to use                                       |
|---|--------------------------------|---------------------------------------------------|
| 1 | Ubuntu Autoinstall (cloud-init)| Recommended; reproducible, CI-friendly            |
| 2 | Cubic (GUI remaster)           | One-shot, no scripting                            |
| 3 | Ventoy + autoinstall partition | Keep the official ISO untouched, multi-ISO USB    |

## 1. Ubuntu Autoinstall (recommended)

The 24.04 live-server installer (`subiquity`) reads `nocloud` data from the
USB. Drop a `user-data` + `meta-data` pair plus the scripts onto the ISO,
set the boot args to point at them, and the install runs unattended.

### 1a. Shell-script delivery

```yaml
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: laptop
    username: tommoro
    password: "$6$...crypt-hash..."
  ssh:
    install-server: true
  packages: [curl, ca-certificates, gnupg, lsb-release]
  late-commands:
    # copy the script bundle into the installed system
    - cp -r /cdrom/extras /target/opt/setup
    - chmod +x /target/opt/setup/*.sh /target/opt/setup/phases/*.sh
    # install a one-shot systemd unit that runs on first boot
    - |
      cat > /target/etc/systemd/system/first-boot-setup.service <<'EOF'
      [Unit]
      Description=First boot Docker + laptop tuning
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/var/lib/first-boot-setup.done
      [Service]
      Type=oneshot
      ExecStart=/bin/bash -c '/opt/setup/setup-docker.sh && /opt/setup/setup-laptop.sh && touch /var/lib/first-boot-setup.done'
      [Install]
      WantedBy=multi-user.target
      EOF
    - curtin in-target --target=/target -- systemctl enable first-boot-setup.service
```

ISO remaster flow:

1. Download `ubuntu-24.04.x-live-server-amd64.iso`.
2. Unpack the ISO, add `/nocloud/{user-data,meta-data}` and copy the scripts
   to `/extras/`.
3. Patch the GRUB/isolinux boot entries with
   `autoinstall ds=nocloud;s=/cdrom/nocloud/`.
4. Repack with `xorriso`, write to USB with `dd` or Rufus.

Reference: <https://ubuntu.com/server/docs/install/autoinstall>.

### 1b. OCI-image delivery

Same autoinstall flow, but the host-tuning logic ships as a pre-built OCI
image. The benefit is an immutable, versioned, registry-pushable artifact;
the tradeoff is that the container still needs host access (privileged,
host PID, bind-mounted `/`) because the scripts mutate `/etc/docker`,
systemd units, TLP/thermald, journald, etc. Containerization here buys
distribution ergonomics, not isolation.

`Dockerfile`:

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl gnupg systemd \
    && rm -rf /var/lib/apt/lists/*
COPY setup-docker.sh setup-laptop.sh /opt/setup/
COPY lib    /opt/setup/lib
COPY phases /opt/setup/phases
RUN chmod +x /opt/setup/*.sh /opt/setup/phases/*.sh
ENTRYPOINT ["/opt/setup/setup-laptop.sh"]
```

Build and export:

```sh
docker build -t laptop-setup:1.0.0 .
docker save laptop-setup:1.0.0 -o build/laptop-setup-1.0.0.tar
# OCI layout alternative:
# skopeo copy docker-daemon:laptop-setup:1.0.0 oci:build/laptop-setup:1.0.0
```

Autoinstall `user-data` (Docker variant):

```yaml
#cloud-config
autoinstall:
  version: 1
  identity: { hostname: laptop, username: tommoro, password: "$6$..." }
  ssh: { install-server: true }
  packages: [docker.io, ca-certificates]
  late-commands:
    - mkdir -p /target/opt/setup-oci
    - cp /cdrom/extras/oci/laptop-setup-1.0.0.tar /target/opt/setup-oci/
    - |
      cat > /target/etc/systemd/system/first-boot-setup.service <<'EOF'
      [Unit]
      Description=First-boot host tuning via OCI image
      After=docker.service network-online.target
      Requires=docker.service
      ConditionPathExists=!/var/lib/first-boot-setup.done
      [Service]
      Type=oneshot
      ExecStartPre=/usr/bin/docker load -i /opt/setup-oci/laptop-setup-1.0.0.tar
      ExecStart=/usr/bin/docker run --rm \
        --privileged --pid=host --network=host \
        -v /:/host \
        -e HOST_ROOT=/host \
        laptop-setup:1.0.0
      ExecStartPost=/bin/touch /var/lib/first-boot-setup.done
      [Install]
      WantedBy=multi-user.target
      EOF
    - curtin in-target --target=/target -- systemctl enable first-boot-setup.service
```

To make the scripts work from inside the container, either prefix paths
with `${HOST_ROOT:-}` or jump into the host namespaces:

```sh
nsenter -t 1 -m -p -- /opt/setup/setup-laptop.sh
```

### Podman + Quadlet variant

Drop a quadlet file instead of a hand-rolled `.service`; the systemd
generator turns it into a unit automatically. Requires `apt install podman`.

```ini
# /etc/containers/systemd/first-boot-setup.container
[Unit]
ConditionPathExists=!/var/lib/first-boot-setup.done
After=network-online.target

[Container]
Image=oci-archive:/opt/setup-oci/laptop-setup-1.0.0.tar
PodmanArgs=--privileged --pid=host --network=host
Volume=/:/host

[Service]
Type=oneshot
ExecStartPost=/bin/touch /var/lib/first-boot-setup.done

[Install]
WantedBy=multi-user.target
```

### Pure OCI runtime (runc) variant

`oci-runtime-tool generate` → `config.json` + `rootfs/` → `runc run`. Only
needs `runc`, but host mounts and cgroup wiring have to be authored by
hand. Practical only if you must avoid both docker and podman.

| Delivery              | Dependency | Pro                                | Con                         |
|-----------------------|------------|------------------------------------|-----------------------------|
| `docker save` tarball | docker     | Standard, registry-pushable        | Needs docker daemon         |
| Podman + quadlet      | podman     | systemd-native, rootless possible  | Quadlet learning curve      |
| runc + OCI bundle     | runc       | Minimal runtime                    | Hand-written `config.json`  |

## 2. Cubic (GUI remaster)

```sh
sudo apt install cubic
```

Open Cubic, load the 24.04 ISO, drop into the chroot, install packages,
copy scripts to `/opt/setup`, enable the systemd unit, repack. Fast for a
one-off; not repeatable in CI.

## 3. Ventoy + autoinstall data partition

Ventoy turns a USB into a multi-ISO bootloader. Put the official ISO on
partition 1 and a second partition with `user-data` + scripts; use Ventoy's
plugin to inject them at boot time. Keeps the upstream ISO byte-identical,
but plugin configuration is the trickiest of the three.

## Recommendation

Use **Autoinstall + `xorriso` remaster as a build script committed to this
repo**. The host-tuning scripts are already idempotent, so `late-commands`
can call them directly (1a) or via a versioned OCI image (1b). Burning the
USB stays the only manual step.

### What ships in this repo

Approach 1a (shell-script delivery) is implemented:

- [`nocloud/user-data`](../nocloud/user-data) — autoinstall config with
  envsubst placeholders for hostname, username, password hash, SSH key. The
  `late-commands` block stages `/cdrom/extras` into `/target/opt/setup` and
  enables a `first-boot-setup.service` oneshot unit.
- [`nocloud/meta-data`](../nocloud/meta-data) — minimal cloud-init metadata
  (`instance-id`, `local-hostname`).
- [`build-iso.sh`](../build-iso.sh) — downloads the live-server ISO,
  renders `nocloud/`, stages `extras/` from this repo, patches the GRUB
  cmdline with `autoinstall ds=nocloud;s=/cdrom/nocloud/`, and repackages
  via `xorriso -boot_image any replay` to preserve hybrid BIOS/UEFI boot.

```bash
SSH_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
ISO_USERNAME=tommoro ISO_HOSTNAME=lab01 \
./build-iso.sh
```

Approach 1b (OCI-image delivery) is **not** committed because the container
still needs `--privileged --pid=host -v /:/host` to mutate `/etc/docker`,
systemd units, and TLP/thermald — the isolation benefit doesn't justify the
extra moving parts for a single-laptop deployment. The Dockerfile and
quadlet snippets above remain as a reference if you want to add it later.
