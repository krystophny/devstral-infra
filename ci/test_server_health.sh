#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MOCK_PORT="${MOCK_PORT:-18080}"
MOCK_PID=""

cleanup() {
  if [[ -n "${MOCK_PID}" ]]; then
    kill "${MOCK_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_mock_server() {
  python3 "${SCRIPT_DIR}/mock_server.py" --port "${MOCK_PORT}" &
  MOCK_PID=$!
  sleep 1
  if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
    echo "FAIL: mock server failed to start"
    exit 1
  fi
}

test_health_endpoint() {
  echo "TEST: /health endpoint"
  local response
  response="$(curl -s "http://127.0.0.1:${MOCK_PORT}/health")"
  if echo "${response}" | grep -q '"status"'; then
    echo "PASS: /health returns status"
  else
    echo "FAIL: /health missing status field"
    echo "Response: ${response}"
    return 1
  fi
}

test_models_endpoint() {
  echo "TEST: /v1/models endpoint"
  local response
  response="$(curl -s "http://127.0.0.1:${MOCK_PORT}/v1/models")"
  if echo "${response}" | grep -q '"data"'; then
    echo "PASS: /v1/models returns data"
  else
    echo "FAIL: /v1/models missing data field"
    echo "Response: ${response}"
    return 1
  fi
}

test_chat_completions() {
  echo "TEST: /v1/chat/completions endpoint"
  local response
  response="$(curl -s "http://127.0.0.1:${MOCK_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"mock","messages":[{"role":"user","content":"Hello"}]}')"
  if echo "${response}" | grep -q '"choices"'; then
    echo "PASS: /v1/chat/completions returns choices"
  else
    echo "FAIL: /v1/chat/completions missing choices field"
    echo "Response: ${response}"
    return 1
  fi
}

echo "=== Mock Server Health Tests ==="
start_mock_server

FAILED=0
test_health_endpoint || FAILED=1
test_models_endpoint || FAILED=1
test_chat_completions || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
