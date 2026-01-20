#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

CONFIG_PATH="${VIBE_CONFIG_PATH:-}"
if [[ -z "${CONFIG_PATH}" ]]; then
  if [[ -f "${REPO_ROOT}/.vibe/config.toml" ]]; then
    CONFIG_PATH="${REPO_ROOT}/.vibe/config.toml"
  else
    CONFIG_PATH="${HOME}/.vibe/config.toml"
  fi
fi

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ ! -f "${BACKUP_PATH}" ]]; then
  echo "no backup found (${BACKUP_PATH}); nothing to restore"
  exit 0
fi

cp "${BACKUP_PATH}" "${CONFIG_PATH}"
echo "restored ${CONFIG_PATH} from ${BACKUP_PATH}"
