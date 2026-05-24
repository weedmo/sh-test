# sh-test — Ubuntu 24.04 Docker host & laptop tuning

A small, idempotent collection of bash scripts that turns a fresh **Ubuntu 24.04
(Noble) / linux-amd64** machine into a hardened, always-on Docker host. Built
for the "9h/day, plugged-in laptop used as a server" use case, but the Docker
installer alone works on any Ubuntu 24.04 box.

Repository: <https://github.com/weedmo/sh-test>

---

## TL;DR — one-liner install

Install Docker Engine 29.2.0 + Compose v5.0.2 on a fresh Ubuntu 24.04 host:

```bash
curl -fsSL https://raw.githubusercontent.com/weedmo/sh-test/main/setup-docker.sh | sudo bash
```

Run the laptop / always-on tuning suite (requires the full repo because it
loads `phases/*.sh` and `lib/common.sh`):

```bash
curl -fsSL https://github.com/weedmo/sh-test/archive/refs/heads/main.tar.gz \
  | tar -xz \
  && cd sh-test-main \
  && sudo ./setup-laptop.sh
```

See **[Installation via curl](#installation-via-curl)** below for safer
download-then-inspect flows, version pinning, and the `git clone` alternative.

---

## What each script does

### Top-level entry points

| File | Role | Requires |
| --- | --- | --- |
| [`setup-docker.sh`](./setup-docker.sh) | Installs Docker Engine, CLI, containerd, buildx, and Compose plugin at pinned versions. Also installs and enables `openssh-server`, opens UFW port 22 if active, adds the invoking user to the `docker` group, and prints all reachable SSH endpoints. | root, Ubuntu 24.04, amd64 |
| [`setup-laptop.sh`](./setup-laptop.sh) | Orchestrator. Runs every script under `phases/` in order. Supports `--list`, `--only 01,03`, `--skip 04,05`, and `--dry-run`. Idempotent. | root, sources `lib/common.sh` |

### Shared library

| File | Role |
| --- | --- |
| [`lib/common.sh`](./lib/common.sh) | Sourced by every phase. Provides colored `log`/`warn`/`die`/`ok` output, `require_root`, platform detection (`os_codename`, `cpu_vendor`, `is_intel`, `is_amd`, `is_laptop`, `has_battery`), and idempotency primitives `write_file`, `backup_once`, `enable_now`, `disable_now`. Respects `DRY_RUN=1`. Do **not** execute directly — it is source-only. |

### Phases (run in order by `setup-laptop.sh`)

| Phase | File | What it does | Skipped when |
| --- | --- | --- | --- |
| **01** | [`phases/01-docker-hardening.sh`](./phases/01-docker-hardening.sh) | Writes `/etc/docker/daemon.json` with bounded `json-file` logs (`max-size=20m`, `max-file=3`) and `live-restore: true` so dockerd restarts (e.g. apt upgrades) don't kill containers. Installs `/etc/cron.d/docker-prune` for a nightly `docker system prune -af --filter "until=72h"`. Uses `jq` to merge into existing `daemon.json` without clobbering unrelated keys. | `docker` is not installed (warned, not fatal) |
| **02** | [`phases/02-thermal.sh`](./phases/02-thermal.sh) | **Intel hosts:** installs and enables `thermald` (DPTF-based throttling). **AMD hosts:** disables `thermald` (no-op on AMD). On laptops, switches `scaling_governor` to `powersave` if it isn't already `powersave`/`schedutil`. Installs `lm-sensors` for visibility. | Unknown CPU vendor: skipped with warning |
| **03** | [`phases/03-battery.sh`](./phases/03-battery.sh) | Caps charge ceiling at `CHARGE_LIMIT=80%` via `/sys/class/power_supply/BAT*/charge_control_end_threshold`. Persists across reboots with a systemd oneshot unit `battery-charge-threshold.service`. Works on Dell / ThinkPad / ASUS when the kernel driver exposes the sysfs node. | No battery present, or kernel driver does not expose the threshold |
| **04** | [`phases/04-tlp.sh`](./phases/04-tlp.sh) | Replaces `power-profiles-daemon` with **TLP** + `tlp-rdw`. Drops `/etc/tlp.d/99-laptop-always-on.conf` tuned for plugged-in laptops: `powersave` governor on both AC and battery, `balance_performance` EPP on AC, turbo on AC only, `PLATFORM_PROFILE_ON_AC=balanced`. Leaves TLP charge thresholds **disabled** to avoid fighting phase 03. | Not a laptop |
| **05** | [`phases/05-lid-and-suspend.sh`](./phases/05-lid-and-suspend.sh) | Writes `/etc/systemd/logind.conf.d/99-laptop-always-on.conf` so lid-close does **not** suspend (would kill containers). Default `LID_BEHAVIOR=ignore-ac-suspend-bat` only ignores the lid on AC; set `LID_BEHAVIOR=ignore` to never suspend (needs a cooling stand!). Also `systemctl mask`s `sleep.target` / `suspend.target` / `hibernate.target` / `hybrid-sleep.target` unless `MASK_SLEEP_TARGETS=0`. | Not a laptop |
| **06** | [`phases/06-journald.sh`](./phases/06-journald.sh) | Caps systemd-journald disk usage to `SystemMaxUse=2G`, `SystemKeepFree=10G`, `MaxRetentionSec=2week`, `Compress=yes`. Prevents chatty containers from filling `/var/log`. | (never skipped) |
| **07** | [`phases/07-monitoring.sh`](./phases/07-monitoring.sh) | Installs `lm-sensors` + `smartmontools`, runs `sensors-detect --auto` on first install, and writes a one-shot baseline snapshot to `/var/log/laptop-baseline.txt` (uname, DMI, sensors, lsblk, SMART summary). Re-snapshot anytime with `sudo bash phases/07-monitoring.sh`. | (never skipped) |

> **Idempotency contract:** every script can be re-run safely. State files are
> compared before writing (`write_file`), existing files are backed up once
> per run (`backup_once`), and systemd units use `enable --now` rather than
> blind starts.

---

## Installation via curl

### Option A — single-file (Docker installer only)

The Docker installer is fully self-contained. Pipe-to-bash is convenient but
opaque; prefer **download → inspect → run** on hosts you care about.

**One-liner (convenience):**

```bash
curl -fsSL https://raw.githubusercontent.com/weedmo/sh-test/main/setup-docker.sh | sudo bash
```

**Safer (download, read, then run):**

```bash
curl -fsSL -o setup-docker.sh \
  https://raw.githubusercontent.com/weedmo/sh-test/main/setup-docker.sh
less setup-docker.sh                # inspect
chmod +x setup-docker.sh
sudo ./setup-docker.sh
```

**Pin to a specific commit** (recommended for reproducible installs — replace
`<sha>` with the commit you reviewed):

```bash
curl -fsSL -o setup-docker.sh \
  https://raw.githubusercontent.com/weedmo/sh-test/<sha>/setup-docker.sh
sudo bash setup-docker.sh
```

**Override pinned versions** via env vars:

```bash
sudo DOCKER_VERSION=29.2.0 \
     CONTAINERD_VERSION=2.2.1 \
     COMPOSE_VERSION=v5.0.2 \
     ./setup-docker.sh
```

After install, open a new shell (or run `newgrp docker`) so the `docker` group
membership takes effect; you can then run `docker` without `sudo`.

### Option B — tarball (full repo, includes `phases/` and `lib/`)

`setup-laptop.sh` reads `phases/*.sh` and `lib/common.sh` at runtime, so a
single curl-to-bash will not work. Pull the whole repo as a tarball:

```bash
curl -fsSL -o sh-test.tar.gz \
  https://github.com/weedmo/sh-test/archive/refs/heads/main.tar.gz
tar -xzf sh-test.tar.gz
cd sh-test-main
sudo ./setup-laptop.sh           # run all phases
```

Pin to a tag/commit:

```bash
curl -fsSL -o sh-test.tar.gz \
  https://github.com/weedmo/sh-test/archive/<sha-or-tag>.tar.gz
tar -xzf sh-test.tar.gz
cd sh-test-*
sudo ./setup-laptop.sh
```

### Option C — git clone (preferred for repeated use)

```bash
git clone https://github.com/weedmo/sh-test.git
cd sh-test
sudo ./setup-laptop.sh
```

### Option D — Multi-cell autoinstall USB (16 cells per ISO)

One ISO installs any of Cell001..Cell016 in a single sector. The GRUB
menu shows 16 entries; pick the right one for the machine in front of
you. On first boot the host runs `setup-docker.sh` + `setup-laptop.sh`
and then starts `simdd.service` as a daemon. SSH lands on the
`CellNNN` account.

```bash
sudo apt install xorriso gettext-base curl openssl python3   # build host deps
SSH_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
SIMDD_ZIP=~/Downloads/drive-download-20260519T075900Z-3-001.zip \
./build-iso.sh
# → build/ubuntu-24.04-multi-cell-sectorA.iso
sudo dd if=build/ubuntu-24.04-multi-cell-sectorA.iso of=/dev/sdX bs=4M \
        status=progress conv=fsync
```

Defaults: `ISO_SECTOR=sectorA`, `UBUNTU_PASSWORD=1234` (locally hashed),
SSH is key-only via `SSH_AUTHORIZED_KEY` (empty value = SSH installed
but unreachable until you add a key manually — local console only).
Timezone is `Asia/Ho_Chi_Minh`.

**Network — static per-cell IP.** Ethernet (`en*`) is pinned to
`10.0.0.<cell-id>/24` (Cell001 = `10.0.0.1`, Cell016 = `10.0.0.16`)
with gateway and DNS at `ISO_GATEWAY` (default `10.0.0.254`, expected
to be the Mikrotik switch). Wi-Fi (`TommoroVN`) stays DHCP as an
outbound fallback. Override with `ISO_GATEWAY`, `ISO_DNS`, `ISO_PREFIX`
at build time, e.g. `ISO_GATEWAY=10.0.0.1 ISO_DNS=1.1.1.1 ./build-iso.sh`.

**Operator note — remove the USB before reboot.** The GRUB menu waits
indefinitely for an explicit cell selection (no auto-default), and
subiquity automatically reboots once the install finishes. When the
installer prints **"Please remove the installation medium, then press
ENTER"**, unplug the USB *before* pressing Enter — otherwise the next
boot returns to the GRUB menu and you will end up reinstalling the
machine in a loop.

For sector expansion, re-run with a different `ISO_SECTOR` to produce a
second ISO. Design rationale and per-cell layout in
[`docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md`](./docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md).

### Order on a fresh box

For a fresh Ubuntu 24.04 host that will become a Docker host **and** stay
plugged in 9h/day:

```bash
# 1. Docker + SSH baseline
curl -fsSL https://raw.githubusercontent.com/weedmo/sh-test/main/setup-docker.sh | sudo bash

# 2. Always-on laptop tuning (needs the full repo)
curl -fsSL https://github.com/weedmo/sh-test/archive/refs/heads/main.tar.gz \
  | tar -xz \
  && cd sh-test-main \
  && sudo ./setup-laptop.sh
```

---

## Running the orchestrator

```bash
sudo ./setup-laptop.sh                 # run every phase
sudo ./setup-laptop.sh --list          # list available phases
sudo ./setup-laptop.sh --only 01,03    # run only phases 01 and 03
sudo ./setup-laptop.sh --skip 04,05    # run everything except phases 04 and 05
sudo ./setup-laptop.sh --dry-run       # print what would change, no writes
```

`--dry-run` propagates through `lib/common.sh` so all mutating helpers
(`run`, `write_file`, `enable_now`) print intent instead of executing.

---

## Environment variables (cheat sheet)

All defaults are sane. Override only what you need.

| Variable | Default | Used by | Meaning |
| --- | --- | --- | --- |
| `DOCKER_VERSION` | `29.2.0` | `setup-docker.sh` | Docker Engine version |
| `CONTAINERD_VERSION` | `2.2.1` | `setup-docker.sh` | containerd version |
| `COMPOSE_VERSION` | `v5.0.2` | `setup-docker.sh` | Compose plugin version |
| `DOCKER_LOG_MAX_SIZE` | `20m` | phase 01 | Per-container log file size |
| `DOCKER_LOG_MAX_FILE` | `3` | phase 01 | Rotated log files retained |
| `DOCKER_PRUNE_UNTIL` | `72h` | phase 01 | Min idle age for `docker system prune` |
| `DOCKER_PRUNE_HOUR` | `4` | phase 01 | Cron hour for nightly prune (0–23) |
| `CHARGE_LIMIT` | `80` | phase 03 | Battery charge ceiling, 50–100 |
| `LID_BEHAVIOR` | `ignore-ac-suspend-bat` | phase 05 | Or `ignore` (needs cooling stand) |
| `MASK_SLEEP_TARGETS` | `1` | phase 05 | Set `0` to keep manual `systemctl suspend` |
| `JOURNAL_MAX_USE` | `2G` | phase 06 | journald `SystemMaxUse` |
| `JOURNAL_KEEP_FREE` | `10G` | phase 06 | journald `SystemKeepFree` |
| `JOURNAL_RETENTION` | `2week` | phase 06 | journald `MaxRetentionSec` |
| `DRY_RUN` | `0` | all phases | `1` = print, don't mutate |

Example:

```bash
sudo CHARGE_LIMIT=70 LID_BEHAVIOR=ignore ./setup-laptop.sh --skip 04
```

---

## Safety notes

- **Pipe-to-bash on production hosts is a trust decision.** Prefer the
  download-inspect-run flow, and pin to a commit hash you've reviewed.
- **Phase 03 vs phase 04 charge thresholds:** they overlap. Phase 03 (sysfs)
  is the default; TLP's `START_/STOP_CHARGE_THRESH_BAT0` is commented out in
  phase 04. Pick one — running both can produce surprising behavior.
- **Phase 05 / `LID_BEHAVIOR=ignore`:** a closed lid blocks the keyboard-deck
  heat path. Only use `ignore` with the laptop on a stand or propped open.
  The default `ignore-ac-suspend-bat` is the safer choice.
- **SSH is enabled by `setup-docker.sh`.** If the host is exposed to a hostile
  network, harden `/etc/ssh/sshd_config` (disable password auth, etc.) before
  exposing port 22.

---

## Repo conventions

- **No git worktrees in this repo.** See [`CLAUDE.md`](./CLAUDE.md) for the
  full reason — short version: `git add .` from the main checkout would stage
  a worktree as a fake submodule and leave stale gitlinks in history.
- All setup scripts must remain **idempotent**. Use `lib/common.sh` helpers
  (`write_file`, `backup_once`, `enable_now`) rather than raw `cp` / `echo >`.
