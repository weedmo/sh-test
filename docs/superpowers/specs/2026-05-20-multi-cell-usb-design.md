# Multi-Cell Autoinstall USB — Design Spec

Status: draft (awaiting user review)
Author: pair with Claude Code, 2026-05-20
Supersedes: prior single-cell `build-iso.sh` design (kept intact; this spec
adds a multi-cell layer on top).

---

## 1. Context

We already have a single-USB Ubuntu 24.04 autoinstall ISO builder
(`build-iso.sh` + `nocloud/`) that drops `setup-docker.sh` and
`setup-laptop.sh` into `/cdrom/extras`, runs them on first boot via
`first-boot-setup.service`, and yields a hardened, always-on Docker host
tuned for the "9h/day, plugged-in laptop used as a server" use case (the
core README purpose; see `phases/02..07` for the actual tuning).

A new operational layer is required: **16 identical-but-numbered cells**
(Cell001..Cell016), all in `sectorA` today, with future sector expansion
planned. Each machine must:

1. Install Ubuntu unattended.
2. Come up with a per-cell Linux user account (`Cell001` ... `Cell016`)
   and matching hostname.
3. Apply the same Docker + long-uptime tuning as the existing flow (no
   extra work — `setup-laptop.sh` already covers thermals, charge cap,
   TLP, lid/suspend behavior, journald cap, baseline monitoring).
4. Have `/opt/simdd/simdd_config.txt` populated with the correct
   `SIMDD_CELL_ID`.
5. Run `start-simdd.run` under a dedicated, restart-on-failure systemd
   service after the first boot, with no operator intervention.

## 2. Goals

- One ISO image that can install any of the 16 cells.
- A single human action per machine: pick the right entry in the GRUB
  boot menu. Everything downstream (account name, hostname, simdd config,
  first-boot setup, simdd daemon) is determined by that one choice.
- Idempotent (safe to re-run setup scripts; first-boot guarded by a
  sentinel file).
- Forward hook for future sector expansion (`SIMDD_SECTOR` settable at
  build time; nothing in the ISO layout assumes there is only one sector).

## 3. Non-goals

- MAC-based auto-detection of cell ID (rejected during brainstorming —
  premature given current scale).
- A custom installer UI inside subiquity (not justified for 16 cells).
- Containerizing the setup scripts (OCI delivery was considered in
  `docs/usb-install.md` §1b and explicitly rejected: container still
  needs `--privileged --pid=host -v /:/host`, so containerization buys
  no isolation, only extra moving parts).
- Hardening SSH beyond what `setup-docker.sh` already does. SSH stays
  key-only (per build-time `SSH_AUTHORIZED_KEY`). The `1234` password
  applies to console + sudo only.

## 4. Confirmed decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | One ISO covers all 16 cells via **16 separate GRUB menu entries** | Sole human action is picking the right entry; no `e`-key editing; user-data is static per cell, so debugging is trivial. |
| D2 | Each GRUB entry points at a **distinct nocloud datasource path** (`/cdrom/nocloud-cell{NN}/`) | Static user-data per cell. Avoids cloud-init Jinja templating (not validated on 24.04 subiquity) and avoids late-commands user-rename gymnastics. |
| D3 | Per-cell values: `username = Cell{NNN}`, `hostname = cell{NN}`, `SIMDD_CELL_ID = N` (no leading zeros in the config value, since the original config has `SIMDD_CELL_ID=1`) | Matches user-stated convention "Cell002". Other simdd_config keys (`SIMDD_SECTOR`, `SIMDD_RECEIVER_URL`, `SIMDD_CAMERA_*_PORT`) stay fixed across cells. |
| D4 | ubuntu-side password is `1234` (locally hashed at build time); SSH stays key-only via `SSH_AUTHORIZED_KEY` build env | Operator stated `1234` is for the Ubuntu user account (console + sudo). SSH password remains disabled so a stolen IP + weak password cannot grant remote shell. |
| D5 | `first-boot-setup.service` runs `setup-docker.sh` + `setup-laptop.sh` (covers 9h-uptime tuning automatically), then drops sentinel | No new tuning required — the existing `phases/*` cover thermal, charge cap (80%), TLP, lid-do-not-suspend, journald cap, monitoring baseline. |
| D6 | `simdd.service` is a **separate** systemd unit, `Type=simple`, `Restart=on-failure`, ordered after `network-online.target` and `docker.service` | Operator wants simdd as a restartable daemon, independent of the one-shot first-boot setup. Unit gets enabled by autoinstall `late-commands`; first invocation happens automatically post-reboot, identical to subsequent boots. |
| D7 | `SIMDD_SECTOR` is a build-time env var (`ISO_SECTOR`, default `sectorA`) baked into every per-cell user-data | Future expansion = re-run `build-iso.sh` with a different `ISO_SECTOR` to produce a second ISO. ISO layout itself does not enumerate sectors. |

