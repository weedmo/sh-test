#!/usr/bin/env bash
# Phase 02: Thermal management.
#
# Intel: enable thermald (DPTF-based throttling helps avoid 95C spikes).
# AMD:   disable thermald (no-op on AMD, only causes confusion).
#
# Also prints the current cpufreq driver/governor so you can confirm
# amd-pstate-epp (AMD) or intel_pstate (Intel) is active.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

VENDOR="$(cpu_vendor)"
log "Detected CPU vendor: ${VENDOR}"

# --- thermald ----------------------------------------------------------------
if is_intel; then
    if ! dpkg -s thermald >/dev/null 2>&1; then
        log "Installing thermald (Intel host)..."
        run apt-get update -y
        run apt-get install -y thermald
    fi
    log "Enabling thermald..."
    enable_now thermald
elif is_amd; then
    if systemctl is-enabled thermald >/dev/null 2>&1; then
        log "AMD host: disabling thermald (no-op on AMD)..."
        disable_now thermald
    else
        ok "AMD host: thermald already disabled."
    fi
else
    warn "Unknown CPU vendor (${VENDOR}); skipping thermald tuning."
fi

# --- cpufreq governor sanity check ------------------------------------------
DRIVER="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo unknown)"
GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
log "cpufreq driver=${DRIVER} governor=${GOV}"

if is_laptop; then
    # On laptops, powersave + the *_pstate driver is the sane default.
    case "$DRIVER" in
        intel_pstate|amd-pstate*|acpi-cpufreq)
            if [ "$GOV" != "powersave" ] && [ "$GOV" != "schedutil" ]; then
                warn "Laptop with governor=${GOV}; switching cpu*/scaling_governor -> powersave"
                for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                    [ -w "$g" ] || continue
                    run bash -c "echo powersave > '$g'"
                done
            else
                ok "Governor already sane for laptop: ${GOV}"
            fi
            ;;
        *)
            warn "Unrecognised cpufreq driver (${DRIVER}); leaving governor alone."
            ;;
    esac
else
    ok "Desktop host: leaving governor as-is (${GOV})."
fi

# --- Optional: install lm-sensors for visibility -----------------------------
if ! command -v sensors >/dev/null 2>&1; then
    log "Installing lm-sensors for temperature visibility..."
    run apt-get install -y lm-sensors
fi

ok "phase 02-thermal done."
