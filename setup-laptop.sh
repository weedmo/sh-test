#!/usr/bin/env bash
# setup-laptop.sh — orchestrator for "9h/day, plugged-in, Docker host" tuning
# on Ubuntu 24.04. Runs phases under phases/ in order. Idempotent.
#
# Each phase is a standalone script that can also be invoked directly.
#
# Usage:
#   sudo ./setup-laptop.sh              # run every phase
#   sudo ./setup-laptop.sh --list       # list available phases
#   sudo ./setup-laptop.sh --only 01,03 # run only matching phase numbers
#   sudo ./setup-laptop.sh --skip 04,05 # run all except these
#   sudo ./setup-laptop.sh --dry-run    # print what would happen, no changes
#
# Common env overrides (see each phase header for the full list):
#   CHARGE_LIMIT=80
#   DOCKER_LOG_MAX_SIZE=20m  DOCKER_LOG_MAX_FILE=3  DOCKER_PRUNE_UNTIL=72h
#   LID_BEHAVIOR=ignore-ac-suspend-bat   # or 'ignore'
#   MASK_SLEEP_TARGETS=1
#   JOURNAL_MAX_USE=2G

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

PHASES_DIR="${SCRIPT_DIR}/phases"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

list_phases() {
    log "Available phases (in run order):"
    for p in "${PHASES_DIR}"/[0-9][0-9]-*.sh; do
        [ -e "$p" ] || continue
        local base name desc
        base="$(basename "$p")"
        name="${base%.sh}"
        # First non-shebang, non-blank comment line as description.
        desc="$(awk '
            NR==1 && /^#!/ {next}
            /^# *Phase/ {sub(/^# */,""); print; exit}
        ' "$p")"
        printf '  %s\n      %s\n' "$name" "${desc:-(no description)}"
    done
}

# --- Arg parsing -------------------------------------------------------------
ONLY=""
SKIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage 0 ;;
        -l|--list)    list_phases; exit 0 ;;
        --only)       ONLY="$2"; shift 2 ;;
        --only=*)     ONLY="${1#*=}"; shift ;;
        --skip)       SKIP="$2"; shift 2 ;;
        --skip=*)     SKIP="${1#*=}"; shift ;;
        --dry-run)    export DRY_RUN=1; shift ;;
        --)           shift; break ;;
        *)            warn "Unknown argument: $1"; usage 1 ;;
    esac
done

require_root "$@"

# --- Comma-list match helpers ------------------------------------------------
in_csv() {
    # in_csv "01" "01,03,05" -> 0
    local needle="$1" hay="$2"
    case ",${hay}," in
        *",${needle},"*) return 0 ;;
        *)               return 1 ;;
    esac
}

should_run() {
    local num="$1"
    if [ -n "$ONLY" ] && ! in_csv "$num" "$ONLY"; then
        return 1
    fi
    if [ -n "$SKIP" ] && in_csv "$num" "$SKIP"; then
        return 1
    fi
    return 0
}

# --- Run phases --------------------------------------------------------------
log "setup-laptop.sh — host=$(hostname) codename=$(os_codename) cpu=$(cpu_vendor) laptop=$(is_laptop && echo yes || echo no) dry_run=${DRY_RUN:-0}"

OVERALL_RC=0
for phase in "${PHASES_DIR}"/[0-9][0-9]-*.sh; do
    [ -e "$phase" ] || { warn "No phases found in ${PHASES_DIR}"; exit 1; }
    base="$(basename "$phase")"
    num="${base%%-*}"
    if ! should_run "$num"; then
        ok "skip: ${base}"
        continue
    fi
    log "===== Running ${base} ====="
    if ! bash "$phase"; then
        warn "Phase ${base} exited non-zero."
        OVERALL_RC=1
    fi
done

if [ "$OVERALL_RC" -eq 0 ]; then
    ok "All requested phases finished cleanly."
else
    warn "One or more phases reported errors — re-run individually to inspect."
fi
exit "$OVERALL_RC"
