#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

if [[ -f "$(server_pid_file)" ]] || [[ -f "$(legacy_pid_file)" ]]; then
  "${SCRIPT_DIR}/server_stop.sh" || true
fi

rm -rf "${VENV_DIR}" "${RUN_DIR}"
rm -rf "${HF_HOME_DIR}"

echo "OK (removed ${VENV_DIR}, ${RUN_DIR}, ${HF_HOME_DIR})"
