#!/usr/bin/env bash
# Phase 04: TLP power management (laptop only).
#
# Replaces power-profiles-daemon with TLP, which has much finer-grained
# AC-vs-battery tuning. Drops a small override at
# /etc/tlp.d/99-laptop-always-on.conf so future TLP package upgrades do not
# clobber our settings.
#
# IMPORTANT: TLP's own START_CHARGE_THRESH_BAT0 / STOP_CHARGE_THRESH_BAT0
# would fight phase 03-battery's systemd unit. We leave them out here. If you
# prefer TLP-managed charge thresholds, disable phase 03 with --skip 03.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

if ! is_laptop; then
    ok "Not a laptop; skipping TLP install."
    exit 0
fi

# --- Switch from power-profiles-daemon to TLP --------------------------------
if systemctl is-active --quiet power-profiles-daemon; then
    log "Disabling power-profiles-daemon (conflicts with TLP)..."
    disable_now power-profiles-daemon
fi

if ! dpkg -s tlp >/dev/null 2>&1; then
    log "Installing TLP + tlp-rdw..."
    run apt-get update -y
    run apt-get install -y tlp tlp-rdw
fi

# --- Drop our override into /etc/tlp.d ---------------------------------------
TLP_OVR="/etc/tlp.d/99-laptop-always-on.conf"
log "Writing TLP override at ${TLP_OVR}..."

write_file "$TLP_OVR" <<'EOF'
# Managed by setup-laptop.sh (phase 04-tlp).
# Tuned for an always-plugged-in laptop running Docker ~9h/day.
#
# Charge thresholds are intentionally NOT set here — phase 03-battery owns
# the sysfs charge ceiling. If you'd rather have TLP manage charging,
# uncomment START_/STOP_CHARGE_THRESH_BAT0 below and skip phase 03.

# CPU governor / EPP
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power

# Allow turbo on AC, suppress on battery
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=0

# Platform profile (Dell / Lenovo firmware hint)
PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power

# Disk runtime power management (AC keeps things snappy for Docker)
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"

# Optional charge thresholds (commented out — phase 03 owns this).
# START_CHARGE_THRESH_BAT0=70
# STOP_CHARGE_THRESH_BAT0=80
EOF

enable_now tlp.service

# --- Sanity: tlp-stat is the source of truth ---------------------------------
if command -v tlp-stat >/dev/null 2>&1; then
    log "TLP active mode summary:"
    tlp-stat -s 2>/dev/null | sed -n '1,20p' || true
fi

ok "phase 04-tlp done."
