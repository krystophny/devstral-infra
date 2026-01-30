#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
    # macOS: Use LM Studio
    exec "${SCRIPT_DIR}/lmstudio_server_stop.sh"
fi

# Linux/WSL: Stop vLLM
migrate_legacy_pid

PID_FILE="$(server_pid_file)"
PORT_FILE="$(server_port_file)"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "not running (no pid file)"
  exit 0
fi

pid="$(cat "${PID_FILE}")"
if kill -0 "${pid}" >/dev/null 2>&1; then
  kill -INT "${pid}" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if kill -0 "${pid}" >/dev/null 2>&1; then
      sleep 1
    else
      break
    fi
  done
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
  fi
fi

rm -f "${PID_FILE}" "${PORT_FILE}"
echo "stopped"
