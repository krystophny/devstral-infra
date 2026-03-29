#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

stop_instance() {
  local inst="$1"
  local pid_file="${RUN_DIR}/vllm-mlx-${inst}.pid"
  local port_file="${RUN_DIR}/vllm-mlx-${inst}.port"
  local launchd_label="com.devstral.vllm-mlx-${inst}"
  local stopped=0

  launchctl unload "${HOME}/Library/LaunchAgents/${launchd_label}.plist" 2>/dev/null || true

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
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

  if [[ "${stopped}" == "0" ]]; then
    if pgrep -f "vllm_mlx.cli serve" >/dev/null 2>&1; then
      pkill -f "vllm_mlx.cli serve" || true
      stopped=1
    fi
  fi

  rm -f "${pid_file}" "${port_file}"
  if [[ "${stopped}" == "1" ]]; then
    echo "stopped vllm-mlx [${inst}]"
  else
    echo "vllm-mlx [${inst}] not running"
  fi
}

INSTANCE="${1:-local}"
if [[ "${INSTANCE}" == "all" ]]; then
  stop_instance local
  stop_instance fast
else
  stop_instance "${INSTANCE}"
fi
