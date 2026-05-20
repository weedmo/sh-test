# Multi-Cell USB Autoinstall — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single-cell `build-iso.sh` already on the working tree into a multi-cell builder that produces one ISO covering Cell001..Cell016, with per-cell username/hostname/`SIMDD_CELL_ID` and a separate `simdd.service`. Reuse the existing `setup-laptop.sh` chain unchanged.

**Architecture:** One source `nocloud/user-data` template + one `nocloud/grub-fragment.cfg.tmpl` template. `build-iso.sh` loops 1..16, renders 16 `nocloud-cellNN/` datasource directories and 16 GRUB menuentries into a single ISO. `setup-docker.sh` + `setup-laptop.sh` are unchanged and run on first boot via `first-boot-setup.service`; `simdd.service` is installed by `late-commands` and starts as a daemon after `first-boot-setup`.

**Tech Stack:** bash, xorriso, envsubst (gettext-base), openssl (for SHA-512 password hashing), python3 (for unzip — `unzip` is not in WSL by default but `python3 -m zipfile` is), curl, Ubuntu 24.04 live-server ISO, cloud-init nocloud datasource, systemd.

**Source spec:** [`docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md`](../specs/2026-05-20-multi-cell-usb-design.md) (committed at `197903c`).

---

## File map

| File | State | Responsibility |
|------|-------|----------------|
| `nocloud/user-data` | rewrite (was single-cell) | Single template; per-cell values come via envsubst (`${ISO_CELL_ID}`, `${ISO_CELL_NAME}`, `${ISO_HOSTNAME}`, `${ISO_SECTOR}`, `${ISO_PASSWORD_HASH}`, `${SSH_AUTHORIZED_KEY}`). Embeds late-commands that copy `/cdrom/extras`, patch `simdd_config.txt`, and install `first-boot-setup.service` + `simdd.service`. |
| `nocloud/meta-data` | minimal edit | Template; `${ISO_HOSTNAME}` only. |
| `nocloud/grub-fragment.cfg.tmpl` | create | Single GRUB menuentry template referencing `${ISO_CELL_NUM}` (zero-padded 2 digits), `${ISO_CELL_NAME}` (e.g. Cell003), `${ISO_SECTOR}`. |
| `build-iso.sh` | full rewrite | 1..16 loop. Renders 16 nocloud dirs, builds GRUB cfg from fragments, stages `extras/` (incl. unzipped simdd payload), repackages ISO. |
| `README.md` | edit | Replace single-cell "Option D" section with the multi-cell flow. |
| `docs/usb-install.md` | edit | Add a short pointer to the multi-cell spec/plan. |
| `docs/superpowers/plans/2026-05-20-multi-cell-usb-autoinstall.md` | this file | Plan. |

No changes to `setup-docker.sh`, `setup-laptop.sh`, `lib/common.sh`, `phases/*.sh`. The 9h-uptime tuning chain is reused verbatim.

---

## Task 0: Lock the single-cell baseline as its own commit

Reason: the single-cell `build-iso.sh` and `nocloud/` files are currently untracked. Committing them first keeps the multi-cell change as a reviewable diff instead of a single mega-commit, and gives us a known-good rollback target.

**Files:**
- Add (untracked → tracked): `build-iso.sh`, `nocloud/user-data`, `nocloud/meta-data`
- Already tracked but modified: `.gitignore`, `README.md`, `docs/usb-install.md`

- [ ] **Step 1: Verify the current untracked state**

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
git status --short
```
Expected (order may vary):
```
 M .gitignore
 M README.md
 M docs/usb-install.md
?? build-iso.sh
?? nocloud/
```

- [ ] **Step 2: Stage the single-cell baseline**

Run:
```bash
git add .gitignore README.md docs/usb-install.md build-iso.sh nocloud/
git status --short
```
Expected:
```
M  .gitignore
M  README.md
A  build-iso.sh
M  docs/usb-install.md
A  nocloud/meta-data
A  nocloud/user-data
```

- [ ] **Step 3: Commit the single-cell baseline**

Run:
```bash
git commit -m "$(cat <<'EOF'
feat: single-cell USB autoinstall ISO builder

Adds build-iso.sh + nocloud/{user-data,meta-data} producing a one-shot
Ubuntu 24.04 installer USB that runs setup-docker.sh + setup-laptop.sh
on first boot via first-boot-setup.service. SSH-key-only by default.
Multi-cell variant follows in a subsequent commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: `[main <sha>] feat: single-cell USB autoinstall ISO builder` with 5 files changed.