## 5. Architecture

### 5.1 ISO layout

```
/                                       (ISO root)
├── boot/grub/
│   ├── grub.cfg                        ← 16 menuentry blocks replacing the
│   │                                     stock subiquity entries
│   └── loopback.cfg                    ← mirrored 16 entries (for tools
│                                         that boot the ISO as loopback)
├── nocloud-cell01/
│   ├── user-data                       ← username=Cell001, hostname=cell01,
│   │                                     SIMDD_CELL_ID=1, sector=sectorA
│   └── meta-data                       ← instance-id, local-hostname=cell01
├── nocloud-cell02/   …   nocloud-cell16/
└── extras/                             ← identical for every cell
    ├── setup-docker.sh
    ├── setup-laptop.sh
    ├── lib/
    ├── phases/
    └── simdd/
        ├── start-simdd.run             ← ~832 MB self-extracting
        ├── view-head.run
        ├── find_camera.sh
        └── simdd_config.txt            ← TEMPLATE; per-cell value of
                                          SIMDD_CELL_ID gets sed-patched
                                          into /target/opt/simdd/ by
                                          each per-cell user-data
```

### 5.2 GRUB menuentry pattern

```
menuentry "Install Cell 001 (sectorA)" --class ubuntu {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud-cell01/ ---
    initrd /casper/initrd
}
... (Cell 002 through Cell 016) ...

set default=0
set timeout=30
```

Default of `Cell 001` with a 30 s timeout is a *deliberate* choice: it
favors visibility (no silent auto-pick) and forces the operator to look
at the screen long enough to catch a wrong USB. Operators can override
with `ISO_GRUB_DEFAULT` / `ISO_GRUB_TIMEOUT` build env vars.

### 5.3 Per-cell user-data (rendered)

Identical except for three lines per file:

```yaml
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: cell01                    # cell{NN}
    realname: Cell001                   # Cell{NNN}
    username: Cell001                   # Cell{NNN}
    password: "$6$...hash-of-1234..."   # locally generated at build time
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "${SSH_AUTHORIZED_KEY}"
  packages: [curl, ca-certificates, gnupg, lsb-release]
  storage: { layout: { name: lvm } }
  late-commands:
    - cp -r /cdrom/extras /target/opt/setup
    - chmod +x /target/opt/setup/setup-docker.sh /target/opt/setup/setup-laptop.sh
    - find /target/opt/setup/phases -name '*.sh' -exec chmod +x {} +
    - mkdir -p /target/opt/simdd
    - cp -r /cdrom/extras/simdd/. /target/opt/simdd/
    - chmod +x /target/opt/simdd/*.run /target/opt/simdd/*.sh
    - sed -i 's/^SIMDD_CELL_ID=.*/SIMDD_CELL_ID=1/'        /target/opt/simdd/simdd_config.txt
    - sed -i 's/^SIMDD_SECTOR=.*/SIMDD_SECTOR=sectorA/'    /target/opt/simdd/simdd_config.txt
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
      StandardOutput=journal+console
      StandardError=journal+console
      TimeoutStartSec=30min
      [Install]
      WantedBy=multi-user.target
      EOF
    - |
      cat > /target/etc/systemd/system/simdd.service <<'EOF'
      [Unit]
      Description=SIMDD runtime
      After=network-online.target docker.service first-boot-setup.service
      Wants=network-online.target
      Requires=docker.service
      [Service]
      Type=simple
      WorkingDirectory=/opt/simdd
      EnvironmentFile=/opt/simdd/simdd_config.txt
      ExecStart=/opt/simdd/start-simdd.run
      Restart=on-failure
      RestartSec=5s
      StandardOutput=journal
      StandardError=journal
      [Install]
      WantedBy=multi-user.target
      EOF
    - curtin in-target --target=/target -- systemctl enable first-boot-setup.service
    - curtin in-target --target=/target -- systemctl enable simdd.service
```

