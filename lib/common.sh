#!/usr/bin/env bash
# Shared helpers and pinned versions for the setup phases.
# Source this file; do not execute it directly.

# Pinned target versions (override via env vars if needed)
: "${DOCKER_VERSION:=29.2.0}"
: "${CONTAINERD_VERSION:=2.2.1}"
: "${COMPOSE_VERSION:=v5.0.2}"

ARCH="${ARCH:-$(dpkg --print-architecture)}"
CODENAME="${CODENAME:-$(. /etc/os-release && echo "${VERSION_CODENAME}")}"

export DOCKER_VERSION CONTAINERD_VERSION COMPOSE_VERSION ARCH CODENAME

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log "Re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
}