- [ ] **Step 4: Verify clean tree**

Run:
```bash
git status --short
git log --oneline -3
```
Expected: empty status; HEAD is the new single-cell commit, then `197903c` (spec).

---

## Task 1: Rewrite `nocloud/user-data` as the multi-cell template

This is the single source of truth for *every* per-cell user-data. `build-iso.sh` will render it 16 times.

**Files:**
- Modify: `nocloud/user-data` (complete rewrite, ~75 lines)

- [ ] **Step 1: Replace `nocloud/user-data` with the multi-cell template**

Overwrite the file with exactly this content:

```yaml
#cloud-config
# Ubuntu 24.04 (subiquity) autoinstall configuration — multi-cell template.
#
# Rendered by build-iso.sh once per cell (Cell001..Cell016) with envsubst.
# Required envs:
#   ISO_CELL_ID         integer 1..16 (no padding, matches simdd_config.txt)
#   ISO_CELL_NAME       Cell001..Cell016 (3-digit zero-padded, used for
#                       Linux username + realname)
#   ISO_HOSTNAME        cell01..cell16 (2-digit zero-padded)
#   ISO_SECTOR          sectorA (extensible)
#   ISO_PASSWORD_HASH   SHA-512 crypt hash of the Ubuntu user password
#   SSH_AUTHORIZED_KEY  full authorized_keys line (optional; if empty,
#                       SSH is enabled but no key is registered — the
#                       host is only reachable from local console until
#                       a key is added manually)
#
# After install, on first boot:
#   1. first-boot-setup.service  runs setup-docker.sh + setup-laptop.sh
#      once, drops /var/lib/first-boot-setup.done
#   2. simdd.service starts /opt/simdd/start-simdd.run as a daemon with
#      Restart=on-failure, ordered after docker.service and
#      first-boot-setup.service
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${ISO_HOSTNAME}
    realname: ${ISO_CELL_NAME}
    username: ${ISO_CELL_NAME}
    password: "${ISO_PASSWORD_HASH}"
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "${SSH_AUTHORIZED_KEY}"
  packages:
    - curl
    - ca-certificates
    - gnupg
    - lsb-release
  storage:
    layout:
      name: lvm
  late-commands:
    - cp -r /cdrom/extras /target/opt/setup
    - chmod +x /target/opt/setup/setup-docker.sh /target/opt/setup/setup-laptop.sh
    - find /target/opt/setup/phases -name '*.sh' -exec chmod +x {} +
    - mkdir -p /target/opt/simdd
    - cp -r /cdrom/extras/simdd/. /target/opt/simdd/
    - chmod +x /target/opt/simdd/start-simdd.run /target/opt/simdd/view-head.run /target/opt/simdd/find_camera.sh
    - sed -i "s/^SIMDD_CELL_ID=.*/SIMDD_CELL_ID=${ISO_CELL_ID}/" /target/opt/simdd/simdd_config.txt
    - sed -i "s/^SIMDD_SECTOR=.*/SIMDD_SECTOR=${ISO_SECTOR}/"   /target/opt/simdd/simdd_config.txt
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

- [ ] **Step 2: YAML sanity-check the template**

`envsubst` placeholders aren't valid YAML on their own; render them first with stubs, then YAML-load.

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
export ISO_CELL_ID=1 ISO_CELL_NAME=Cell001 ISO_HOSTNAME=cell01 \
       ISO_SECTOR=sectorA ISO_PASSWORD_HASH='!' \
       SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA test@host'
envsubst '${ISO_CELL_ID} ${ISO_CELL_NAME} ${ISO_HOSTNAME} ${ISO_SECTOR} ${ISO_PASSWORD_HASH} ${SSH_AUTHORIZED_KEY}' \
  < nocloud/user-data > /tmp/rendered-user-data
python3 -c "import sys, yaml; yaml.safe_load(open('/tmp/rendered-user-data'))" \
  && echo "[OK] rendered YAML parses"
```
Expected: `[OK] rendered YAML parses`. If python's `yaml` module is missing: `pip install pyyaml` or `apt install python3-yaml`.

- [ ] **Step 3: Confirm key fields render with the right cell values**

Run:
```bash
grep -E 'hostname:|username:|realname:|SIMDD_CELL_ID=|SIMDD_SECTOR=' /tmp/rendered-user-data
```
Expected output contains:
```
    hostname: cell01
    realname: Cell001
    username: Cell001
    - sed -i "s/^SIMDD_CELL_ID=.*/SIMDD_CELL_ID=1/" /target/opt/simdd/simdd_config.txt
    - sed -i "s/^SIMDD_SECTOR=.*/SIMDD_SECTOR=sectorA/"   /target/opt/simdd/simdd_config.txt
```

