#!/usr/bin/env bash
# Stop the llama.cpp server started by server_start_llamacpp.sh.
#
# Env:
#   LLAMACPP_INSTANCE  instance suffix matching the one passed at start time;
#                      empty (default) targets the unnamed instance.
#   LLAMACPP_PORT      fallback port when no port file is present (default 8080)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

INSTANCE="${LLAMACPP_INSTANCE:-}"
if [[ -n "${INSTANCE}" ]]; then
  PID_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.pid"
  PORT_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.port"
else
  PID_FILE="${RUN_DIR}/llamacpp.pid"
  PORT_FILE="${RUN_DIR}/llamacpp.port"
fi
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
