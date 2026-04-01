#!/usr/bin/env bash
# Stop llama.cpp BGE-M3 embedding service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PID_FILE="${RUN_DIR}/llamacpp-embed.pid"
PORT_FILE="${RUN_DIR}/llamacpp-embed.port"
HOST="${LLAMACPP_EMBEDDING_HOST:-127.0.0.1}"
PORT="${LLAMACPP_EMBEDDING_PORT:-11434}"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "stopping llama.cpp embedding server (pid ${pid})..."
    kill "${pid}" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -9 "${pid}" >/dev/null 2>&1 || true
  fi
fi

if command -v lsof >/dev/null 2>&1; then
  if lsof -ti ":${PORT}" >/dev/null 2>&1; then
    lsof -ti ":${PORT}" | xargs -r kill -9 2>/dev/null || true
  fi
else
  for _pid in $(
    ss -ltnp 2>/dev/null \
      | awk -v port="${PORT}" '
          $4 ~ ":" port "$" {
            match($0, /pid=([0-9]+)/, m)
            if (m[1] != "") {
              print m[1]
            }
          }
        '
  ); do
    if [[ -n "${_pid}" ]]; then
      kill -9 "${_pid}" 2>/dev/null || true
    fi
  done
fi

rm -f "${PID_FILE}" "${PORT_FILE}"
echo "stopped"
