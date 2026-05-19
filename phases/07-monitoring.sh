#!/usr/bin/env bash
# Phase 07: Monitoring tooling baseline.
#
# Installs lm-sensors and smartmontools and emits a one-shot snapshot to
# /var/log/laptop-baseline.txt — useful as a "day 0" reference to diff
# against after weeks of 9h/day operation.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

PKGS=(lm-sensors smartmontools)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    log "Installing: ${MISSING[*]}"
    run apt-get update -y
    run apt-get install -y "${MISSING[@]}"
else
    ok "All monitoring packages already installed."
fi

# lm-sensors first-run detection (interactive prompts disabled).
if [ ! -e /etc/sensors3.conf ] && [ ! -d /etc/sensors.d ]; then
    log "Running sensors-detect --auto..."
    run sensors-detect --auto >/dev/null || true
fi

BASELINE="/var/log/laptop-baseline.txt"
log "Writing baseline snapshot to ${BASELINE}..."
if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '\033[1;35m[dry-run]\033[0m would write %s\n' "$BASELINE"
else
    {
        printf '=== Baseline captured at %s ===\n' "$(date -Is)"
        printf '\n--- uname ---\n'; uname -a
        printf '\n--- DMI ---\n'
        cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null
        printf '\n--- sensors ---\n'
        sensors 2>/dev/null || echo "(sensors not yet configured)"
        printf '\n--- block devices ---\n'
        lsblk -d -o NAME,MODEL,SIZE,ROTA,TRAN
        printf '\n--- SMART summary ---\n'
        for dev in /dev/nvme?n? /dev/sd? ; do
            [ -e "$dev" ] || continue
            printf '\n# %s\n' "$dev"
            smartctl -a "$dev" 2>/dev/null \
              | grep -E 'Model Number|Serial Number|Firmware|Percentage Used|Available Spare|Temperature|Power_On_Hours|Wear_Leveling_Count' \
              || true
        done
    } > "$BASELINE"
fi

ok "phase 07-monitoring done."
echo "    Re-snapshot anytime with: sudo bash ${PHASE_DIR}/07-monitoring.sh"
