#!/usr/bin/env bash
# Shared helpers for laptop / always-on Docker host setup phases.
#
# Source-only: do not execute directly.
#   . "$(dirname "$0")/../lib/common.sh"

# Guard against double-sourcing.
if [ -n "${_LAPTOP_COMMON_SOURCED:-}" ]; then
    return 0
fi
_LAPTOP_COMMON_SOURCED=1

#-----------------------------------------------------------------------------
# Output
#-----------------------------------------------------------------------------
log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }

# DRY_RUN=1 -> print actions instead of executing root-mutating commands.
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '\033[1;35m[dry-run]\033[0m %s\n' "$*"
        return 0
    fi
    "$@"
}

#-----------------------------------------------------------------------------
# Privilege
#-----------------------------------------------------------------------------
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log "Re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
}

#-----------------------------------------------------------------------------
# Platform detection
#-----------------------------------------------------------------------------
os_codename() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s\n' "${VERSION_CODENAME:-unknown}" )
    else
        echo unknown
    fi
}

# Returns 0 if the host has any battery, 1 otherwise.
has_battery() {
    for d in /sys/class/power_supply/BAT*; do
        [ -e "$d" ] && return 0
    done
    return 1
}

# Echoes the first BAT path (e.g. /sys/class/power_supply/BAT0). Empty if none.
battery_path() {
    for d in /sys/class/power_supply/BAT*; do
        [ -e "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

cpu_vendor() {
    awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo
}

is_intel() { [ "$(cpu_vendor)" = "GenuineIntel" ]; }
is_amd()   { [ "$(cpu_vendor)" = "AuthenticAMD" ]; }

# Returns 0 if it looks like a laptop (battery present OR DMI chassis indicates
# notebook/laptop/portable). Useful to gate laptop-only phases.
is_laptop() {
    has_battery && return 0
    local t
    t="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)"
    case "$t" in
        8|9|10|14) return 0 ;; # Portable / Laptop / Notebook / Sub-Notebook
        *)         return 1 ;;
    esac
}

#-----------------------------------------------------------------------------
# Idempotency primitives
#-----------------------------------------------------------------------------

# Write FILE with given CONTENT only if it differs (or does not exist).
#   write_file <path> <<'EOF' ... EOF
# Honors DRY_RUN.
write_file() {
    local path="$1"
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    if [ -e "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        ok "unchanged: $path"
        return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '\033[1;35m[dry-run]\033[0m would write %s:\n' "$path"
        sed 's/^/    /' "$tmp"
        rm -f "$tmp"
        return 0
    fi
    install -D -m 0644 "$tmp" "$path"
    rm -f "$tmp"
    log "wrote: $path"
}

# Backup a file once, suffixed .bak-YYYYmmddHHMMSS, only if not already backed
# up in this run.
backup_once() {
    local f="$1"
    [ -e "$f" ] || return 0
    local ts
    ts="$(date +%Y%m%d%H%M%S)"
    run cp -a "$f" "${f}.bak-${ts}"
    log "backup: ${f}.bak-${ts}"
}

# Ensure a systemd unit is enabled and started (idempotent).
enable_now() {
    local unit="$1"
    run systemctl daemon-reload
    run systemctl enable --now "$unit"
}

disable_now() {
    local unit="$1"
    run systemctl disable --now "$unit" 2>/dev/null || true
}
