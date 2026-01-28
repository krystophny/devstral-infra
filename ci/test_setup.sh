#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/_common.sh"

FAILED=0

test_platform_detection() {
  echo "TEST: Platform detection"
  local platform
  platform="$(detect_platform)"
  case "${platform}" in
    mac|linux|wsl)
      echo "PASS: valid platform detected (${platform})"
      ;;
    *)
      echo "FAIL: invalid platform (${platform})"
      return 1
      ;;
  esac
}

test_ram_detection() {
  echo "TEST: RAM detection"
  local ram_mb
  ram_mb="$(detect_ram_mb)"
  if [[ "${ram_mb}" -gt 0 ]]; then
    echo "PASS: RAM detected (${ram_mb} MB)"
  else
    echo "FAIL: RAM not detected or zero"
    return 1
  fi
}

test_vram_detection() {
  echo "TEST: VRAM detection"
  local vram_mb
  vram_mb="$(detect_vram_mb)"
  if [[ "${vram_mb}" -ge 0 ]]; then
    echo "PASS: VRAM detected (${vram_mb} MB)"
  else
    echo "FAIL: VRAM detection failed"
    return 1
  fi
}

test_gpu_detection() {
  echo "TEST: GPU detection"
  local gpu
  gpu="$(detect_gpu)"
  case "${gpu}" in
    metal|cuda|cpu)
      echo "PASS: valid GPU backend detected (${gpu})"
      ;;
    *)
      echo "FAIL: invalid GPU backend (${gpu})"
      return 1
      ;;
  esac
}

test_model_memory_requirements() {
  echo "TEST: Model memory requirements lookup"
  local mem
  mem="$(model_memory_requirements Q4_K_M 24B)"
  if [[ "${mem}" == "14300" ]]; then
    echo "PASS: 24B Q4_K_M = 14300 MB"
  else
    echo "FAIL: 24B Q4_K_M expected 14300, got ${mem}"
    return 1
  fi

  mem="$(model_memory_requirements Q4_K_M 123B)"
  if [[ "${mem}" == "74900" ]]; then
    echo "PASS: 123B Q4_K_M = 74900 MB"
  else
    echo "FAIL: 123B Q4_K_M expected 74900, got ${mem}"
    return 1
  fi
}

test_auto_config_with_override() {
  echo "TEST: Auto config with env override"
  local config
  DEVSTRAL_MODEL="test/model" DEVSTRAL_MAX_MODEL_LEN="12345" \
    config="$(auto_config)"
  local model ctx
  model="$(echo "${config}" | cut -d'|' -f1)"
  ctx="$(echo "${config}" | cut -d'|' -f2)"

  if [[ "${model}" == "test/model" ]]; then
    echo "PASS: model override works"
  else
    echo "FAIL: model override failed (${model})"
    return 1
  fi
  if [[ "${ctx}" == "12345" ]]; then
    echo "PASS: context override works"
  else
    echo "FAIL: context override failed (${ctx})"
    return 1
  fi
}

test_model_id_from_config() {
  echo "TEST: Model ID from config"
  local model_id

  model_id="$(model_id_from_config 24B Q4_K_M)"
  if [[ "${model_id}" == "mistralai/Devstral-Small-2-24B-Instruct-2512" ]]; then
    echo "PASS: 24B -> correct model ID"
  else
    echo "FAIL: 24B model ID wrong (${model_id})"
    return 1
  fi

  model_id="$(model_id_from_config 123B Q4_K_M)"
  if [[ "${model_id}" == "mistralai/Devstral-2-123B-Instruct-2512" ]]; then
    echo "PASS: 123B -> correct model ID"
  else
    echo "FAIL: 123B model ID wrong (${model_id})"
    return 1
  fi
}

echo "=== Setup Script Tests ==="

test_platform_detection || FAILED=1
test_ram_detection || FAILED=1
test_vram_detection || FAILED=1
test_gpu_detection || FAILED=1
test_model_memory_requirements || FAILED=1
test_auto_config_with_override || FAILED=1
test_model_id_from_config || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
