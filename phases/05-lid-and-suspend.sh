#!/usr/bin/env bash
# Phase 05: Keep the box running when lid closes / never auto-suspend.
#
# For a laptop acting as a 9h/day Docker host:
#   - Closing the lid must NOT suspend (would kill containers).
#   - System-wide sleep/suspend targets are masked so nothing schedules them.
#
# IMPORTANT — physical safety: closing the lid blocks the keyboard-deck heat
# escape path. Only enable LID_BEHAVIOR=ignore if you keep the laptop on a
# stand or with the lid propped open enough for airflow. Otherwise leave the
# default (LID_BEHAVIOR=ignore-ac-suspend-bat) which only ignores the lid when
# on AC power.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

if ! is_laptop; then
    ok "Not a laptop; skipping lid/suspend tuning."
    exit 0
fi

# ignore                    : never sleep on lid close (needs cooling stand)
# ignore-ac-suspend-bat     : ignore on AC, suspend on battery (safer default)
# suspend                   : normal laptop behavior (do not use here)
LID_BEHAVIOR="${LID_BEHAVIOR:-ignore-ac-suspend-bat}"

# Whether to systemctl mask the sleep/suspend/hibernate targets.
# Set MASK_SLEEP_TARGETS=0 to skip if you sometimes want manual `systemctl suspend`.
MASK_SLEEP_TARGETS="${MASK_SLEEP_TARGETS:-1}"

LID_CONF="/etc/systemd/logind.conf.d/99-laptop-always-on.conf"

case "$LID_BEHAVIOR" in
    ignore)
        log "Lid policy: ignore (never suspend on lid close — requires cooling stand)."
        write_file "$LID_CONF" <<'EOF'
# Managed by setup-laptop.sh (phase 05-lid-and-suspend).
# WARNING: lid closed = obstructed airflow. Use a stand.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
        ;;
    ignore-ac-suspend-bat)
        log "Lid policy: ignore on AC, suspend on battery."
        write_file "$LID_CONF" <<'EOF'
# Managed by setup-laptop.sh (phase 05-lid-and-suspend).
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
        ;;
    *)
        die "Unknown LID_BEHAVIOR='${LID_BEHAVIOR}' (use: ignore | ignore-ac-suspend-bat)"
        ;;
esac

run systemctl restart systemd-logind

# --- Mask sleep targets ------------------------------------------------------
if [ "$MASK_SLEEP_TARGETS" = "1" ]; then
    log "Masking sleep / suspend / hibernate targets..."
    run systemctl mask \
        sleep.target \
        suspend.target \
        hibernate.target \
        hybrid-sleep.target
else
    ok "Sleep targets not masked (MASK_SLEEP_TARGETS=0)."
fi

ok "phase 05-lid-and-suspend done."
