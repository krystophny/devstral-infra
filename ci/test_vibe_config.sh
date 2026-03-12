#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

FAILED=0

test_fresh_config() {
  echo "TEST: Fresh config creation"
  local cfg="${TEST_DIR}/fresh/config.toml"
  rm -rf "${TEST_DIR}/fresh"

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null

  if [[ ! -f "${cfg}" ]]; then
    echo "FAIL: config file not created"
    return 1
  fi
  if grep -q 'active_model = "local"' "${cfg}"; then
    echo "PASS: active_model set"
  else
    echo "FAIL: active_model not set"
    return 1
  fi
  if grep -q 'enable_auto_update = false' "${cfg}"; then
    echo "PASS: enable_auto_update set to false"
  else
    echo "FAIL: enable_auto_update not set"
    return 1
  fi
}

test_existing_config() {
  echo "TEST: Update existing config (old settings backed up)"
  local cfg="${TEST_DIR}/existing/config.toml"
  local bak="${cfg}.devstral-infra.bak"
  mkdir -p "${TEST_DIR}/existing"
  cat > "${cfg}" <<'EOF'
# Existing config
active_model = "claude"
some_other_setting = "value"
EOF

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null

  if grep -q 'active_model = "local"' "${cfg}"; then
    echo "PASS: active_model updated"
  else
    echo "FAIL: active_model not updated"
    return 1
  fi
  if grep -q 'some_other_setting = "value"' "${bak}"; then
    echo "PASS: old settings preserved in backup"
  else
    echo "FAIL: old settings not found in backup"
    return 1
  fi
}

test_backup_created() {
  echo "TEST: Backup creation"
  local cfg="${TEST_DIR}/backup/config.toml"
  local bak="${cfg}.devstral-infra.bak"
  mkdir -p "${TEST_DIR}/backup"
  echo 'active_model = "original"' > "${cfg}"

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null

  if [[ -f "${bak}" ]]; then
    echo "PASS: backup created"
  else
    echo "FAIL: backup not created"
    return 1
  fi
  if grep -q 'active_model = "original"' "${bak}"; then
    echo "PASS: backup contains original content"
  else
    echo "FAIL: backup content wrong"
    return 1
  fi
}

test_idempotency() {
  echo "TEST: Idempotency (semantic, ignoring whitespace)"
  local cfg="${TEST_DIR}/idempotent/config.toml"
  mkdir -p "${TEST_DIR}/idempotent"

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null
  local first_run
  first_run="$(grep -v '^$' "${cfg}")"

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null
  local second_run
  second_run="$(grep -v '^$' "${cfg}")"

  if [[ "${first_run}" == "${second_run}" ]]; then
    echo "PASS: config semantically unchanged on second run"
  else
    echo "FAIL: config changed on second run"
    echo "First: ${first_run}"
    echo "Second: ${second_run}"
    return 1
  fi
}

test_provider_section() {
  echo "TEST: Provider section created"
  local cfg="${TEST_DIR}/provider/config.toml"
  rm -rf "${TEST_DIR}/provider"

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null

  if grep -q '\[\[providers\]\]' "${cfg}"; then
    echo "PASS: providers section exists"
  else
    echo "FAIL: providers section missing"
    return 1
  fi
  if grep -q 'api_key_env_var = ""' "${cfg}"; then
    echo "PASS: api_key_env_var empty (security)"
  else
    echo "FAIL: api_key_env_var not empty"
    return 1
  fi
}

test_restore() {
  echo "TEST: Restore from backup"
  local cfg="${TEST_DIR}/restore/config.toml"
  local bak="${cfg}.devstral-infra.bak"
  mkdir -p "${TEST_DIR}/restore"
  echo 'active_model = "original"' > "${cfg}"

  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_set_lmstudio.sh" >/dev/null
  VIBE_CONFIG_PATH="${cfg}" "${REPO_ROOT}/scripts/vibe_unset_local.sh" >/dev/null

  if grep -q 'active_model = "original"' "${cfg}"; then
    echo "PASS: config restored"
  else
    echo "FAIL: config not restored"
    return 1
  fi
}

echo "=== Vibe Config Tests ==="

test_fresh_config || FAILED=1
test_existing_config || FAILED=1
test_backup_created || FAILED=1
test_idempotency || FAILED=1
test_provider_section || FAILED=1
test_restore || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
