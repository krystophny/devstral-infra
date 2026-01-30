#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
    # macOS: Use LM Studio
    exec "${SCRIPT_DIR}/lmstudio_server_start.sh"
fi

# Linux/WSL: Use vLLM
migrate_legacy_pid

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"

PID_FILE="$(server_pid_file)"
LOG_FILE="$(server_log_file)"
PORT_FILE="$(server_port_file)"

if [[ -f "${PID_FILE}" ]]; then
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" >/dev/null 2>&1; then
        echo "already running (pid ${pid})"
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

mkdir -p "${RUN_DIR}"

# Check if vLLM venv exists
if [[ ! -d "${VENV_DIR}" ]]; then
    die "vLLM not installed. Run: scripts/setup.sh"
fi

activate_venv

if ! python -c "import vllm" >/dev/null 2>&1; then
    die "vLLM not installed. Run: scripts/setup.sh"
fi

mkdir -p "${HF_HOME_DIR}"

config="$(auto_config)"
MODEL="$(echo "${config}" | cut -d'|' -f1)"
MAX_MODEL_LEN="$(echo "${config}" | cut -d'|' -f2)"
EXTRA_FLAGS="$(echo "${config}" | cut -d'|' -f3)"

export HF_HOME="${HF_HOME_DIR}"
export VLLM_HOST_IP="127.0.0.1"
export DEVSTRAL_MODEL="${MODEL}"
export DEVSTRAL_HOST="${HOST}"
export DEVSTRAL_PORT="${PORT}"
export DEVSTRAL_MAX_MODEL_LEN="${MAX_MODEL_LEN}"
export DEVSTRAL_EXTRA_FLAGS="${EXTRA_FLAGS}"

nohup python "${REPO_ROOT}/server/run_devstral_server.py" \
    >"${LOG_FILE}" 2>&1 &

pid=$!
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

echo "started (pid ${pid})"
echo "- model: ${MODEL}"
echo "- max_model_len: ${MAX_MODEL_LEN}"
echo "- url: http://${HOST}:${PORT}/v1"
echo "- log: ${LOG_FILE}"
