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
#   ISO_GRUB_TIMEOUT     default -1 (wait indefinitely — operator must
#                        pick a cell every time; no auto-default). Set to
#                        a positive integer to allow auto-default.
#   ISO_GRUB_DEFAULT     default 0 (Cell001). Only relevant when
#                        ISO_GRUB_TIMEOUT is positive.
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
: "${ISO_GRUB_TIMEOUT:=-1}"
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
ISO_PASSWORD_HASH="$(printf '%s\n' "${UBUNTU_PASSWORD}" | openssl passwd -6 -stdin)"
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
    flat_names = {os.path.basename(n) for n in z.namelist() if not n.endswith('/')}
    missing = expected - flat_names
    if missing:
        sys.exit(f"simdd zip is missing expected files: {sorted(missing)}")
    for member in z.infolist():
        base = os.path.basename(member.filename)
        if not base:
            continue
        member.filename = base
        z.extract(member, dst)
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

# When SSH_AUTHORIZED_KEY was empty, the rendered authorized-keys list
# contains a single empty string. subiquity rejects an empty key, so
# replace it with an empty list to keep the YAML valid.
if [ -z "${SSH_AUTHORIZED_KEY}" ]; then
    for f in build/nocloud-cell*/user-data; do
        sed -i 's/^    authorized-keys:$/    authorized-keys: []/' "$f"
        sed -i '/^      - ""$/d' "$f"
    done
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
if [ "${ISO_GRUB_TIMEOUT}" = "-1" ]; then
    log "GRUB will wait indefinitely — operator must explicitly pick a cell."
else
    log "Default entry is index ${ISO_GRUB_DEFAULT}, timeout ${ISO_GRUB_TIMEOUT}s."
fi
log "Each cell's first boot will run setup-docker.sh + setup-laptop.sh, then"
log "start simdd.service. SSH as e.g. Cell003@<host-ip>."
