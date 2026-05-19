#!/usr/bin/env bash
# Phase 01: Docker daemon hardening for always-on hosts.
#
# - Configures /etc/docker/daemon.json with bounded json-file logs and
#   live-restore so dockerd restarts (e.g. apt upgrade) don't kill containers.
# - Installs a daily `docker system prune` cron job to keep disk in check.
#
# Idempotent: re-running this script is safe. The daemon.json values can be
# overridden via env vars.

set -euo pipefail
PHASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${PHASE_DIR}/../lib/common.sh"

require_root "$@"

# --- Tunables ----------------------------------------------------------------
DOCKER_LOG_MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-20m}"   # per container log file
DOCKER_LOG_MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"     # rotated files retained
DOCKER_PRUNE_UNTIL="${DOCKER_PRUNE_UNTIL:-72h}"     # min idle age to prune
DOCKER_PRUNE_HOUR="${DOCKER_PRUNE_HOUR:-4}"         # cron hour (0-23)

# --- daemon.json -------------------------------------------------------------
DAEMON_JSON="/etc/docker/daemon.json"

if ! command -v docker >/dev/null 2>&1; then
    warn "docker not installed; skipping daemon.json (run setup-docker.sh first)."
else
    log "Configuring ${DAEMON_JSON} (log rotation + live-restore)..."

    if [ -e "$DAEMON_JSON" ]; then
        if command -v jq >/dev/null 2>&1; then
            # Merge into existing config — preserve unrelated keys.
            backup_once "$DAEMON_JSON"
            tmp="$(mktemp)"
            jq \
                --arg max_size "$DOCKER_LOG_MAX_SIZE" \
                --arg max_file "$DOCKER_LOG_MAX_FILE" \
                '. + {
                    "log-driver": "json-file",
                    "log-opts": ((."log-opts" // {}) + {
                        "max-size": $max_size,
                        "max-file": $max_file
                    }),
                    "live-restore": true
                }' "$DAEMON_JSON" >"$tmp"
            if cmp -s "$tmp" "$DAEMON_JSON"; then
                ok "daemon.json already up to date"
                rm -f "$tmp"
            else
                if [ "${DRY_RUN:-0}" = "1" ]; then
                    printf '\033[1;35m[dry-run]\033[0m would update %s:\n' "$DAEMON_JSON"
                    sed 's/^/    /' "$tmp"
                    rm -f "$tmp"
                else
                    install -D -m 0644 "$tmp" "$DAEMON_JSON"
                    rm -f "$tmp"
                    log "updated $DAEMON_JSON"
                    NEED_RESTART=1
                fi
            fi
        else
            warn "jq missing — installing for safe daemon.json merge"
            run apt-get update -y
            run apt-get install -y jq
            # Re-exec into the same script so jq path becomes effective.
            exec bash "$0" "$@"
        fi
    else
        write_file "$DAEMON_JSON" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE}",
    "max-file": "${DOCKER_LOG_MAX_FILE}"
  },
  "live-restore": true
}
EOF
        NEED_RESTART=1
    fi

    if [ "${NEED_RESTART:-0}" = "1" ]; then
        log "Restarting dockerd to apply new daemon.json..."
        run systemctl restart docker
    fi
fi

# --- Daily prune cron --------------------------------------------------------
PRUNE_CRON="/etc/cron.d/docker-prune"
log "Installing daily docker prune cron at ${PRUNE_CRON} (until=${DOCKER_PRUNE_UNTIL})..."

write_file "$PRUNE_CRON" <<EOF
# Managed by setup-laptop.sh (phase 01-docker-hardening)
# Prune unused images/networks/build cache older than ${DOCKER_PRUNE_UNTIL}.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 ${DOCKER_PRUNE_HOUR} * * * root /usr/bin/docker system prune -af --filter "until=${DOCKER_PRUNE_UNTIL}" >>/var/log/docker-prune.log 2>&1
EOF
run chmod 0644 "$PRUNE_CRON"

ok "phase 01-docker-hardening done."