- [ ] **Step 4: Commit**

Run:
```bash
rm -f /tmp/rendered-user-data
git add nocloud/user-data
git commit -m "$(cat <<'EOF'
refactor(nocloud): make user-data a multi-cell template

Adds envsubst placeholders for cell ID, cell name, hostname, sector, and
password hash. late-commands now also stage /opt/simdd from extras, patch
SIMDD_CELL_ID/SIMDD_SECTOR in simdd_config.txt, and install/enable
simdd.service alongside first-boot-setup.service.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Update `nocloud/meta-data` for the new placeholder name

The file already uses `${ISO_HOSTNAME}` — confirm and adjust the comment / instance-id wording so it stays self-documenting.

**Files:**
- Modify: `nocloud/meta-data`

- [ ] **Step 1: Replace `nocloud/meta-data` with the cleaner template**

Overwrite with:
```
# Rendered by build-iso.sh per cell (Cell001..Cell016).
instance-id: ubuntu-autoinstall-${ISO_HOSTNAME}
local-hostname: ${ISO_HOSTNAME}
```

- [ ] **Step 2: Verify it still renders to two valid lines**

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
ISO_HOSTNAME=cell03 envsubst '${ISO_HOSTNAME}' < nocloud/meta-data
```
Expected:
```
# Rendered by build-iso.sh per cell (Cell001..Cell016).
instance-id: ubuntu-autoinstall-cell03
local-hostname: cell03
```

- [ ] **Step 3: Commit**

Run:
```bash
git add nocloud/meta-data
git commit -m "refactor(nocloud): per-cell instance-id in meta-data template

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Create `nocloud/grub-fragment.cfg.tmpl`

One GRUB menuentry per template render. `build-iso.sh` renders this 16 times and concatenates with a header.

**Files:**
- Create: `nocloud/grub-fragment.cfg.tmpl`

- [ ] **Step 1: Write the fragment template**

Create `nocloud/grub-fragment.cfg.tmpl` with:
```
menuentry "Install ${ISO_CELL_NAME} (${ISO_SECTOR})" --class ubuntu --class gnu-linux --class gnu --class os {
	set gfxpayload=keep
	linux	/casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud-cell${ISO_CELL_NUM}/ ---
	initrd	/casper/initrd
}
```

Note the tabs inside the menuentry body (GRUB tolerates spaces, but the upstream Ubuntu cfg uses tabs — we match).

- [ ] **Step 2: Confirm placeholders render**

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
ISO_CELL_NAME=Cell005 ISO_SECTOR=sectorA ISO_CELL_NUM=05 \
  envsubst '${ISO_CELL_NAME} ${ISO_SECTOR} ${ISO_CELL_NUM}' \
  < nocloud/grub-fragment.cfg.tmpl
```
Expected:
```
menuentry "Install Cell005 (sectorA)" --class ubuntu --class gnu-linux --class gnu --class os {
	set gfxpayload=keep
	linux	/casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud-cell05/ ---
	initrd	/casper/initrd
}
```

- [ ] **Step 3: Commit**

Run:
```bash
git add nocloud/grub-fragment.cfg.tmpl
git commit -m "feat(nocloud): GRUB menuentry template for per-cell datasource

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Rewrite `build-iso.sh` for the multi-cell flow

The whole script gets replaced. Big task — split into rewrite + verification sub-steps.

**Files:**
- Modify: `build-iso.sh` (~200 lines)

- [ ] **Step 1: Overwrite `build-iso.sh` with the multi-cell version**

Write exactly this content to `build-iso.sh`:

```bash
#!/usr/bin/env bash
# build-iso.sh — Build one Ubuntu 24.04 autoinstall ISO covering 16 cells
# (Cell001..Cell016) within one sector. GRUB shows 16 menu entries; each
# entry points at a different nocloud datasource so subiquity sees a
# user-data tailored to that cell (username, hostname, SIMDD_CELL_ID).
#
# Outputs:
#   build/ubuntu-24.04-multi-cell-${ISO_SECTOR}.iso
#
# Required env:
#   SIMDD_ZIP            path to the .zip containing start-simdd.run +
#                        view-head.run + find_camera.sh + simdd_config.txt
#
# Optional env:
#   ISO_SECTOR           default 'sectorA'
#   UBUNTU_PASSWORD      default '1234' (hashed locally; never sent over
#                        the network; stays out of git via build/ ignore)
#   SSH_AUTHORIZED_KEY   if empty, SSH is enabled but has no keys (host
#                        only reachable via local console until a key
#                        gets added manually). Warned, not fatal.
#   SRC_ISO              path to an already-downloaded live-server ISO
#   UBUNTU_ISO_URL       default 24.04 live-server amd64 release ISO
#   OUTPUT_ISO           override output path
#   ISO_GRUB_TIMEOUT     default 30 (seconds the menu waits)
#   ISO_GRUB_DEFAULT     default 0 (Cell001)
#
# Build host deps: xorriso, gettext-base (envsubst), curl, openssl,
# python3 (for unzipping the simdd payload; `unzip` is not in stock WSL).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck disable=SC1091
. lib/common.sh

