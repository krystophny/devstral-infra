#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

if [[ -f "$(server_pid_file)" ]] || [[ -f "$(legacy_pid_file)" ]]; then
  "${SCRIPT_DIR}/server_stop.sh" || true
fi

platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
    # macOS: LM Studio manages its own model storage
    # We only clean up our runtime directory
    rm -rf "${RUN_DIR}"
    echo "OK (removed ${RUN_DIR})"
    echo ""
    echo "Note: LM Studio models are stored in ~/.cache/lm-studio/models"
    echo "To remove models: lms rm <model-name>"
else
    # Linux/WSL: Clean up venv and HuggingFace cache
    rm -rf "${VENV_DIR}" "${RUN_DIR}"
    rm -rf "${HF_HOME_DIR}"
    echo "OK (removed ${VENV_DIR}, ${RUN_DIR}, ${HF_HOME_DIR})"
fi
