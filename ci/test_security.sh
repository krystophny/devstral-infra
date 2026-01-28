#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0

test_vibe_config_no_api_key() {
  echo "TEST: Vibe config has empty api_key_env_var"
  local cfg
  cfg="$(mktemp)"
  trap "rm -f ${cfg}" RETURN

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_local.sh" >/dev/null

  if grep -q 'api_key_env_var = ""' "${cfg}"; then
    echo "PASS: api_key_env_var is empty"
  else
    echo "FAIL: api_key_env_var should be empty for security"
    return 1
  fi
}

test_vibe_config_auto_update_disabled() {
  echo "TEST: Vibe config has auto_update disabled"
  local cfg
  cfg="$(mktemp)"
  trap "rm -f ${cfg}" RETURN

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_local.sh" >/dev/null

  if grep -q 'enable_auto_update = false' "${cfg}"; then
    echo "PASS: enable_auto_update is false"
  else
    echo "FAIL: enable_auto_update should be false for security"
    return 1
  fi
}

test_vibe_config_update_checks_disabled() {
  echo "TEST: Vibe config has update_checks disabled"
  local cfg
  cfg="$(mktemp)"
  trap "rm -f ${cfg}" RETURN

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_local.sh" >/dev/null

  if grep -q 'enable_update_checks = false' "${cfg}"; then
    echo "PASS: enable_update_checks is false"
  else
    echo "FAIL: enable_update_checks should be false to prevent phone-home"
    return 1
  fi
}

test_server_binds_localhost() {
  echo "TEST: Server start script defaults to localhost"
  if grep -q 'DEVSTRAL_HOST:-127.0.0.1' "${REPO_ROOT}/scripts/server_start.sh"; then
    echo "PASS: default host is 127.0.0.1"
  else
    echo "FAIL: default host should be 127.0.0.1"
    return 1
  fi
}

test_security_harden_script_exists() {
  echo "TEST: Security harden script exists and is executable"
  if [[ -x "${REPO_ROOT}/scripts/security_harden.sh" ]]; then
    echo "PASS: security_harden.sh exists and is executable"
  else
    echo "FAIL: security_harden.sh missing or not executable"
    return 1
  fi
}

test_security_unharden_script_exists() {
  echo "TEST: Security unharden script exists and is executable"
  if [[ -x "${REPO_ROOT}/scripts/security_unharden.sh" ]]; then
    echo "PASS: security_unharden.sh exists and is executable"
  else
    echo "FAIL: security_unharden.sh missing or not executable"
    return 1
  fi
}

echo "=== Security Tests ==="

test_vibe_config_no_api_key || FAILED=1
test_vibe_config_auto_update_disabled || FAILED=1
test_vibe_config_update_checks_disabled || FAILED=1
test_server_binds_localhost || FAILED=1
test_security_harden_script_exists || FAILED=1
test_security_unharden_script_exists || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
