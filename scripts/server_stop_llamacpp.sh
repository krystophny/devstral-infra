#!/usr/bin/env bash
# Stop llama.cpp server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/llamacpp.pid"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "not running (no pid file)"
  exit 0
fi

pid="$(cat "${PID_FILE}")"
if ! kill -0 "${pid}" 2>/dev/null; then
  echo "not running (stale pid file)"
  rm -f "${PID_FILE}"
  exit 0
fi

echo "stopping llama.cpp (pid ${pid})..."

# Graceful shutdown
kill "${pid}" 2>/dev/null || true

# Wait up to 30 seconds
for _ in {1..30}; do
  if ! kill -0 "${pid}" 2>/dev/null; then
    break
  fi
  sleep 1
done

# Force kill if still running
if kill -0 "${pid}" 2>/dev/null; then
  echo "force killing..."
  kill -9 "${pid}" 2>/dev/null || true
fi

rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
echo "stopped"
