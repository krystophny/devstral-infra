#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

MODEL="${DEVSTRAL_MODEL:-mlx-community/Devstral-2-123B-Instruct-2512-6bit}"
HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"
MAX_TOKENS="${DEVSTRAL_MAX_TOKENS:-1024}"
MAX_PROMPT_TOKENS="${DEVSTRAL_MAX_PROMPT_TOKENS:-200000}"
LOG_LEVEL="${DEVSTRAL_LOG_LEVEL:-INFO}"

ensure_python_venv
activate_venv

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

mkdir -p "${HF_HOME_DIR}" "${RUN_DIR}"

export HF_HOME="${HF_HOME_DIR}"
export DEVSTRAL_MAX_PROMPT_TOKENS="${MAX_PROMPT_TOKENS}"

nohup python "${REPO_ROOT}/server/run_devstral_mlx_server.py" \
  --model "${MODEL}" \
  --host "${HOST}" \
  --port "${PORT}" \
  --max-tokens "${MAX_TOKENS}" \
  --log-level "${LOG_LEVEL}" \
  >"${LOG_FILE}" 2>&1 &

pid=$!
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

echo "started (pid ${pid})"
echo "- model: ${MODEL}"
echo "- url: http://${HOST}:${PORT}/v1"
echo "- log: ${LOG_FILE}"