#-----------------------------------------------------------------------------
# Config
#-----------------------------------------------------------------------------
: "${UBUNTU_ISO_URL:=https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso}"
: "${SRC_ISO:=}"
: "${ISO_SECTOR:=sectorA}"
: "${OUTPUT_ISO:=build/ubuntu-24.04-multi-cell-${ISO_SECTOR}.iso}"
: "${UBUNTU_PASSWORD:=1234}"
: "${SSH_AUTHORIZED_KEY:=}"
: "${SIMDD_ZIP:=}"
: "${ISO_GRUB_TIMEOUT:=30}"
: "${ISO_GRUB_DEFAULT:=0}"

#-----------------------------------------------------------------------------
# Preflight
#-----------------------------------------------------------------------------
for cmd in xorriso envsubst curl openssl python3; do
    command -v "${cmd}" >/dev/null \
        || die "${cmd} not found. Install with: sudo apt install xorriso gettext-base curl openssl python3"
done

[ -n "${SIMDD_ZIP}" ] || die "SIMDD_ZIP is required (path to drive-download .zip with start-simdd.run, view-head.run, find_camera.sh, simdd_config.txt)"
[ -s "${SIMDD_ZIP}" ] || die "SIMDD_ZIP not found or empty: ${SIMDD_ZIP}"

if [ -z "${SSH_AUTHORIZED_KEY}" ]; then
    warn "SSH_AUTHORIZED_KEY is empty. SSH will be installed but no keys"
    warn "registered. The host will only be reachable from local console"
    warn "until you add a key manually. Set it with:"
    warn "  SSH_AUTHORIZED_KEY=\"\$(cat ~/.ssh/id_ed25519.pub)\" ./build-iso.sh"
fi

mkdir -p build

#-----------------------------------------------------------------------------
# 1. Acquire source ISO
#-----------------------------------------------------------------------------
if [ -z "${SRC_ISO}" ]; then
    SRC_ISO="build/$(basename "${UBUNTU_ISO_URL}")"
    if [ ! -s "${SRC_ISO}" ]; then
        log "Downloading ${UBUNTU_ISO_URL}"
        curl -fL --retry 3 -o "${SRC_ISO}.part" "${UBUNTU_ISO_URL}"
        mv "${SRC_ISO}.part" "${SRC_ISO}"
    else
        ok "Reusing cached ${SRC_ISO}"
    fi
fi
[ -s "${SRC_ISO}" ] || die "Source ISO missing or empty: ${SRC_ISO}"

#-----------------------------------------------------------------------------
# 2. Hash the Ubuntu user password
#-----------------------------------------------------------------------------
log "Hashing Ubuntu user password (SHA-512 crypt)"
ISO_PASSWORD_HASH="$(openssl passwd -6 "${UBUNTU_PASSWORD}")"
[ -n "${ISO_PASSWORD_HASH}" ] || die "Password hashing failed"

