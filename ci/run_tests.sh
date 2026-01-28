#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "       devstral-infra Test Suite"
echo "========================================"
echo ""

FAILED=0

run_test() {
  local name="$1"
  local script="$2"
  echo "----------------------------------------"
  echo "Running: ${name}"
  echo "----------------------------------------"
  if bash "${script}"; then
    echo ""
  else
    echo "FAILED: ${name}"
    echo ""
    FAILED=1
  fi
}

run_test "Setup Script Tests" "${SCRIPT_DIR}/test_setup.sh"
run_test "Hardware Detection Tests" "${SCRIPT_DIR}/test_hardware_detect.sh"
run_test "Vibe Config Tests" "${SCRIPT_DIR}/test_vibe_config.sh"
run_test "Security Tests" "${SCRIPT_DIR}/test_security.sh"
run_test "Mock Server Health Tests" "${SCRIPT_DIR}/test_server_health.sh"

if [[ -n "${CI_SMOKE_TEST:-}" ]]; then
  run_test "Smoke Test: Real Inference" "${SCRIPT_DIR}/test_server_inference.sh"
fi

echo "========================================"
if [[ "${FAILED}" -eq 0 ]]; then
  echo "        All Tests Passed"
else
  echo "        Some Tests Failed"
fi
echo "========================================"

exit "${FAILED}"