The two `sed -i ... SIMDD_CELL_ID=N` and `SIMDD_SECTOR=sectorA` lines are
the per-cell + per-sector values that `build-iso.sh` interpolates when
rendering each `nocloud-cellNN/user-data`.

## 6. Data flow

```
Operator boots USB
   │
   ▼
GRUB menu (16 entries)
   │  picks "Install Cell 003"
   ▼
kernel cmdline: ds=nocloud;s=/cdrom/nocloud-cell03/
   │
   ▼
subiquity loads /cdrom/nocloud-cell03/user-data
   │  identity.username = Cell003
   │  identity.hostname = cell03
   │
   ▼
Install Ubuntu, run late-commands:
   │  copy /cdrom/extras  → /target/opt/setup
   │  copy /cdrom/extras/simdd → /target/opt/simdd
   │  sed SIMDD_CELL_ID=3 into /target/opt/simdd/simdd_config.txt
   │  install + enable first-boot-setup.service
   │  install + enable simdd.service
   │
   ▼
Reboot
   │
   ▼
First boot:
   ├─ first-boot-setup.service (oneshot)
   │     setup-docker.sh
   │     setup-laptop.sh        ← applies the 9h-uptime tuning
   │     touch /var/lib/first-boot-setup.done
   │
   └─ simdd.service (simple, after first-boot-setup + docker + network)
         /opt/simdd/start-simdd.run
         (Restart=on-failure)
```

Subsequent boots: `first-boot-setup.service` is skipped via
`ConditionPathExists=!`, `simdd.service` starts as a normal daemon.

## 7. Components

### 7.1 New files in the repo

| Path | Role |
|------|------|
| `nocloud/user-data` | Single template; envsubst targets include `${ISO_CELL_ID}`, `${ISO_CELL_NAME}` (`Cell{NNN}`), `${ISO_HOSTNAME}` (`cell{NN}`), `${ISO_SECTOR}`, `${ISO_PASSWORD_HASH}`, `${SSH_AUTHORIZED_KEY}`. |
| `nocloud/meta-data` | Same template, only `${ISO_HOSTNAME}` and `instance-id` change. |
| `nocloud/grub-fragment.cfg.tmpl` | New. Single menuentry template with `${ISO_CELL_ID}`, `${ISO_CELL_NUM}`, `${ISO_SECTOR}` placeholders. `build-iso.sh` renders this 16× and concatenates with a `set default=` + `set timeout=` header. |
| `docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md` | This spec. |

### 7.2 Changed files

| Path | Change |
|------|--------|
| `build-iso.sh` | Replace single-cell logic with a 1..16 loop. New env vars: `ISO_SECTOR` (default `sectorA`), `UBUNTU_PASSWORD` (default `1234`, hashed at build via `openssl passwd -6` or `mkpasswd -m sha512crypt`). Replace stock GRUB cfg with the 16-entry generated cfg. `SSH_AUTHORIZED_KEY` becomes optional (warn if empty, since SSH would then be unreachable until a key is dropped manually). |
| `README.md` | Update the "Option D — Single-USB autoinstall" section: 16 GRUB entries, per-cell account, simdd auto-start. |
| `docs/usb-install.md` | Add a short subsection pointing at this spec for the multi-cell layout; the single-cell flow stays as the simpler reference. |

### 7.3 Files NOT changed

- `setup-docker.sh`, `setup-laptop.sh`, `lib/common.sh`, `phases/*.sh` —
  the entire 9h-uptime tuning chain stays untouched. Re-using them
  verbatim is the whole point.

