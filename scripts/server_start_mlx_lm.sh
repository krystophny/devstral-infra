#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"
START_TIMEOUT="${MLX_LM_START_TIMEOUT:-900}"
SMOKE_TEST="${MLX_LM_SMOKE_TEST:-true}"
SMOKE_TEST_PROMPT="${MLX_LM_SMOKE_TEST_PROMPT:-Reply with exactly READY.}"
DRY_RUN="${MLX_LM_DRY_RUN:-false}"
MODEL_PATH="${MLX_LM_MODEL:-}"
SERVER_BIN="${MLX_LM_SERVER_BIN:-}"
MAX_TOKENS="${MLX_LM_MAX_TOKENS:-}"
DECODE_CONCURRENCY="${MLX_LM_DECODE_CONCURRENCY:-}"
PROMPT_CONCURRENCY="${MLX_LM_PROMPT_CONCURRENCY:-}"
PREFILL_STEP_SIZE="${MLX_LM_PREFILL_STEP_SIZE:-}"
PROMPT_CACHE_SIZE="${MLX_LM_PROMPT_CACHE_SIZE:-}"
PROMPT_CACHE_BYTES="${MLX_LM_PROMPT_CACHE_BYTES:-}"
CHAT_TEMPLATE_ARGS="${MLX_LM_CHAT_TEMPLATE_ARGS:-}"

PID_FILE="${RUN_DIR}/mlx-lm.pid"
LOG_FILE="${RUN_DIR}/mlx-lm.log"
PORT_FILE="${RUN_DIR}/mlx-lm.port"

if [[ -z "${SERVER_BIN}" ]]; then
  if have mlx_lm.server; then
    SERVER_BIN="$(command -v mlx_lm.server)"
  else
    SERVER_BIN="/Users/user/code/.venv/bin/mlx_lm.server"
  fi
fi

if [[ ! -x "${SERVER_BIN}" ]]; then
  die "mlx_lm.server not found. Set MLX_LM_SERVER_BIN or install mlx-lm."
fi

if [[ -z "${MODEL_PATH}" ]]; then
  MODEL_PATH="$(python3 "${SCRIPT_DIR}/benchmark_model_paths.py" resolve mlx-qwen3.5-9b-4bit 2>/dev/null || true)"
fi
if [[ -z "${MODEL_PATH}" || ! -d "${MODEL_PATH}" ]]; then
  die "missing MLX model path. Set MLX_LM_MODEL or BENCHMARK_MLX_MODEL."
fi

CMD=(
  "${SERVER_BIN}"
  --model
  "${MODEL_PATH}"
  --host
  "${HOST}"
  --port
  "${PORT}"
  --use-default-chat-template
)

if [[ -n "${MAX_TOKENS}" ]]; then
  CMD+=(--max-tokens "${MAX_TOKENS}")
fi
if [[ -n "${DECODE_CONCURRENCY}" ]]; then
  CMD+=(--decode-concurrency "${DECODE_CONCURRENCY}")
fi
if [[ -n "${PROMPT_CONCURRENCY}" ]]; then
  CMD+=(--prompt-concurrency "${PROMPT_CONCURRENCY}")
fi
if [[ -n "${PREFILL_STEP_SIZE}" ]]; then
  CMD+=(--prefill-step-size "${PREFILL_STEP_SIZE}")
fi
if [[ -n "${PROMPT_CACHE_SIZE}" ]]; then
  CMD+=(--prompt-cache-size "${PROMPT_CACHE_SIZE}")
fi
if [[ -n "${PROMPT_CACHE_BYTES}" ]]; then
  CMD+=(--prompt-cache-bytes "${PROMPT_CACHE_BYTES}")
fi
if [[ -n "${CHAT_TEMPLATE_ARGS}" ]]; then
  CMD+=(--chat-template-args "${CHAT_TEMPLATE_ARGS}")
fi

if [[ "${MLX_LM_TRUST_REMOTE_CODE:-false}" == "true" ]]; then
  CMD+=(--trust-remote-code)
fi

if [[ -n "${MLX_LM_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CMD+=(${MLX_LM_EXTRA_FLAGS})
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'dry-run:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "mlx-lm already running (pid ${pid})"
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  die "port ${PORT} already in use"
fi

nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
pid="$!"
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

for (( i = 1; i <= START_TIMEOUT; i++ )); do
  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    echo "mlx-lm failed to start. Check log: ${LOG_FILE}"
    tail -40 "${LOG_FILE}" || true
    exit 1
  fi
  if curl -fsS "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ "${SMOKE_TEST}" == "true" ]]; then
  model_id="$(
    curl -fsS "http://${HOST}:${PORT}/v1/models" | \
      python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["data"][0]["id"])'
  )"
  payload="$(
    python3 - "${model_id}" "${SMOKE_TEST_PROMPT}" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 16,
    "temperature": 0.0,
}))
PY
  )"
  response="$(
    curl -sS \
      -H 'Content-Type: application/json' \
      "http://${HOST}:${PORT}/v1/chat/completions" \
      -d "${payload}"
  )"
  if [[ "${response}" != *"READY"* ]]; then
    echo "Smoke test failed"
    printf '%s\n' "${response}"
    exit 1
  fi
fi

cat <<EOF
started mlx-lm (pid ${pid})
- model: ${MODEL_PATH}
- local url: http://${HOST}:${PORT}/v1
- log: ${LOG_FILE}
EOF
