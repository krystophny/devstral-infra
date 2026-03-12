#!/usr/bin/env bash
# Stop llama.cpp server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/llamacpp.pid"
LAUNCHD_LABEL="com.devstral.llamacpp"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
SYSTEMD_UNIT="devstral-llamacpp"
platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
  # Try launchd first
  if launchctl list "${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    echo "stopping llama.cpp (launchd: ${LAUNCHD_LABEL})..."
    launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
    echo "stopped"
    exit 0
  fi
  # Fall back to PID (SSH session where launchd wasn't available at start)
  if [[ ! -f "${PID_FILE}" ]]; then
    echo "not running"
    exit 0
  fi
  pid="$(cat "${PID_FILE}")"
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "not running (stale pid file)"
    rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
    exit 0
  fi
  echo "stopping llama.cpp (pid ${pid})..."
  kill "${pid}" 2>/dev/null || true
  for _ in {1..30}; do
    if ! kill -0 "${pid}" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    echo "force killing..."
    kill -9 "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
  echo "stopped"
else
  # Linux: systemd
  if ! systemctl --user is-active "${SYSTEMD_UNIT}" >/dev/null 2>&1; then
    echo "not running"
    rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
    exit 0
  fi
  echo "stopping llama.cpp (systemd: ${SYSTEMD_UNIT})..."
  systemctl --user stop "${SYSTEMD_UNIT}"
  rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
  echo "stopped"
fi
