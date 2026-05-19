#!/usr/bin/env bash
# Phase 03: Battery charge threshold (laptop only).
#
# For "always plugged in" laptops, cap the charge ceiling at ~80% to slow
# calendar-aging of the lithium pack. Implemented via the standard
# /sys/class/power_supply/BAT*/charge_control_end_threshold interface
# (works on Dell, ThinkPad, ASUS, etc. when the kernel driver exposes it).
#
# Skipped if no battery is present (desktop, server, hypervisor).
#
# NOTE: If you configured Dell BIOS "Primarily AC Use" mode, the firmware
# already manages this at 50-55%. Don't also run this — pick one. This script
# only writes to sysfs, never touches firmware.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

CHARGE_LIMIT="${CHARGE_LIMIT:-80}"
UNIT="/etc/systemd/system/battery-charge-threshold.service"

if ! has_battery; then
    ok "No battery detected; skipping battery threshold setup."
    exit 0
fi

BAT="$(battery_path)"
log "Battery detected at ${BAT}"

THRESH_FILE="${BAT}/charge_control_end_threshold"
if [ ! -w "$THRESH_FILE" ] && [ ! -e "$THRESH_FILE" ]; then
    warn "${THRESH_FILE} missing — kernel driver does not expose charge limit."
    warn "Check BIOS-level options (e.g. Dell Power Manager 'Primarily AC Use')."
    exit 0
fi

# Validate the requested limit.
case "$CHARGE_LIMIT" in
    ''|*[!0-9]*) die "CHARGE_LIMIT must be an integer, got: ${CHARGE_LIMIT}" ;;
esac
if [ "$CHARGE_LIMIT" -lt 50 ] || [ "$CHARGE_LIMIT" -gt 100 ]; then
    die "CHARGE_LIMIT out of sane range [50,100]: ${CHARGE_LIMIT}"
fi

log "Applying charge ceiling = ${CHARGE_LIMIT}% (current: $(cat "$THRESH_FILE" 2>/dev/null || echo ?))"
run bash -c "echo ${CHARGE_LIMIT} > '${THRESH_FILE}'"

# Persist across reboots via systemd. Globbing inside the unit makes it work
# for BAT0 / BAT1 / BATC etc. without hardcoding.
write_file "$UNIT" <<EOF
[Unit]
Description=Set battery charge threshold to ${CHARGE_LIMIT}%
After=multi-user.target
StartLimitBurst=0

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
ExecStart=/bin/bash -c 'for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do [ -w "\$f" ] && echo ${CHARGE_LIMIT} > "\$f"; done'

[Install]
WantedBy=multi-user.target
EOF

enable_now battery-charge-threshold.service

ok "phase 03-battery done. Verify: cat ${THRESH_FILE}"
