#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${CI_SMOKE_TEST:-}" ]]; then
  echo "SKIP: Set CI_SMOKE_TEST=1 to run inference tests with Ministral 3B"
  exit 0
fi

MODEL_URL="https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512.Q4_K_M.gguf"
MODEL_CACHE="${REPO_ROOT}/.hf/ministral-3b.gguf"
PORT="${SMOKE_TEST_PORT:-18081}"
SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

download_model() {
  mkdir -p "$(dirname "${MODEL_CACHE}")"

  # Validate existing cache: GGUF files start with "GGUF" magic bytes
  if [[ -f "${MODEL_CACHE}" ]]; then
    if head -c 4 "${MODEL_CACHE}" 2>/dev/null | grep -q "GGUF"; then
      local size_mb
      size_mb=$(( $(stat -f%z "${MODEL_CACHE}" 2>/dev/null || stat -c%s "${MODEL_CACHE}" 2>/dev/null) / 1048576 ))
      if [[ "${size_mb}" -gt 2000 ]]; then
        echo "Model already cached and valid: ${MODEL_CACHE} (${size_mb} MB)"
        return 0
      fi
    fi
    echo "Cached model invalid or incomplete, re-downloading..."
    rm -f "${MODEL_CACHE}"
  fi

  echo "Downloading Ministral 3B Q4_K_M (~2.15 GB)..."
  curl -L --fail -o "${MODEL_CACHE}.tmp" "${MODEL_URL}"
  mv "${MODEL_CACHE}.tmp" "${MODEL_CACHE}"
}

start_llama_server() {
  echo "Starting llama-cpp-python server..."
  python -m llama_cpp.server \
    --model "${MODEL_CACHE}" \
    --host 127.0.0.1 \
    --port "${PORT}" \
    --n_ctx 4096 &
  SERVER_PID=$!

  local max_wait=60
  local waited=0
  while [[ "${waited}" -lt "${max_wait}" ]]; do
    if curl -s "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "Server ready after ${waited}s"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "FAIL: Server did not start within ${max_wait}s"
  exit 1
}

test_chat_completion() {
  echo "TEST: Real inference with Ministral 3B"
  local response
  response="$(curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "ministral",
      "messages": [{"role": "user", "content": "What is 2+2? Answer with just the number."}],
      "max_tokens": 10,
      "temperature": 0
    }')"

  echo "Response: ${response}"

  if echo "${response}" | grep -q '"choices"'; then
    echo "PASS: Got valid completion response"
  else
    echo "FAIL: Invalid response structure"
    return 1
  fi

  local content
  content="$(echo "${response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")"
  if echo "${content}" | grep -q "4"; then
    echo "PASS: Model answered correctly (contains 4)"
  else
    echo "WARN: Model answer may be wrong: ${content}"
  fi
}

echo "=== Smoke Test: Real Inference ==="

download_model
start_llama_server
test_chat_completion

echo ""
echo "Smoke test passed"
