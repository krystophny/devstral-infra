#!/usr/bin/env bash
# Stop oMLX server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/omlx.pid"
PORT_FILE="${RUN_DIR}/omlx.port"

stopped=0

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "stopping oMLX (pid ${pid})..."
    kill "${pid}" || true
    for _ in {1..30}; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        stopped=1
        break
      fi
      sleep 1
    done
    if kill -0 "${pid}" >/dev/null 2>&1; then
      echo "force stopping oMLX (pid ${pid})..."
      kill -9 "${pid}" || true
      stopped=1
    fi
  fi
fi

# Fallback if PID file was stale/missing.
if [[ "${stopped}" == "0" ]]; then
  if pgrep -f "omlx serve" >/dev/null 2>&1; then
    pkill -f "omlx serve" || true
    stopped=1
  fi
fi

rm -f "${PID_FILE}" "${PORT_FILE}"

if [[ "${stopped}" == "1" ]]; then
  echo "oMLX stopped"
else
  echo "oMLX not running"
fi
