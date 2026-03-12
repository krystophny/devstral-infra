#!/usr/bin/env bash
# Stop llama.cpp server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/llamacpp.pid"
LAUNCHD_LABEL="com.devstral.llamacpp"
SYSTEMD_UNIT="devstral-llamacpp"
platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
  if ! launchctl list "${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    echo "not running"
    rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
    exit 0
  fi
  echo "stopping llama.cpp (launchd: ${LAUNCHD_LABEL})..."
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  for _ in {1..30}; do
    if ! launchctl list "${LAUNCHD_LABEL}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  rm -f "${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  rm -f "${PID_FILE}" "${RUN_DIR}/llamacpp.port"
  echo "stopped"
else
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
