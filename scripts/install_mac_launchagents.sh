#!/usr/bin/env bash
# Install macOS launchd user agents for the dual-instance llama.cpp deployment:
#   com.devstral.llamacpp-35b-a3b -> 35B-A3B Q4 (MoE) on 127.0.0.1:8080
#   com.devstral.llamacpp-27b     -> 27B    Q4 (dense) on 127.0.0.1:8081
#
# Each agent sets KeepAlive=true and RunAtLoad=true so the servers come up on
# login and restart on crash. If a legacy single-instance agent
# com.devstral.llamacpp-local is present, it is booted out first.
#
# Env overrides:
#   LLAMACPP_SERVER_BIN  llama-server path (default: $(command -v llama-server)
#                        or ~/.local/llama.cpp/llama-server).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "install_mac_launchagents.sh is macOS only"

MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR_ABS="${RUN_DIR}"
mkdir -p "${AGENTS_DIR}" "${LOG_DIR_ABS}"

SERVER_BIN="${LLAMACPP_SERVER_BIN:-}"
if [[ -z "${SERVER_BIN}" ]]; then
  if have llama-server; then
    SERVER_BIN="$(command -v llama-server)"
  elif [[ -x "${LLAMACPP_HOME}/llama-server" ]]; then
    SERVER_BIN="${LLAMACPP_HOME}/llama-server"
  else
    die "llama-server not found. Run scripts/setup_llamacpp.sh or set LLAMACPP_SERVER_BIN"
  fi
fi
[[ -x "${SERVER_BIN}" ]] || die "not executable: ${SERVER_BIN}"
SERVER_DIR="$(cd "$(dirname "${SERVER_BIN}")" && pwd)"

resolve_model() {
  local alias="$1" path
  path="$(python3 "${MODELS_SCRIPT}" resolve "${alias}" 2>/dev/null || true)"
  [[ -n "${path}" && -f "${path}" ]] || die "model for alias ${alias} not on disk. Run: python3 ${MODELS_SCRIPT} prefetch ${alias}"
  echo "${path}"
}

MODEL_35B="$(resolve_model qwen3.6-35b-a3b-q4)"
MODEL_27B="$(resolve_model qwen3.6-27b-q4)"

bootout_if_loaded() {
  local label="$1" plist="${AGENTS_DIR}/${1}.plist"
  if launchctl list | awk '{print $3}' | grep -qx "${label}"; then
    echo "unloading ${label}"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || launchctl unload "${plist}" 2>/dev/null || true
  fi
  rm -f "${plist}"
}

# Legacy single-instance agent -> remove.
bootout_if_loaded com.devstral.llamacpp-local

wait_gone() {
  local label="$1" deadline=$(( $(date +%s) + 10 ))
  while launchctl list | awk '{print $3}' | grep -qx "${label}"; do
    [[ $(date +%s) -ge ${deadline} ]] && return 1
    sleep 1
  done
  return 0
}

write_plist() {
  local label="$1" port="$2" alias="$3" model="$4" instance="$5"
  local plist="${AGENTS_DIR}/${label}.plist"
  local log="${LOG_DIR_ABS}/llamacpp-${instance}.log"
  cat > "${plist}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${SERVER_BIN}</string>
    <string>-m</string><string>${model}</string>
    <string>-c</string><string>524288</string>
    <string>-b</string><string>2048</string>
    <string>-ub</string><string>512</string>
    <string>-ngl</string><string>99</string>
    <string>-fa</string><string>on</string>
    <string>-np</string><string>2</string>
    <string>--cache-type-k</string><string>q8_0</string>
    <string>--cache-type-v</string><string>q8_0</string>
    <string>--alias</string><string>${alias}</string>
    <string>--jinja</string>
    <string>--temp</string><string>0.6</string>
    <string>--top-p</string><string>0.95</string>
    <string>--top-k</string><string>20</string>
    <string>--min-p</string><string>0</string>
    <string>--presence-penalty</string><string>0.0</string>
    <string>--repeat-penalty</string><string>1.0</string>
    <string>--reasoning-format</string><string>deepseek</string>
    <string>--no-context-shift</string>
    <string>--reasoning</string><string>on</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>${port}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key><string>${SERVER_DIR}</string>
  </dict>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
XML
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  wait_gone "${label}" || die "failed to unload existing ${label}"
  launchctl bootstrap "gui/$(id -u)" "${plist}"
  echo "loaded ${label} (port ${port}, alias ${alias})"
}

write_plist com.devstral.llamacpp-35b-a3b 8080 qwen-35b-a3b "${MODEL_35B}" 35b-a3b
write_plist com.devstral.llamacpp-27b     8081 qwen-27b     "${MODEL_27B}" 27b

echo
echo "waiting for both endpoints (up to 900s each)..."
wait_ready() {
  local port="$1" deadline=$(( $(date +%s) + 900 ))
  while : ; do
    if curl -fsS "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
      echo "ready: http://127.0.0.1:${port}/v1"
      return 0
    fi
    [[ $(date +%s) -ge ${deadline} ]] && die "timed out on port ${port}"
    sleep 2
  done
}
wait_ready 8080
wait_ready 8081
echo "dual-instance deployment live"
