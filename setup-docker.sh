#!/usr/bin/env bash
# Docker Engine + Compose installer for Ubuntu 24.04 (Noble) / linux-amd64
#
# Target versions:
#   - Docker Engine (Community) 29.2.0
#   - containerd.io 2.2.1
#   - docker-buildx-plugin (latest from Docker apt repo)
#   - docker-compose-plugin v5.0.2
#
# Usage:
#   sudo ./setup-docker.sh
#   (or: ./setup-docker.sh   — script will re-exec under sudo)

set -euo pipefail

#-----------------------------------------------------------------------------
# Pinned target versions (override via env vars if needed)
#-----------------------------------------------------------------------------
DOCKER_VERSION="${DOCKER_VERSION:-29.2.0}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.1}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v5.0.2}"

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log "Re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
}

#-----------------------------------------------------------------------------
# 1. Preflight
#-----------------------------------------------------------------------------
require_root "$@"

[ "${ARCH}" = "amd64" ]   || die "This script targets linux/amd64 (current: ${ARCH})"
[ "${CODENAME}" = "noble" ] || warn "Tested on Ubuntu 24.04 (noble); detected '${CODENAME}'. Continuing anyway."

log "Updating apt cache and installing prerequisites..."
apt-get update -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    lsb-release

#-----------------------------------------------------------------------------
# 1a. Install + enable SSH server (fresh-Ubuntu friendly)
#-----------------------------------------------------------------------------
log "Installing and enabling OpenSSH server..."
apt-get install -y openssh-server

systemctl enable --now ssh

# Open port 22 if UFW is installed and active (or being enabled).
if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
fi

#-----------------------------------------------------------------------------
# 2. Remove any conflicting/older Docker packages
#-----------------------------------------------------------------------------
log "Removing legacy Docker packages (if any)..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "${pkg}" 2>/dev/null || true
done

#-----------------------------------------------------------------------------
# 3. Add Docker's official GPG key + apt repository
#-----------------------------------------------------------------------------
log "Configuring Docker apt repository..."
install -m 0755 -d /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

apt-get update -y

#-----------------------------------------------------------------------------
# 4. Resolve exact apt package versions for the pinned releases
#-----------------------------------------------------------------------------
resolve_pkg_version() {
    # Find the apt candidate string (e.g. "5:29.2.0-1~ubuntu.24.04~noble")
    # that begins with the upstream version we want.
    local pkg="$1" want="$2"
    apt-cache madison "${pkg}" \
        | awk '{print $3}' \
        | grep -E "(^|:)${want//./\\.}([-~]|$)" \
        | head -n1
}

log "Resolving package versions from apt..."
DOCKER_CE_PKG_VER="$(resolve_pkg_version docker-ce "${DOCKER_VERSION}")"
DOCKER_CLI_PKG_VER="$(resolve_pkg_version docker-ce-cli "${DOCKER_VERSION}")"
CONTAINERD_PKG_VER="$(resolve_pkg_version containerd.io "${CONTAINERD_VERSION}")"
COMPOSE_PKG_VER="$(resolve_pkg_version docker-compose-plugin "${COMPOSE_VERSION#v}")"

[ -n "${DOCKER_CE_PKG_VER}"  ] || die "docker-ce ${DOCKER_VERSION} not found in apt"
[ -n "${DOCKER_CLI_PKG_VER}" ] || die "docker-ce-cli ${DOCKER_VERSION} not found in apt"
[ -n "${CONTAINERD_PKG_VER}" ] || die "containerd.io ${CONTAINERD_VERSION} not found in apt"
[ -n "${COMPOSE_PKG_VER}"    ] || warn "docker-compose-plugin ${COMPOSE_VERSION} not found in apt — will fall back to manual install"

log "  docker-ce            -> ${DOCKER_CE_PKG_VER}"
log "  docker-ce-cli        -> ${DOCKER_CLI_PKG_VER}"
log "  containerd.io        -> ${CONTAINERD_PKG_VER}"
log "  docker-compose-plugin-> ${COMPOSE_PKG_VER:-<manual>}"

#-----------------------------------------------------------------------------
# 5. Install Docker Engine, CLI, containerd, buildx, compose plugin
#-----------------------------------------------------------------------------
log "Installing Docker packages..."
APT_PKGS=(
    "docker-ce=${DOCKER_CE_PKG_VER}"
    "docker-ce-cli=${DOCKER_CLI_PKG_VER}"
    "containerd.io=${CONTAINERD_PKG_VER}"
    "docker-buildx-plugin"
)
if [ -n "${COMPOSE_PKG_VER}" ]; then
    APT_PKGS+=("docker-compose-plugin=${COMPOSE_PKG_VER}")
fi

apt-get install -y --allow-downgrades "${APT_PKGS[@]}"

# Pin packages so unattended-upgrades doesn't quietly bump them.
apt-mark hold docker-ce docker-ce-cli containerd.io
[ -n "${COMPOSE_PKG_VER}" ] && apt-mark hold docker-compose-plugin || true

#-----------------------------------------------------------------------------
# 6. Fallback: install docker-compose-plugin from GitHub if apt did not have it
#-----------------------------------------------------------------------------
if [ -z "${COMPOSE_PKG_VER}" ]; then
    log "Installing docker compose ${COMPOSE_VERSION} from GitHub release..."
    CLI_PLUGIN_DIR="/usr/libexec/docker/cli-plugins"
    install -m 0755 -d "${CLI_PLUGIN_DIR}"
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        -o "${CLI_PLUGIN_DIR}/docker-compose"
    chmod +x "${CLI_PLUGIN_DIR}/docker-compose"
fi

#-----------------------------------------------------------------------------
# 7. Enable + start the daemon
#-----------------------------------------------------------------------------
log "Enabling and starting docker.service..."
systemctl enable --now docker.service
systemctl enable --now containerd.service

#-----------------------------------------------------------------------------
# 8. Allow the invoking user to run docker without sudo
#-----------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-${USER}}"
if [ -n "${TARGET_USER}" ] && [ "${TARGET_USER}" != "root" ]; then
    if ! id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
        log "Adding '${TARGET_USER}' to the 'docker' group (re-login required)..."
        usermod -aG docker "${TARGET_USER}"
    fi
fi

#-----------------------------------------------------------------------------
# 9. Verify
#-----------------------------------------------------------------------------
log "Versions installed:"
docker version  || true
docker compose version || true

#-----------------------------------------------------------------------------
# 10. Report SSH reachability (LAN + public IP)
#-----------------------------------------------------------------------------
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

log "Done. Open a new shell (or run: newgrp docker) to use docker without sudo."
