#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"
START_TIMEOUT="${VLLM_METAL_START_TIMEOUT:-900}"
SMOKE_TEST="${VLLM_METAL_SMOKE_TEST:-true}"
SMOKE_TEST_PROMPT="${VLLM_METAL_SMOKE_TEST_PROMPT:-Reply with exactly READY.}"
DRY_RUN="${VLLM_METAL_DRY_RUN:-false}"
MODEL_REF="${VLLM_METAL_MODEL:-mlx-community/Qwen3.5-9B-4bit}"
BIN="${VLLM_METAL_BIN:-$HOME/.venv-vllm-metal/bin/vllm-metal}"

PID_FILE="${RUN_DIR}/vllm-metal.pid"
LOG_FILE="${RUN_DIR}/vllm-metal.log"
PORT_FILE="${RUN_DIR}/vllm-metal.port"

if [[ ! -x "${BIN}" ]]; then
  die "vllm-metal not found. Set VLLM_METAL_BIN or install it."
fi

CMD=(
  "${BIN}"
  --model
  "${MODEL_REF}"
  --host
  "${HOST}"
  --port
  "${PORT}"
)

if [[ -n "${VLLM_METAL_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CMD+=(${VLLM_METAL_EXTRA_FLAGS})
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
    echo "vllm-metal already running (pid ${pid})"
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
    echo "vllm-metal failed to start. Check log: ${LOG_FILE}"
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
started vllm-metal (pid ${pid})
- model: ${MODEL_REF}
- local url: http://${HOST}:${PORT}/v1
- log: ${LOG_FILE}
EOF
