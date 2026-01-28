#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0

# These tests use list_viable_configs directly with explicit platform/gpu
# to test the config mapping logic independent of actual hardware detection.

test_config_256gb_mac() {
  echo "TEST: 256GB Mac -> 123B full context"
  local config
  config="$(list_viable_configs 192000 256000 mac metal | head -1)"
  local model_size ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  if [[ "${model_size}" == "123B" && "${ctx}" == "262144" ]]; then
    echo "PASS: 256GB Mac selects 123B with 262K context"
  else
    echo "FAIL: got ${model_size} with ${ctx} context"
    return 1
  fi
}

test_config_128gb_mac() {
  echo "TEST: 128GB Mac -> 123B 8K context (96GB usable < 103GB for 32K)"
  local config
  config="$(list_viable_configs 96000 128000 mac metal | head -1)"
  local model_size ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  if [[ "${model_size}" == "123B" && "${ctx}" == "8192" ]]; then
    echo "PASS: 128GB Mac selects 123B with 8K context"
  else
    echo "FAIL: got ${model_size} with ${ctx} context"
    return 1
  fi
}

test_config_64gb_mac() {
  echo "TEST: 64GB Mac -> 24B 131K context (48GB usable < 55GB for 262K)"
  local config
  config="$(list_viable_configs 48000 64000 mac metal | head -1)"
  local model_size ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  if [[ "${model_size}" == "24B" && "${ctx}" == "131072" ]]; then
    echo "PASS: 64GB Mac selects 24B with 131K context"
  else
    echo "FAIL: got ${model_size} with ${ctx} context"
    return 1
  fi
}

test_config_24gb_cuda() {
  echo "TEST: 24GB CUDA VRAM -> 24B 57K context"
  local config
  config="$(list_viable_configs 24000 64000 linux cuda | head -1)"
  local model_size ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  if [[ "${model_size}" == "24B" && "${ctx}" == "57344" ]]; then
    echo "PASS: 24GB CUDA VRAM selects 24B with 57K context"
  else
    echo "FAIL: got ${model_size} with ${ctx} context"
    return 1
  fi
}

test_config_16gb_mac() {
  echo "TEST: 16GB Mac -> 24B 8K context"
  local config
  config="$(list_viable_configs 16000 24000 mac metal | head -1)"
  local model_size ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  if [[ "${model_size}" == "24B" && "${ctx}" == "8192" ]]; then
    echo "PASS: 16GB Mac selects 24B with 8K context"
  else
    echo "FAIL: got ${model_size} with ${ctx} context"
    return 1
  fi
}

test_config_12gb_cuda() {
  echo "TEST: 12GB CUDA VRAM -> 24B 8K context"
  local config
  config="$(list_viable_configs 12000 32000 linux cuda | head -1)"
  local model_size ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  if [[ "${model_size}" == "24B" && "${ctx}" == "8192" ]]; then
    echo "PASS: 12GB CUDA VRAM selects 24B with 8K context"
  else
    echo "FAIL: got ${model_size} with ${ctx} context"
    return 1
  fi
}

test_list_viable_configs_mac() {
  echo "TEST: list_viable_configs returns multiple options for Mac"
  local count
  count="$(list_viable_configs 96000 128000 mac metal | wc -l | tr -d ' ')"
  if [[ "${count}" -gt 1 ]]; then
    echo "PASS: ${count} configs available for 128GB Mac"
  else
    echo "FAIL: only ${count} config(s) available"
    return 1
  fi
}

test_list_viable_configs_cuda() {
  echo "TEST: list_viable_configs returns multiple options for CUDA"
  local count
  count="$(list_viable_configs 48000 64000 linux cuda | wc -l | tr -d ' ')"
  if [[ "${count}" -gt 1 ]]; then
    echo "PASS: ${count} configs available for 48GB CUDA"
  else
    echo "FAIL: only ${count} config(s) available"
    return 1
  fi
}

test_context_memory_overhead() {
  echo "TEST: Context memory overhead lookup"
  local overhead

  overhead="$(context_memory_overhead 32768 24B)"
  if [[ "${overhead}" == "5000" ]]; then
    echo "PASS: 24B 32K overhead = 5000 MB"
  else
    echo "FAIL: expected 5000, got ${overhead}"
    return 1
  fi

  overhead="$(context_memory_overhead 262144 123B)"
  if [[ "${overhead}" == "96000" ]]; then
    echo "PASS: 123B 262K overhead = 96000 MB"
  else
    echo "FAIL: expected 96000, got ${overhead}"
    return 1
  fi
}

echo "=== Hardware Detection Tests ==="

test_config_256gb_mac || FAILED=1
test_config_128gb_mac || FAILED=1
test_config_64gb_mac || FAILED=1
test_config_24gb_cuda || FAILED=1
test_config_16gb_mac || FAILED=1
test_config_12gb_cuda || FAILED=1
test_list_viable_configs_mac || FAILED=1
test_list_viable_configs_cuda || FAILED=1
test_context_memory_overhead || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
