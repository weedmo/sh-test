#!/usr/bin/env bash
# Host setup orchestrator for Ubuntu 24.04 (Noble) / linux-amd64.
# Runs SSH setup (phase 1) then Docker setup (phase 2).
#
# Usage:
#   sudo ./main.sh
#   (or: ./main.sh   — script will re-exec under sudo)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root "$@"

[ "${ARCH}" = "amd64" ]     || die "This script targets linux/amd64 (current: ${ARCH})"
[ "${CODENAME}" = "noble" ] || warn "Tested on Ubuntu 24.04 (noble); detected '${CODENAME}'. Continuing anyway."

log "Updating apt cache and installing base prerequisites..."
apt-get update -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    lsb-release

PHASES=(
    "01-ssh.sh"
    "02-docker.sh"
)

total=${#PHASES[@]}
i=0
for phase in "${PHASES[@]}"; do
    i=$((i + 1))
    log "===== [${i}/${total}] Running phase: ${phase} ====="
    bash "${SCRIPT_DIR}/phases/${phase}"
done

log "All phases completed."
