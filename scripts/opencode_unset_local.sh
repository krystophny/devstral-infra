#!/usr/bin/env bash
# Restore OpenCode config from backup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"

if [[ -f "${BACKUP_PATH}" ]]; then
    mv "${BACKUP_PATH}" "${CONFIG_PATH}"
    echo "Restored OpenCode config from backup"
elif [[ -f "${CONFIG_PATH}" ]]; then
    rm -f "${CONFIG_PATH}"
    echo "Removed OpenCode local config (no backup found)"
else
    echo "No OpenCode config to restore"
fi
