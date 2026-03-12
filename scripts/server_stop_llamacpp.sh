#!/usr/bin/env bash
# Stop llama.cpp server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/llamacpp.pid"
TMUX_FILE="${RUN_DIR}/llamacpp.tmux"

if [[ ! -f "${PID_FILE}" && ! -f "${TMUX_FILE}" ]]; then
  echo "not running (no pid file)"
  exit 0
fi

session_name=""
if [[ -f "${TMUX_FILE}" ]]; then
  session_name="$(cat "${TMUX_FILE}")"
fi

if [[ ! -f "${PID_FILE}" ]]; then
  if [[ -n "${session_name}" ]] && tmux has-session -t "${session_name}" 2>/dev/null; then
    echo "stopping llama.cpp tmux session (${session_name})..."
    tmux kill-session -t "${session_name}" >/dev/null 2>&1 || true
    rm -f "${TMUX_FILE}" "${RUN_DIR}/llamacpp.port"
    echo "stopped"
    exit 0
  fi
  echo "not running (stale launcher metadata)"
  rm -f "${TMUX_FILE}"
  exit 0
fi

pid="$(cat "${PID_FILE}")"
if ! kill -0 "${pid}" 2>/dev/null; then
  if [[ -n "${session_name}" ]] && tmux has-session -t "${session_name}" 2>/dev/null; then
    echo "stopping stale tmux session (${session_name})..."
    tmux kill-session -t "${session_name}" >/dev/null 2>&1 || true
  else
    echo "not running (stale pid file)"
  fi
  rm -f "${PID_FILE}" "${TMUX_FILE}"
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

if [[ -n "${session_name}" ]] && tmux has-session -t "${session_name}" 2>/dev/null; then
  tmux kill-session -t "${session_name}" >/dev/null 2>&1 || true
fi

rm -f "${PID_FILE}" "${TMUX_FILE}" "${RUN_DIR}/llamacpp.port"
echo "stopped"
