#!/usr/bin/env bash
# build-iso.sh — Build a single-USB Ubuntu 24.04 autoinstall ISO that bundles
# the setup scripts so a fresh laptop comes up with Docker + tuning applied.
#
# Outputs:
#   build/ubuntu-24.04-autoinstall.iso   (override via OUTPUT_ISO)
#
# Usage:
#   SSH_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
#   ISO_USERNAME=tommoro ISO_HOSTNAME=lab01 \
#   ./build-iso.sh
#
# Required env:
#   SSH_AUTHORIZED_KEY     Full authorized_keys line for the initial account.
#
# Optional env:
#   ISO_USERNAME           default 'ubuntu'
#   ISO_HOSTNAME           default 'ubuntu-laptop'
#   ISO_PASSWORD_HASH      default '!' (locked, SSH-key-only)
#   SRC_ISO                path to an already-downloaded live-server ISO
#   UBUNTU_ISO_URL         default 24.04 live-server amd64 release ISO
#   OUTPUT_ISO             default build/ubuntu-24.04-autoinstall.iso
#
# Burn the resulting ISO to a USB stick with `dd`, Rufus (DD-image mode), or
# Balena Etcher. The installer is unattended; on first boot the host runs
# setup-docker.sh + setup-laptop.sh exactly once via first-boot-setup.service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck disable=SC1091
. lib/common.sh

#-----------------------------------------------------------------------------
# Config (override via env)
#-----------------------------------------------------------------------------
: "${UBUNTU_ISO_URL:=https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso}"
: "${SRC_ISO:=}"
: "${OUTPUT_ISO:=build/ubuntu-24.04-autoinstall.iso}"
: "${ISO_HOSTNAME:=ubuntu-laptop}"
: "${ISO_USERNAME:=ubuntu}"
: "${ISO_PASSWORD_HASH:=!}"
: "${SSH_AUTHORIZED_KEY:=}"

#-----------------------------------------------------------------------------
# Preflight
#-----------------------------------------------------------------------------
if [ -z "${SSH_AUTHORIZED_KEY}" ]; then
    die "SSH_AUTHORIZED_KEY is required (the built ISO is SSH-key-only).
   Example:
     SSH_AUTHORIZED_KEY=\"\$(cat ~/.ssh/id_ed25519.pub)\" ./build-iso.sh"
fi

for cmd in xorriso envsubst curl; do
    command -v "${cmd}" >/dev/null \
        || die "${cmd} not found. Install with: sudo apt install xorriso gettext-base curl"
done

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
# 2. Stage extras/ (setup scripts copied verbatim into /cdrom/extras)
#-----------------------------------------------------------------------------
log "Staging extras/ from repo"
rm -rf build/extras
mkdir -p build/extras
cp setup-docker.sh setup-laptop.sh build/extras/
cp -r lib phases build/extras/
chmod +x build/extras/*.sh build/extras/phases/*.sh

#-----------------------------------------------------------------------------
# 3. Render nocloud/ via envsubst
#-----------------------------------------------------------------------------
log "Rendering nocloud/ (hostname=${ISO_HOSTNAME} username=${ISO_USERNAME})"
rm -rf build/nocloud
mkdir -p build/nocloud
SUBST_VARS='${ISO_HOSTNAME} ${ISO_USERNAME} ${ISO_PASSWORD_HASH} ${SSH_AUTHORIZED_KEY}'
export ISO_HOSTNAME ISO_USERNAME ISO_PASSWORD_HASH SSH_AUTHORIZED_KEY
envsubst "${SUBST_VARS}" < nocloud/user-data > build/nocloud/user-data
envsubst "${SUBST_VARS}" < nocloud/meta-data > build/nocloud/meta-data

#-----------------------------------------------------------------------------
# 4. Extract + patch GRUB / loopback cmdline with autoinstall args
#-----------------------------------------------------------------------------
log "Extracting boot configs from source ISO"
rm -rf build/grub
mkdir -p build/grub
# Each extract runs in its own xorriso invocation: if the ISO lacks one of
# the optional files (loopback.cfg in some spins), we still proceed.
xorriso -osirrox on -indev "${SRC_ISO}" \
    -extract /boot/grub/grub.cfg     build/grub/grub.cfg     2>/dev/null || true
xorriso -osirrox on -indev "${SRC_ISO}" \
    -extract /boot/grub/loopback.cfg build/grub/loopback.cfg 2>/dev/null || true

[ -s build/grub/grub.cfg ] \
    || die "Could not extract /boot/grub/grub.cfg from ${SRC_ISO}.
   Is this a real Ubuntu 24.04 live-server amd64 ISO?"

# xorriso extracts files read-only; reopen for writing.
chmod u+w build/grub/*.cfg 2>/dev/null || true
for f in build/grub/grub.cfg build/grub/loopback.cfg; do
    [ -s "$f" ] || continue
    # Insert kernel cmdline args before the standard '---' separator that
    # subiquity uses. GRUB needs ';' backslash-escaped so it isn't parsed
    # as a command separator.
    sed -i 's|---|autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---|g' "$f"
    # Tighten boot-menu timeout so unattended installs proceed quickly.
    sed -i 's/^set timeout=.*/set timeout=5/' "$f"
done

#-----------------------------------------------------------------------------
# 5. Repackage ISO (preserve original boot image via -boot_image any replay)
#-----------------------------------------------------------------------------
log "Building ${OUTPUT_ISO}"
mkdir -p "$(dirname "${OUTPUT_ISO}")"
rm -f "${OUTPUT_ISO}"

XORRISO_ARGS=(
    -indev  "${SRC_ISO}"
    -outdev "${OUTPUT_ISO}"
    -boot_image any replay
    -volid  "Ubuntu-Auto-24.04"
    -compliance no_emul_toc
    -overwrite on
    -pathspecs on
    -map build/nocloud /nocloud
    -map build/extras  /extras
    -map build/grub/grub.cfg /boot/grub/grub.cfg
)
[ -s build/grub/loopback.cfg ] \
    && XORRISO_ARGS+=(-map build/grub/loopback.cfg /boot/grub/loopback.cfg)

xorriso "${XORRISO_ARGS[@]}"

ok "Built: ${OUTPUT_ISO}"
log "Burn to USB:"
log "  Linux:   sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress conv=fsync"
log "  Windows: Rufus / Balena Etcher in 'DD image' mode"
log ""
log "On first boot the host runs setup-docker.sh + setup-laptop.sh automatically."
log "Then SSH in: ssh ${ISO_USERNAME}@<host-ip>"