## 8. Failure modes

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Operator picks the wrong cell entry | `hostnamectl` / SSH banner / `cat /opt/simdd/simdd_config.txt` after first boot | Reinstall from USB. (16 visible entries minimize this vs. an `e`-key edit which is the failure mode we explicitly rejected.) |
| `start-simdd.run` exits immediately because it is a one-shot installer (not a daemon) | `journalctl -u simdd` shows rapid restart loop | Switch `simdd.service` to `Type=oneshot`. Spec includes this as the most likely real-world adjustment. The fix is a one-line change committed only after we observe actual `.run` behavior on hardware. |
| docker.service not up yet when simdd starts | `simdd.service` fails immediately, `Restart=on-failure` kicks in within 5 s | Already handled by `Requires=docker.service` ordering. |
| zip contents change in a future drop (filenames differ) | `build-iso.sh` fails when copying expected files into `extras/simdd/` | Build script asserts the expected 4 filenames are present and emits a clear `die` message. |
| Two USBs accidentally burned with the same cell entry | Two hosts join the LAN with identical `cell{NN}` hostname → ARP / mDNS collision | Operational mitigation only (label USBs immediately after burn). Out of design scope. |
| GRUB picks default Cell 001 because the operator wandered off | hostname `cell01` shows up on the wrong machine | Default timeout is 30 s and default entry is Cell 001 — first machine plugged in is normally Cell 001 anyway. Documented in README. |
| 9h-uptime tuning silently regresses (e.g., a future TLP package change) | Phase 04 logs in `journalctl`, plus phase 07's `/var/log/laptop-baseline.txt` baseline snapshot | Reinstall picks up the latest `phases/`. No multi-cell-specific impact. |

## 9. Testing

| Stage | What to verify | How |
|-------|----------------|-----|
| Unit (build-iso.sh) | All 16 `nocloud-cell{NN}/user-data` differ only in 3 lines (username, hostname, SIMDD_CELL_ID); all 16 GRUB entries point at the right datasource | `diff` neighboring pairs; `grep -c menuentry` returns 16 |
| Unit (envsubst) | No `${...}` placeholders remain in any rendered file | `grep -RnE '\\$\\{[A-Z_]+\\}' build/nocloud-*/` returns empty |
| Unit (shell syntax) | All new scripts parse | `bash -n` for each |
| Integration (smoke) | ISO boots in QEMU, GRUB menu shows 16 entries, picking Cell 003 yields a host with `hostname=cell03`, `id Cell003`, `cat /opt/simdd/simdd_config.txt` shows `SIMDD_CELL_ID=3` | `qemu-system-x86_64 -m 4G -cdrom build/ubuntu-24.04-autoinstall.iso -boot d` (manual one-shot, not CI) |
| Integration (real hw, 1 machine) | First-boot logs in `journalctl -u first-boot-setup` show setup-laptop.sh completed cleanly; `journalctl -u simdd` shows the daemon running | Use Cell 001 hardware as the canary |
| Regression (9h-uptime) | After install, lid-close on AC does not suspend; battery charge ceiling reads ≤80 %; `systemctl is-enabled tlp` is `enabled`; `cat /etc/docker/daemon.json` has `live-restore: true` | One-shot manual check on the Cell 001 canary |

## 10. Open questions / future work

- **Real behavior of `start-simdd.run`**: spec assumes a long-running
  process suitable for `Type=simple`. If it turns out to be a one-shot
  installer that exits 0 after extracting, switch to `Type=oneshot` and
  drop `Restart=on-failure`. This is a one-line follow-up after we
  observe the canary boot.
- **Sector expansion**: when sectorB lands, the operator re-runs
  `ISO_SECTOR=sectorB build-iso.sh` to produce a second ISO. No change
  to the ISO internal layout. If sectors ever need to coexist on the
  same USB, GRUB entries become a 2D grid (sector × cell) — out of scope
  today.
- **Camera USB ports** (`SIMDD_CAMERA_LEFT_PORT`, `SIMDD_CAMERA_RIGHT_PORT`):
  spec assumes identical USB topology across all 16 machines. If that
  proves false in the field, the same envsubst mechanism can be extended
  to per-cell camera ports via a small lookup table in `build-iso.sh`.
- **First-cell-id zero-padding mismatch**: user wants `Cell002` (3-digit,
  zero-padded) for the username but the existing `simdd_config.txt` uses
  `SIMDD_CELL_ID=1` (no padding). Spec keeps both conventions: username
  is 3-digit padded, `SIMDD_CELL_ID` stays integer. If the consuming
  software needs a different format we adjust the sed expression.
