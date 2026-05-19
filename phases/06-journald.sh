#!/usr/bin/env bash
# Phase 06: Cap journald disk usage.
#
# Chatty containers + 9h/day uptime can easily push /var/log past 10GB if
# journald is left at defaults. Cap SystemMaxUse to keep disk pressure
# bounded; honor SystemKeepFree as a hard safety margin.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-2G}"
JOURNAL_KEEP_FREE="${JOURNAL_KEEP_FREE:-10G}"
JOURNAL_RETENTION="${JOURNAL_RETENTION:-2week}"

JCONF="/etc/systemd/journald.conf.d/99-laptop-always-on.conf"

write_file "$JCONF" <<EOF
# Managed by setup-laptop.sh (phase 06-journald).
[Journal]
SystemMaxUse=${JOURNAL_MAX_USE}
SystemKeepFree=${JOURNAL_KEEP_FREE}
MaxRetentionSec=${JOURNAL_RETENTION}
Compress=yes
ForwardToSyslog=no
EOF

log "Restarting systemd-journald..."
run systemctl restart systemd-journald

ok "phase 06-journald done. Current disk use:"
journalctl --disk-usage 2>/dev/null || true
