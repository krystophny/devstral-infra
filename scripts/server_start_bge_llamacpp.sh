#!/usr/bin/env bash
# Start llama.cpp for BGE-M3 embeddings on the local machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LLAMA_SERVER_BIN="${LLAMACPP_EMBEDDING_SERVER_BIN:-${LLAMA_SERVER_BIN:-}}"
if [[ -z "${LLAMA_SERVER_BIN}" ]]; then
  if [[ -x "${HOME}/.local/bin/llama-server" ]]; then
    LLAMA_SERVER_BIN="${HOME}/.local/bin/llama-server"
  elif command -v llama-server >/dev/null 2>&1; then
    LLAMA_SERVER_BIN="$(command -v llama-server)"
  else
    die "llama-server not found. Install it first or set LLAMACPP_EMBEDDING_SERVER_BIN."
  fi
fi

HOST="${LLAMACPP_EMBEDDING_HOST:-0.0.0.0}"
PORT="${LLAMACPP_EMBEDDING_PORT:-11434}"
MODEL_PATH="${LLAMACPP_EMBEDDING_MODEL:-${LLAMACPP_EMBEDDING_MODEL_PATH:-}}"
POOLING="${LLAMACPP_EMBEDDING_POOLING:-cls}"
ALIAS="${LLAMACPP_EMBEDDING_ALIAS:-bge-m3}"
MODEL_CTX="${LLAMACPP_EMBEDDING_CONTEXT:-8192}"
THREADS="${LLAMACPP_EMBEDDING_THREADS:-${LLAMACPP_THREADS:-4}}"

if [[ -z "${MODEL_PATH}" ]]; then
  die "LLAMACPP_EMBEDDING_MODEL is required (path to a BGE-M3 GGUF)."
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
  die "Model file not found: ${MODEL_PATH}"
fi

PID_FILE="${RUN_DIR}/llamacpp-embed.pid"
LOG_FILE="${RUN_DIR}/llamacpp-embed.log"
PORT_FILE="${RUN_DIR}/llamacpp-embed.port"

mkdir -p "${RUN_DIR}"

if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}")"
  if kill -0 "${old_pid}" >/dev/null 2>&1; then
    echo "already running (pid ${old_pid})"
    exit 0
  fi
  rm -f "${PID_FILE}" "${PORT_FILE}"
fi

cmd=(
  "${LLAMA_SERVER_BIN}"
  -m "${MODEL_PATH}"
  --host "${HOST}"
  --port "${PORT}"
  -c "${MODEL_CTX}"
  -t "${THREADS}"
  --alias "${ALIAS}"
  --embeddings
  --pooling "${POOLING}"
  --no-webui
)

if [[ -n "${LLAMACPP_EMBEDDING_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=( ${LLAMACPP_EMBEDDING_EXTRA_FLAGS} )
fi

# Keep process detached from shell lifecycle to avoid orphaning issues.
if command -v setsid >/dev/null 2>&1; then
  setsid -f "${cmd[@]}" >"${LOG_FILE}" 2>&1 < /dev/null &
else
  nohup "${cmd[@]}" >"${LOG_FILE}" 2>&1 < /dev/null &
fi
pid=$!

for _ in {1..30}; do
  if kill -0 "${pid}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kill -0 "${pid}" >/dev/null 2>&1; then
  echo "failed to start llama.cpp embedding server. check: ${LOG_FILE}" >&2
  exit 1
fi

echo "${pid}" >"${PID_FILE}"
echo "${PORT}" >"${PORT_FILE}"

for _ in {1..120}; do
  if curl -sf "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "started (pid ${pid})"
    echo "- url: http://${HOST}:${PORT}/v1"
    echo "- model: ${MODEL_PATH}"
    echo "- alias: ${ALIAS}"
    echo "- log: ${LOG_FILE}"
    exit 0
  fi
  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    echo "server exited during startup. check: ${LOG_FILE}" >&2
    cat "${LOG_FILE}" >&2
    exit 1
  fi
  sleep 1
done

echo "server started but /v1/models did not become ready within timeout. check: ${LOG_FILE}" >&2
exit 1
