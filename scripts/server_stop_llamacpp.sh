#!/usr/bin/env bash
# Stop the llama.cpp server started by server_start_llamacpp.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/llamacpp.pid"
PORT_FILE="${RUN_DIR}/llamacpp.port"
PORT="${LLAMACPP_PORT:-8080}"
[[ -f "${PORT_FILE}" ]] && PORT="$(cat "${PORT_FILE}")"

stopped=0
if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" 2>/dev/null; then
    echo "stopping llama.cpp (pid ${pid})..."
    stop_pid "${pid}" "llama.cpp"
    stopped=1
  fi
  rm -f "${PID_FILE}"
fi

if [[ -n "$(port_listener_pids "${PORT}")" ]]; then
  stop_llamacpp_port_occupants "${PORT}" "llama.cpp"
  stopped=1
fi

rm -f "${PORT_FILE}"

if [[ "${stopped}" -eq 0 ]]; then
  echo "llama.cpp not running"
else
  echo "stopped"
fi
