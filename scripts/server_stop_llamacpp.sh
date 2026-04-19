#!/usr/bin/env bash
# Stop llama.cpp server instance(s).
# Usage: server_stop_llamacpp.sh [instance]
#   instance: "local" (default), "fast", or "all" (stops both)
#   Also settable via LLAMACPP_INSTANCE env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

INSTANCE="${1:-${LLAMACPP_INSTANCE:-local}}"

stop_instance() {
  local inst="$1"
  local pid_file="${RUN_DIR}/llamacpp-${inst}.pid"
  local port_file="${RUN_DIR}/llamacpp-${inst}.port"
  local launchd_label="com.devstral.llamacpp-${inst}"
  local plist_path="${HOME}/Library/LaunchAgents/${launchd_label}.plist"
  local systemd_unit="devstral-llamacpp-${inst}"
  local platform
  platform="$(detect_platform)"

  # Migrate old unsuffixed files for the "local" instance
  if [[ "${inst}" == "local" ]]; then
    for ext in pid port log; do
      local old="${RUN_DIR}/llamacpp.${ext}"
      local new="${RUN_DIR}/llamacpp-local.${ext}"
      if [[ -f "${old}" && ! -f "${new}" ]]; then
        mv "${old}" "${new}"
      fi
      rm -f "${old}"
    done

    # Also try stopping the old unsuffixed launchd label
    local old_label="com.devstral.llamacpp"
    local old_plist="${HOME}/Library/LaunchAgents/${old_label}.plist"
    if [[ "${platform}" == "mac" ]] && launchctl list "${old_label}" >/dev/null 2>&1; then
      launchctl unload "${old_plist}" 2>/dev/null || true
    fi
  fi

  if [[ "${platform}" == "mac" ]]; then
    if launchctl list "${launchd_label}" >/dev/null 2>&1; then
      echo "stopping llama.cpp [${inst}] (launchd: ${launchd_label})..."
      launchctl unload "${plist_path}" 2>/dev/null || true
      local port
      if [[ "${inst}" == "local" ]]; then port=8080; else port=8081; fi
      stop_llamacpp_port_occupants "${port}" "launchd llama.cpp [${inst}]"
      rm -f "${pid_file}" "${port_file}"
      echo "stopped"
      return 0
    fi
    local port
    if [[ "${inst}" == "local" ]]; then port=8080; else port=8081; fi
    if [[ ! -f "${pid_file}" ]]; then
      # Fallback: stop by port if PID file is missing but server is running.
      if [[ -n "$(port_listener_pids "${port}")" ]]; then
        echo "stopping orphan llama.cpp [${inst}] on port ${port} (PID file missing)..."
        stop_llamacpp_port_occupants "${port}" "orphan llama.cpp [${inst}]"
        sleep 2
        echo "stopped (orphan)"
        return 0
      fi
      echo "[${inst}] not running"
      return 0
    fi
    local pid
    pid="$(cat "${pid_file}")"
    if ! kill -0 "${pid}" 2>/dev/null; then
      if [[ -n "$(port_listener_pids "${port}")" ]]; then
        echo "stopping stale-port llama.cpp [${inst}] on port ${port}..."
        stop_llamacpp_port_occupants "${port}" "stale-port llama.cpp [${inst}]"
      else
        echo "[${inst}] not running (stale pid file)"
      fi
      rm -f "${pid_file}" "${port_file}"
      return 0
    fi
    echo "stopping llama.cpp [${inst}] (pid ${pid})..."
    stop_pid "${pid}" "llama.cpp [${inst}]"
    rm -f "${pid_file}" "${port_file}"
    echo "stopped"
  else
    if ! systemctl --user is-active "${systemd_unit}" >/dev/null 2>&1; then
      echo "[${inst}] not running"
      rm -f "${pid_file}" "${port_file}"
      return 0
    fi
    echo "stopping llama.cpp [${inst}] (systemd: ${systemd_unit})..."
    systemctl --user stop "${systemd_unit}"
    rm -f "${pid_file}" "${port_file}"
    echo "stopped"
  fi
}

if [[ "${INSTANCE}" == "all" ]]; then
  stop_instance "local"
  stop_instance "fast"
elif [[ "${INSTANCE}" == "local" || "${INSTANCE}" == "fast" ]]; then
  stop_instance "${INSTANCE}"
else
  die "unknown instance: ${INSTANCE} (expected: local, fast, all)"
fi
