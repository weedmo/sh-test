#!/usr/bin/env bash
# Phase 1: Install + enable OpenSSH server and report reachability.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root "$@"

log "Installing and enabling OpenSSH server..."
apt-get install -y openssh-server
systemctl enable --now ssh

if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
fi

TARGET_USER="${SUDO_USER:-${USER}}"

SSH_PORT="$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')"
SSH_PORT="${SSH_PORT:-22}"

mapfile -t LAN_IPS < <(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1)

PUBLIC_IP="$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --max-time 3 https://ifconfig.me 2>/dev/null \
    || true)"

log "SSH service status:"
systemctl is-active ssh && log "  ssh.service: active" || warn "  ssh.service: not active"

log "SSH access endpoints (user: ${TARGET_USER:-$(whoami)}, port: ${SSH_PORT}):"
if [ "${#LAN_IPS[@]}" -gt 0 ]; then
    for ip in "${LAN_IPS[@]}"; do
        printf '    ssh -p %s %s@%s\n' "${SSH_PORT}" "${TARGET_USER:-$(whoami)}" "${ip}"
    done
else
    warn "  No non-loopback IPv4 address detected."
fi
if [ -n "${PUBLIC_IP}" ]; then
    printf '    ssh -p %s %s@%s   # public (verify firewall/NAT)\n' \
        "${SSH_PORT}" "${TARGET_USER:-$(whoami)}" "${PUBLIC_IP}"
fi
