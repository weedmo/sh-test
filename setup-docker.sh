#!/usr/bin/env bash
# Backward-compatible entrypoint for the split setup phases.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
exec "${SCRIPT_DIR}/main.sh" "$@"
