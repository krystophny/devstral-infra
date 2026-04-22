#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

test_server_start_dry_run() {
  echo "TEST: llama.cpp launcher dry-run profile"
  local home_dir="${TMPDIR}/home"
  local model_path="${TMPDIR}/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"

  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
    LLAMACPP_MODEL="${model_path}" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  local platform cpu_moe_ok=1
  platform="$(uname -s)"
  if [[ "${platform}" == "Darwin" ]]; then
    [[ "${output}" != *"--cpu-moe"* ]] || cpu_moe_ok=0
  else
    [[ "${output}" == *"--cpu-moe"* ]] || cpu_moe_ok=0
  fi

  if [[ "${output}" == *"-c 131072"* && \
        "${output}" == *"--cache-type-k q8_0"* && \
        "${output}" == *"--cache-type-v q8_0"* && \
        "${output}" == *"-fa on"* && \
        "${output}" == *"--alias qwen"* && \
        "${output}" == *"--jinja"* && \
        "${output}" == *"--reasoning on"* && \
        "${output}" == *"--port 8080"* && \
        "${output}" == *"Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"* && \
        "${cpu_moe_ok}" == "1" ]]; then
    echo "PASS: launcher emits the blessed profile"
  else
    echo "FAIL: launcher profile mismatch"
    echo "${output}"
    return 1
  fi
}

test_opencode_config() {
  echo "TEST: OpenCode llama.cpp config generation"
  local home_dir="${TMPDIR}/home-config"
  local config_path="${TMPDIR}/opencode.json"
  mkdir -p "${home_dir}"

  HOME="${home_dir}" \
  OPENCODE_CONFIG_PATH="${config_path}" \
  bash "${REPO_ROOT}/scripts/opencode_set_llamacpp.sh" >/dev/null

  if grep -q '"model": "llamacpp/qwen3.6-35b-a3b-q4"' "${config_path}" && \
     grep -q '"disable": true' "${config_path}" && \
     grep -q '"permission": "allow"' "${config_path}" && \
     grep -q '"context": 131072' "${config_path}" && \
     grep -q '"output": 16384' "${config_path}" && \
     grep -q '"reasoning": true' "${config_path}" && \
     grep -q '"thinking_budget": 4096' "${config_path}" && \
     grep -q '"temperature": 0.6' "${config_path}" && \
     grep -q '"top_p": 0.95' "${config_path}" && \
     grep -q '"top_k": 20' "${config_path}" && \
     grep -q '"min_p": 0.0' "${config_path}" && \
     grep -q '"presence_penalty": 0.0' "${config_path}" && \
     grep -q '"repeat_penalty": 1.0' "${config_path}" && \
     grep -q 'http://127.0.0.1:8080/v1' "${config_path}" && \
     grep -q '"disabled_providers": \["exa", "openai", "anthropic"' "${config_path}"; then
    echo "PASS: OpenCode config matches the blessed profile"
  else
    echo "FAIL: OpenCode config missing expected fields"
    cat "${config_path}"
    return 1
  fi
}

test_models_default_alias() {
  echo "TEST: llamacpp_models.py default alias"
  local alias
  alias="$(python3 "${REPO_ROOT}/scripts/llamacpp_models.py" default-alias)"
  if [[ "${alias}" == "qwen3.6-35b-a3b-q4" ]]; then
    echo "PASS: default alias is qwen3.6-35b-a3b-q4"
  else
    echo "FAIL: default alias was '${alias}'"
    return 1
  fi
}

test_server_start_dry_run || FAILED=$((FAILED + 1))
test_opencode_config || FAILED=$((FAILED + 1))
test_models_default_alias || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then
  echo "${FAILED} test(s) failed"
  exit 1
fi
echo "all llama.cpp profile tests passed"
