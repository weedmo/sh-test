#!/usr/bin/env bash
# Phase 2: Install Docker Engine, CLI, containerd, buildx, compose plugin.
# Enables the daemon and adds the invoking user to the 'docker' group.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root "$@"

log "Removing legacy Docker packages (if any)..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "${pkg}" 2>/dev/null || true
done

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

resolve_pkg_version() {
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

apt-mark hold docker-ce docker-ce-cli containerd.io
[ -n "${COMPOSE_PKG_VER}" ] && apt-mark hold docker-compose-plugin || true

if [ -z "${COMPOSE_PKG_VER}" ]; then
    log "Installing docker compose ${COMPOSE_VERSION} from GitHub release..."
    CLI_PLUGIN_DIR="/usr/libexec/docker/cli-plugins"
    install -m 0755 -d "${CLI_PLUGIN_DIR}"
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        -o "${CLI_PLUGIN_DIR}/docker-compose"
    chmod +x "${CLI_PLUGIN_DIR}/docker-compose"
fi

log "Enabling and starting docker.service..."
systemctl enable --now docker.service
systemctl enable --now containerd.service

TARGET_USER="${SUDO_USER:-${USER}}"
if [ -n "${TARGET_USER}" ] && [ "${TARGET_USER}" != "root" ]; then
    if ! id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
        log "Adding '${TARGET_USER}' to the 'docker' group (re-login required)..."
        usermod -aG docker "${TARGET_USER}"
    fi
fi

log "Versions installed:"
docker version || true
docker compose version || true

log "Done. Open a new shell (or run: newgrp docker) to use docker without sudo."