#-----------------------------------------------------------------------------
# 3. Stage extras/ (setup scripts + simdd payload)
#-----------------------------------------------------------------------------
log "Staging extras/ from repo + simdd payload from ${SIMDD_ZIP}"
rm -rf build/extras
mkdir -p build/extras
cp setup-docker.sh setup-laptop.sh build/extras/
cp -r lib phases build/extras/
chmod +x build/extras/*.sh build/extras/phases/*.sh

mkdir -p build/extras/simdd
python3 - "${SIMDD_ZIP}" build/extras/simdd <<'PY'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
expected = {"start-simdd.run", "view-head.run", "find_camera.sh", "simdd_config.txt"}
with zipfile.ZipFile(src) as z:
    names = set(z.namelist())
    missing = expected - names
    if missing:
        sys.exit(f"simdd zip is missing expected files: {sorted(missing)}")
    z.extractall(dst)
print(f"Extracted {len(expected)} files to {dst}")
PY
chmod +x build/extras/simdd/*.run build/extras/simdd/*.sh

#-----------------------------------------------------------------------------
# 4. Render 16 per-cell nocloud directories
#-----------------------------------------------------------------------------
log "Rendering 16 per-cell nocloud datasources"
SUBST_VARS='${ISO_CELL_ID} ${ISO_CELL_NAME} ${ISO_HOSTNAME} ${ISO_SECTOR} ${ISO_PASSWORD_HASH} ${SSH_AUTHORIZED_KEY}'
export ISO_SECTOR ISO_PASSWORD_HASH SSH_AUTHORIZED_KEY

for i in $(seq 1 16); do
    cell_id="$i"
    cell_num="$(printf '%02d' "$i")"
    cell_name="$(printf 'Cell%03d' "$i")"
    hostname="cell${cell_num}"

    out="build/nocloud-cell${cell_num}"
    rm -rf "$out"
    mkdir -p "$out"

    ISO_CELL_ID="$cell_id" ISO_CELL_NAME="$cell_name" ISO_HOSTNAME="$hostname" \
        envsubst "${SUBST_VARS}" < nocloud/user-data > "$out/user-data"
    ISO_HOSTNAME="$hostname" \
        envsubst '${ISO_HOSTNAME}' < nocloud/meta-data > "$out/meta-data"
done

# Sanity: confirm no leftover placeholders.
if grep -RnE '\$\{(ISO_[A-Z_]+|SSH_AUTHORIZED_KEY)\}' build/nocloud-cell* >/dev/null; then
    die "Leftover \${...} placeholders detected in rendered nocloud dirs"
fi

#-----------------------------------------------------------------------------
# 5. Render the 16-entry GRUB cfg
#-----------------------------------------------------------------------------
log "Generating 16-entry GRUB cfg"
rm -rf build/grub
mkdir -p build/grub

{
    printf 'set timeout=%s\n'           "${ISO_GRUB_TIMEOUT}"
    printf 'set default=%s\n'           "${ISO_GRUB_DEFAULT}"
    printf 'loadfont unicode\n'
    printf 'set menu_color_normal=white/black\n'
    printf 'set menu_color_highlight=black/light-gray\n\n'
} > build/grub/grub.cfg

for i in $(seq 1 16); do
    cell_num="$(printf '%02d' "$i")"
    cell_name="$(printf 'Cell%03d' "$i")"
    ISO_CELL_NUM="$cell_num" ISO_CELL_NAME="$cell_name" ISO_SECTOR="$ISO_SECTOR" \
        envsubst '${ISO_CELL_NUM} ${ISO_CELL_NAME} ${ISO_SECTOR}' \
        < nocloud/grub-fragment.cfg.tmpl >> build/grub/grub.cfg
    printf '\n' >> build/grub/grub.cfg
done

# loopback.cfg mirrors grub.cfg for tools that boot the ISO as loopback.
cp build/grub/grub.cfg build/grub/loopback.cfg

#-----------------------------------------------------------------------------
# 6. Repackage ISO
#-----------------------------------------------------------------------------
log "Building ${OUTPUT_ISO}"
mkdir -p "$(dirname "${OUTPUT_ISO}")"
rm -f "${OUTPUT_ISO}"

XORRISO_ARGS=(
    -indev  "${SRC_ISO}"
    -outdev "${OUTPUT_ISO}"
    -boot_image any replay
    -volid  "Ubuntu-${ISO_SECTOR}-MultiCell"
    -compliance no_emul_toc
    -overwrite on
    -pathspecs on
    -map build/extras  /extras
    -map build/grub/grub.cfg     /boot/grub/grub.cfg
    -map build/grub/loopback.cfg /boot/grub/loopback.cfg
)
for i in $(seq 1 16); do
    cell_num="$(printf '%02d' "$i")"
    XORRISO_ARGS+=(-map "build/nocloud-cell${cell_num}" "/nocloud-cell${cell_num}")
done

xorriso "${XORRISO_ARGS[@]}"

ok "Built: ${OUTPUT_ISO}"
log "Burn to USB:"
log "  Linux:   sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress conv=fsync"
log "  Windows: Rufus / Balena Etcher in 'DD image' mode"
log ""
log "GRUB will show 16 entries (Install Cell001..Cell016, sector ${ISO_SECTOR})."
log "Default entry is index ${ISO_GRUB_DEFAULT}, timeout ${ISO_GRUB_TIMEOUT}s."
log "Each cell's first boot will run setup-docker.sh + setup-laptop.sh, then"
log "start simdd.service. SSH as e.g. Cell003@<host-ip>."
```

- [ ] **Step 2: Ensure executable bit and syntax-check**

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
chmod +x build-iso.sh
bash -n build-iso.sh && echo "[OK] syntax"
```
Expected: `[OK] syntax`.

- [ ] **Step 3: Preflight smoke — missing SIMDD_ZIP**

Run:
```bash
./build-iso.sh 2>&1 | head -3
```
Expected (exit non-zero, message includes the required-env hint):
```
[x] SIMDD_ZIP is required (path to drive-download .zip with start-simdd.run, view-head.run, find_camera.sh, simdd_config.txt)
```

- [ ] **Step 4: Preflight smoke — password hashing works**

Run:
```bash
openssl passwd -6 1234 | head -1
```
Expected: a line starting with `$6$...` (SHA-512 crypt). This validates the build host has the right openssl.

- [ ] **Step 5: Per-cell render smoke (no ISO build yet)**

We'll run the rendering portion in isolation by setting `SIMDD_ZIP=/dev/null` first to confirm preflight stops there, then by extracting just the loop logic.

Run (preflight check should stop us before download):
```bash
SIMDD_ZIP=/dev/null ./build-iso.sh 2>&1 | head -3
```
Expected:
```
[x] SIMDD_ZIP not found or empty: /dev/null
```

- [ ] **Step 6: Commit**

Run:
```bash
git add build-iso.sh
git commit -m "$(cat <<'EOF'
feat(build-iso): multi-cell ISO builder (Cell001..Cell016)

Loops 1..16 to render per-cell nocloud datasources and a 16-entry GRUB
menu. Hashes the Ubuntu user password locally via openssl passwd -6.
Extracts simdd payload from SIMDD_ZIP and stages it under
extras/simdd/. xorriso reads the original ISO and writes a multi-cell
output, preserving hybrid boot via -boot_image any replay.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: End-to-end render smoke test (no actual ISO write)

We want one command that exercises everything up to (and not including) the xorriso repackaging step, against a real simdd.zip. Run this from a shell that has openssl + envsubst + python3 + the zip file accessible.

**Files:**
- No file changes; verification only.

- [ ] **Step 1: Acquire the simdd zip path**

Run:
```bash
ls -lh /mnt/c/Users/jjoon/Downloads/drive-download-20260519T075900Z-3-001.zip
```
Expected: ~832 MB file is listed. If it isn't there, copy it from wherever the operator stored it.

- [ ] **Step 2: Drive the build up to the xorriso step**

We don't have a "render-only" flag in the script (YAGNI), so the cleanest smoke is to set `SRC_ISO=/dev/null` after the staging/rendering work. The script will fail at xorriso, but we'll have inspected the rendered tree before that.

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
SIMDD_ZIP=/mnt/c/Users/jjoon/Downloads/drive-download-20260519T075900Z-3-001.zip \
SRC_ISO=/dev/null \
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA test@host" \
./build-iso.sh 2>&1 | tail -20
```
Expected: progress through "Staging extras/", "Extracted 4 files to build/extras/simdd", "Rendering 16 per-cell nocloud datasources", "Generating 16-entry GRUB cfg", then a xorriso failure at the very end (because `/dev/null` isn't a real ISO). The render artifacts in `build/` are what we want.

- [ ] **Step 3: Verify 16 nocloud dirs differ only in 3 lines each**

Run:
```bash
ls build/nocloud-cell*/user-data | wc -l   # → 16
diff build/nocloud-cell01/user-data build/nocloud-cell02/user-data
```
Expected: count is `16`; diff shows changes ONLY on the lines containing `hostname:`, `realname:`/`username:`, the `SIMDD_CELL_ID=N` sed, and the `instance-id` (in meta-data). No other diffs.

- [ ] **Step 4: Verify 16 GRUB entries**

Run:
```bash
grep -c '^menuentry ' build/grub/grub.cfg
```
Expected: `16`.

Run:
```bash
grep -E 'menuentry|s=/cdrom/nocloud-cell' build/grub/grub.cfg | head -6
```
Expected (first two cells shown; rest follows):
```
menuentry "Install Cell001 (sectorA)" --class ubuntu --class gnu-linux --class gnu --class os {
	linux	/casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud-cell01/ ---
menuentry "Install Cell002 (sectorA)" --class ubuntu --class gnu-linux --class gnu --class os {
	linux	/casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud-cell02/ ---
menuentry "Install Cell003 (sectorA)" --class ubuntu --class gnu-linux --class gnu --class os {
	linux	/casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud-cell03/ ---
```

- [ ] **Step 5: Verify no leftover placeholders anywhere under build/**

Run:
```bash
grep -RnE '\$\{(ISO_[A-Z_]+|SSH_AUTHORIZED_KEY)\}' build/nocloud-cell* build/grub/ \
    && echo "[FAIL] leftover placeholders" \
    || echo "[OK] all placeholders rendered"
```
Expected: `[OK] all placeholders rendered`.

- [ ] **Step 6: Verify simdd payload structure**

Run:
```bash
ls build/extras/simdd/
file build/extras/simdd/start-simdd.run | head -1
```
Expected: 4 files (`start-simdd.run`, `view-head.run`, `find_camera.sh`, `simdd_config.txt`); the `.run` is reported as a self-extracting or shell wrapper.

- [ ] **Step 7: Verify password got hashed and embedded**

Run:
```bash
grep -E '^    password:' build/nocloud-cell01/user-data
```
Expected: a line like `    password: "$6$<salt>$<hash>"` (NOT literal `1234`, NOT empty, NOT `${ISO_PASSWORD_HASH}`).

- [ ] **Step 8: Commit a note (no code change)**

There's nothing to commit yet from this task — it's pure verification. Skip the commit; move on to Task 6.

---

## Task 6: Update `README.md` Option D to describe the multi-cell flow

**Files:**
- Modify: `README.md` (replace the existing "Option D — Single-USB autoinstall ISO" subsection)

- [ ] **Step 1: Locate the current Option D block**

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
grep -n '^### Option D' README.md
```
Expected: one match, e.g. `145:### Option D — Single-USB autoinstall ISO (zero-touch install)`.

- [ ] **Step 2: Replace the Option D block**

Open `README.md` and find the section that starts with `### Option D — Single-USB autoinstall ISO (zero-touch install)` and ends right before `### Order on a fresh box`. Replace the entire block with:

```markdown
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

For sector expansion, re-run with a different `ISO_SECTOR` to produce a
second ISO. Design rationale and per-cell layout in
[`docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md`](./docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md).
```

- [ ] **Step 3: Verify the section reads correctly**

Run:
```bash
sed -n '/^### Option D/,/^### Order on a fresh box/p' README.md | head -40
```
Expected: only the new multi-cell block is shown above the "Order on a fresh box" header. No mention of the old single-cell `ISO_USERNAME`/`ISO_HOSTNAME` envs in this section.

- [ ] **Step 4: Commit**

Run:
```bash
git add README.md
git commit -m "docs(readme): describe multi-cell Option D flow

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Update `docs/usb-install.md` to point at the multi-cell layout

**Files:**
- Modify: `docs/usb-install.md`

- [ ] **Step 1: Find the existing "What ships in this repo" subsection**

Run:
```bash
grep -n '^### What ships in this repo' /mnt/c/Users/jjoon/sh-test/docs/usb-install.md
```
Expected: one match.

- [ ] **Step 2: Append a new subsection after that one**

Insert this block immediately after the existing "What ships in this repo" subsection (and before the existing OCI-image-rejection paragraph if any):

```markdown
### Multi-cell layout (current default)

`build-iso.sh` produces a single ISO that installs any of Cell001..Cell016
in one sector. The ISO contains 16 GRUB menu entries, each pointing at a
distinct `/cdrom/nocloud-cellNN/` datasource. Per-cell deltas in user-data:
`hostname`, `username`, `realname`, and the `SIMDD_CELL_ID` sed-patch
inside `late-commands`. Everything else (Ubuntu password, sector, SSH key,
simdd payload, setup scripts) is constant across the 16 entries.

Full design rationale (including the explicit non-goals and the rejected
alternatives — `e`-key cmdline edit, cloud-init Jinja, MAC auto-detect):
[`../superpowers/specs/2026-05-20-multi-cell-usb-design.md`](../superpowers/specs/2026-05-20-multi-cell-usb-design.md).

Implementation plan that produced the current state:
[`../superpowers/plans/2026-05-20-multi-cell-usb-autoinstall.md`](../superpowers/plans/2026-05-20-multi-cell-usb-autoinstall.md).
```

- [ ] **Step 3: Verify**

Run:
```bash
grep -n -A2 '^### Multi-cell layout' /mnt/c/Users/jjoon/sh-test/docs/usb-install.md
```
Expected: the new heading and the first two lines of the new block.

- [ ] **Step 4: Commit**

Run:
```bash
git add docs/usb-install.md
git commit -m "docs(usb-install): point at multi-cell spec + plan

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Final verification + manual smoke-build instructions

This task does NOT run the full ISO build (it's a 3+ GB output that needs xorriso to grind for a few minutes). It documents the exact command the operator runs once everything else is green.

**Files:**
- No file changes.

- [ ] **Step 1: Final git log sanity**

Run:
```bash
cd /mnt/c/Users/jjoon/sh-test
git log --oneline -10
git status --short
```
Expected: 8-ish new commits stacked on `197903c` (spec) and `40396cf` (last merge). `git status` clean.

- [ ] **Step 2: Document the operator command (no commit)**

The full build, when the operator is ready:
```bash
sudo apt install xorriso gettext-base curl openssl python3
cd /path/to/sh-test
SSH_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
SIMDD_ZIP=/mnt/c/Users/jjoon/Downloads/drive-download-20260519T075900Z-3-001.zip \
./build-iso.sh
ls -lh build/ubuntu-24.04-multi-cell-sectorA.iso
```
Expected outcome: an ISO of roughly `live-server-iso-size + 832 MB ≈ 3.3 GB`. Burn with `dd` or Rufus (DD-image mode).

- [ ] **Step 3: One real-hardware canary boot (Cell 001)**

Document the verification checklist the operator runs on the first cell after first-boot completes (NO commit; this is operational instruction, not code):

1. `hostnamectl` → `Static hostname: cell01`
2. `id Cell001` → uid/gid for Cell001 returned
3. `cat /opt/simdd/simdd_config.txt | grep SIMDD_CELL_ID` → `SIMDD_CELL_ID=1`
4. `systemctl is-active first-boot-setup.service` → `inactive` (oneshot, already done)
5. `ls /var/lib/first-boot-setup.done` → file exists
6. `systemctl is-active simdd.service` → `active`
7. `journalctl -u simdd --no-pager -n 50` → no rapid restart loop
8. `cat /sys/class/power_supply/BAT*/charge_control_end_threshold` → `80` (Phase 03)
9. `systemctl is-enabled tlp` → `enabled` (Phase 04)
10. `grep live-restore /etc/docker/daemon.json` → `"live-restore": true` (Phase 01)

If step 6 fails because `start-simdd.run` is a one-shot installer (not a daemon), follow up by switching `simdd.service` to `Type=oneshot` in `nocloud/user-data` and rebuilding. See spec §10 open questions.

---

## Self-review

**Spec coverage check** (against `docs/superpowers/specs/2026-05-20-multi-cell-usb-design.md`):

| Spec section | Plan task(s) |
|--------------|-------------|
| §4 D1 — 16 GRUB entries | Tasks 3, 4 (step 1 GRUB loop), 5 (step 4 verify count=16) |
| §4 D2 — distinct nocloud paths | Tasks 3 (template), 4 (step 1 loop body), 5 (step 4 verify s=/cdrom/nocloud-cellNN/) |
| §4 D3 — per-cell username/hostname/CELL_ID | Task 1 (template variables), Task 4 (render loop), Task 5 step 3 (diff verify) |
| §4 D4 — password=1234 + SSH key-only | Task 1 (template), Task 4 step 1 (openssl passwd -6, warn-not-die on empty SSH key), Task 5 step 7 |
| §4 D5 — first-boot-setup runs both setup scripts | Task 1 (embedded systemd unit) |
| §4 D6 — simdd.service separate, Restart=on-failure | Task 1 (embedded systemd unit) |
| §4 D7 — ISO_SECTOR baked at build time | Task 4 (env var with default, propagated into both template renders and GRUB title) |
| §5.1 ISO layout | Task 4 step 1 xorriso -map directives |
| §8 Failure modes — `.run` is one-shot | Task 8 step 3 documents the fallback (switch to Type=oneshot) |
| §9 Testing — unit + integration | Tasks 4 (syntax), 5 (render smoke), 8 (manual hardware checklist) |

No gaps.

**Placeholder scan:** searched for TBD/TODO/"implement later"/"similar to" — none present in this plan.

**Type consistency:** envsubst variable names (`ISO_CELL_ID`, `ISO_CELL_NAME`, `ISO_HOSTNAME`, `ISO_SECTOR`, `ISO_PASSWORD_HASH`, `SSH_AUTHORIZED_KEY`) and the GRUB-only `ISO_CELL_NUM` (zero-padded 2 digits) are used identically in Task 1, Task 3, Task 4, and Task 5. systemd unit names (`first-boot-setup.service`, `simdd.service`) and sentinel path (`/var/lib/first-boot-setup.done`) match the spec.
