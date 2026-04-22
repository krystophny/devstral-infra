#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/.run}"
LOG_DIR="${LOG_DIR:-${RUN_DIR}}"
LLAMACPP_HOME="${LLAMACPP_HOME:-${HOME}/.local/llama.cpp}"
case "$(uname -s)" in
  Darwin) DEFAULT_CACHE_ROOT="${HOME}/Library/Caches/llama.cpp" ;;
  *)      DEFAULT_CACHE_ROOT="${HOME}/.cache/llama.cpp" ;;
esac
LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-${DEFAULT_CACHE_ROOT}}"
export LLAMA_CACHE="${LLAMA_CACHE:-${LLAMACPP_CACHE_ROOT}}"

mkdir -p "${RUN_DIR}"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "mac" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) die "unsupported platform: $(uname -s)" ;;
  esac
}

detect_gpu() {
  case "$(detect_platform)" in
    mac) echo "metal" ;;
    linux|wsl)
      if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        echo "cuda"
      elif have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; then
        echo "vulkan"
      else
        echo "cpu"
      fi
      ;;
    windows) echo "vulkan" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

pid_command() { ps -p "$1" -o command= 2>/dev/null || true; }
port_listener_pids() { lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; }

stop_pid() {
  local pid="$1" label="${2:-process}"
  kill -0 "${pid}" 2>/dev/null || return 0
  kill "${pid}" 2>/dev/null || true
  for _ in {1..30}; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  warn "${label} pid ${pid} did not exit after SIGTERM; sending SIGKILL"
  kill -9 "${pid}" 2>/dev/null || true
}

stop_llamacpp_port_occupants() {
  local port="$1" label="${2:-llama.cpp server}"
  local pids pid cmd
  pids="$(port_listener_pids "${port}")"
  [[ -n "${pids}" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmd="$(pid_command "${pid}")"
    if [[ "${cmd}" != *"llama-server"* ]]; then
      die "port ${port} is occupied by a non-llama process (pid ${pid}: ${cmd})"
    fi
    echo "stopping ${label} on port ${port} (pid ${pid})..."
    stop_pid "${pid}" "${label}"
  done <<< "${pids}"
}
