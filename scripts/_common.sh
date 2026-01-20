#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${REPO_ROOT}/.run"
HF_HOME_DIR="${REPO_ROOT}/.hf"
VENV_DIR="${REPO_ROOT}/.venv"

mkdir -p "${RUN_DIR}"

die() {
  echo "error: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

ensure_python_venv() {
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    return 0
  fi

  if have python3.12; then
    python3.12 -m venv "${VENV_DIR}"
  elif have /opt/homebrew/bin/python3.12; then
    /opt/homebrew/bin/python3.12 -m venv "${VENV_DIR}"
  else
    die "python3.12 not found (MLX wheels are currently built for 3.12). Install via Homebrew: brew install python@3.12"
  fi
}

activate_venv() {
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
}

server_pid_file() {
  echo "${RUN_DIR}/mlx-server.pid"
}

server_log_file() {
  echo "${RUN_DIR}/mlx-server.log"
}

server_port_file() {
  echo "${RUN_DIR}/mlx-server.port"
}
