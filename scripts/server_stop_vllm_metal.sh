#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/vllm-metal.pid"
PORT_FILE="${RUN_DIR}/vllm-metal.port"

stopped=0

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" || true
    for _ in {1..30}; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        stopped=1
        break
      fi
      sleep 1
    done
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -9 "${pid}" || true
      stopped=1
    fi
  fi
fi

rm -f "${PID_FILE}" "${PORT_FILE}"

if [[ "${stopped}" == "1" ]]; then
  echo "vllm-metal stopped"
else
  echo "vllm-metal not running"
fi
