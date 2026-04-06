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
  local run_dir="${REPO_ROOT}/.run"
  local pid_file="${run_dir}/llamacpp-local.pid"
  local port_file="${run_dir}/llamacpp-local.port"
  local backup_dir="${TMPDIR}/run-backup"
  mkdir -p "${home_dir}/.local/llama.cpp" "${home_dir}/.cache"
  mkdir -p "${backup_dir}"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"

  if [[ -f "${pid_file}" ]]; then mv "${pid_file}" "${backup_dir}/llamacpp-local.pid"; fi
  if [[ -f "${port_file}" ]]; then mv "${port_file}" "${backup_dir}/llamacpp-local.port"; fi

  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_MODEL="${TMPDIR}/Qwen3.5-122B-A10B-Q8_0-00001-of-00004.gguf" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ -f "${backup_dir}/llamacpp-local.pid" ]]; then mv "${backup_dir}/llamacpp-local.pid" "${pid_file}"; fi
  if [[ -f "${backup_dir}/llamacpp-local.port" ]]; then mv "${backup_dir}/llamacpp-local.port" "${port_file}"; fi

  if [[ "${output}" == *"-c 131072"* && \
        "${output}" == *"--ctx-checkpoints 64"* && \
        "${output}" == *"--checkpoint-every-n-tokens 4096"* && \
        "${output}" == *"-b 2048"* && \
        "${output}" == *"-ub 512"* && \
        "${output}" == *"--temp 0.6"* && \
        "${output}" == *"--top-p 0.95"* && \
        "${output}" == *"--top-k 20"* && \
        "${output}" == *"--min-p 0"* && \
        "${output}" == *"--presence-penalty 0.0"* && \
        "${output}" == *"--repeat-penalty 1.0"* && \
        "${output}" == *"--reasoning-format deepseek"* && \
        "${output}" == *"--no-context-shift"* && \
        "${output}" == *"--host 0.0.0.0"* && \
        "${output}" != *"--reasoning off"* && \
        "${output}" != *"--no-webui"* && \
        "${output}" != *"enable_thinking"* && \
        "${output}" == *"Qwen3.5-122B-A10B-Q8_0-00001-of-00004.gguf"* ]]; then
    echo "PASS: launcher emits the recommended local profile"
  else
    echo "FAIL: launcher output did not include the expected profile"
    echo "${output}"
    return 1
  fi
}

test_server_start_family_profiles() {
  echo "TEST: llama.cpp launcher emits family-specific profiles"

  local home_dir="${TMPDIR}/home-family"
  mkdir -p "${home_dir}/.local/llama.cpp" "${home_dir}/.cache"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"

  local devstral
  devstral="$(
    HOME="${home_dir}" \
    LLAMACPP_DRY_RUN=true \
    LLAMACPP_MODEL_ALIAS=devstral-2-123b \
    LLAMACPP_SMOKE_TEST=false \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  local nemotron
  nemotron="$(
    HOME="${home_dir}" \
    LLAMACPP_DRY_RUN=true \
    LLAMACPP_MODEL_ALIAS=nemotron-120b-a12b \
    LLAMACPP_SMOKE_TEST=false \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  local gptoss
  gptoss="$(
    HOME="${home_dir}" \
    LLAMACPP_DRY_RUN=true \
    LLAMACPP_MODEL_ALIAS=gpt-oss-120b \
    LLAMACPP_SMOKE_TEST=false \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${devstral}" == *"--temp 0.15"* && \
        "${devstral}" != *"--top-p"* && \
        "${nemotron}" == *"--temp 1.0"* && \
        "${nemotron}" == *"--top-p 0.95"* && \
        "${gptoss}" != *"--temp"* && \
        "${gptoss}" != *"--top-p"* ]]; then
    echo "PASS: launcher applies the expected family-specific sampling defaults"
  else
    echo "FAIL: family-specific launcher profiles are wrong"
    echo "--- devstral ---"
    echo "${devstral}"
    echo "--- nemotron ---"
    echo "${nemotron}"
    echo "--- gpt-oss ---"
    echo "${gptoss}"
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

  if grep -q '"model": "llamacpp/qwen3.5-9b"' "${config_path}" && \
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
     grep -q 'http://127.0.0.1:8081/v1' "${config_path}"; then
    echo "PASS: OpenCode config uses the recommended local profile"
  else
    echo "FAIL: OpenCode config missing expected fields"
    cat "${config_path}"
    return 1
  fi
}

test_exec_start_output() {
  echo "TEST: llama.cpp launcher ExecStart rendering"

  local home_dir="${TMPDIR}/home-exec-start"
  mkdir -p "${home_dir}/.local/llama.cpp" "${home_dir}/.cache"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"

  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_MODEL="${TMPDIR}/Qwen3.5-9B-Q8_0.gguf" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_PRINT_EXEC_START=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh" fast
  )"

  if [[ "${output}" == "${home_dir}/.local/llama.cpp/llama-server"* && \
        "${output}" == *"--port 8081"* && \
        "${output}" != *"Starting llama.cpp server"* && \
        "${output}" != *"--reasoning off"* && \
        "${output}" != *"--no-webui"* ]]; then
    echo "PASS: ExecStart rendering stays reasoning-capable and WebUI-enabled"
  else
    echo "FAIL: ExecStart rendering incorrect"
    echo "${output}"
    return 1
  fi
}

test_aider_config() {
  echo "TEST: aider llama.cpp config generation"

  local home_dir="${TMPDIR}/home-aider"
  mkdir -p "${home_dir}"

  HOME="${home_dir}" \
  bash "${REPO_ROOT}/scripts/aider_set_llamacpp.sh" >/dev/null

  local conf="${home_dir}/.aider.conf.yml"
  local settings="${home_dir}/.aider.model.settings.yml"

  if grep -q 'model: openai/qwen' "${conf}" && \
     grep -q 'openai-api-base: http://127.0.0.1:8080/v1' "${conf}" && \
     grep -q 'auto-commits: false' "${conf}" && \
     grep -q 'edit-format: diff' "${conf}" && \
     grep -q 'name: openai/qwen' "${settings}" && \
     grep -q 'temperature: 0.6' "${settings}" && \
     grep -q 'top_p: 0.95' "${settings}"; then
    echo "PASS: aider config uses the recommended local profile"
  else
    echo "FAIL: aider config missing expected fields"
    echo "--- .aider.conf.yml ---"
    cat "${conf}"
    echo "--- .aider.model.settings.yml ---"
    cat "${settings}"
    return 1
  fi
}

test_qwencode_config() {
  echo "TEST: qwen-code llama.cpp config generation"

  local home_dir="${TMPDIR}/home-qwencode"
  mkdir -p "${home_dir}"

  HOME="${home_dir}" \
  bash "${REPO_ROOT}/scripts/qwencode_set_llamacpp.sh" >/dev/null

  local config="${home_dir}/.qwen/settings.json"

  if grep -q '"id": "qwen"' "${config}" && \
     grep -q 'http://127.0.0.1:8080/v1' "${config}" && \
     grep -q '"contextWindowSize": 262144' "${config}" && \
     grep -q '"temperature": 0.6' "${config}" && \
     grep -q '"selectedType": "openai"' "${config}" && \
     grep -q '"approvalMode": "yolo"' "${config}"; then
    echo "PASS: qwen-code config uses the recommended local profile"
  else
    echo "FAIL: qwen-code config missing expected fields"
    cat "${config}"
    return 1
  fi
}

test_codex_config() {
  echo "TEST: Codex llama.cpp config generation (fresh)"

  local home_dir="${TMPDIR}/home-codex"
  local config_path="${TMPDIR}/codex-config.toml"
  local catalog_path="${TMPDIR}/codex-catalog.json"
  mkdir -p "${home_dir}"

  HOME="${home_dir}" \
  CODEX_CONFIG_PATH="${config_path}" \
  CODEX_CATALOG_PATH="${catalog_path}" \
  bash "${REPO_ROOT}/scripts/codex_set_llamacpp.sh" >/dev/null

  if grep -q 'wire_api = "responses"' "${config_path}" && \
     grep -q 'base_url = "http://127.0.0.1:8080/v1"' "${config_path}" && \
     grep -q 'base_url = "http://127.0.0.1:8081/v1"' "${config_path}" && \
     grep -q '\[profiles.local\]' "${config_path}" && \
     grep -q '\[profiles.fast\]' "${config_path}" && \
     grep -q 'web_search = "disabled"' "${config_path}" && \
     grep -q 'model_provider = "local"' "${config_path}" && \
     grep -q 'model_provider = "fast"' "${config_path}" && \
     grep -q 'model_catalog_json' "${config_path}"; then
    echo "PASS: Codex config has both local and fast profiles with Responses API"
  else
    echo "FAIL: Codex config missing expected fields"
    cat "${config_path}"
    return 1
  fi
}

test_codex_model_catalog() {
  echo "TEST: Codex model catalog JSON generation"

  local home_dir="${TMPDIR}/home-codex-catalog"
  local config_path="${TMPDIR}/codex-catalog-cfg.toml"
  local catalog_path="${TMPDIR}/codex-models.json"
  mkdir -p "${home_dir}"

  HOME="${home_dir}" \
  CODEX_CONFIG_PATH="${config_path}" \
  CODEX_CATALOG_PATH="${catalog_path}" \
  CODEX_LOCAL_MODEL="Qwen3.5-122B-A10B" \
  CODEX_FAST_MODEL="Qwen3.5-9B" \
  CODEX_LOCAL_CONTEXT=262144 \
  CODEX_FAST_CONTEXT=32768 \
  bash "${REPO_ROOT}/scripts/codex_set_llamacpp.sh" >/dev/null

  if [[ ! -f "${catalog_path}" ]]; then
    echo "FAIL: catalog file not created"
    return 1
  fi

  local valid
  valid="$(python3 - "${catalog_path}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
models = data.get("models", [])
if len(models) != 2:
    print(f"FAIL: expected 2 models, got {len(models)}")
    sys.exit(1)
slugs = [m["slug"] for m in models]
if "Qwen3.5-122B-A10B" not in slugs:
    print(f"FAIL: missing Qwen3.5-122B-A10B slug, got {slugs}")
    sys.exit(1)
if "Qwen3.5-9B" not in slugs:
    print(f"FAIL: missing Qwen3.5-9B slug, got {slugs}")
    sys.exit(1)
for m in models:
    for field in ("base_instructions", "context_window", "truncation_policy",
                  "supports_parallel_tool_calls", "auto_compact_token_limit"):
        if field not in m:
            print(f"FAIL: model {m['slug']} missing field {field}")
            sys.exit(1)
local = [m for m in models if m["slug"] == "Qwen3.5-122B-A10B"][0]
fast = [m for m in models if m["slug"] == "Qwen3.5-9B"][0]
if local["context_window"] != 262144:
    print(f"FAIL: local context_window={local['context_window']}, expected 262144")
    sys.exit(1)
if fast["context_window"] != 32768:
    print(f"FAIL: fast context_window={fast['context_window']}, expected 32768")
    sys.exit(1)
if local["truncation_policy"]["mode"] != "tokens":
    print(f"FAIL: truncation mode={local['truncation_policy']['mode']}, expected tokens")
    sys.exit(1)
print("OK")
PY
  )"

  if [[ "${valid}" == "OK" ]]; then
    echo "PASS: model catalog has correct slugs, context windows, and required fields"
  else
    echo "FAIL: ${valid}"
    cat "${catalog_path}"
    return 1
  fi
}

test_codex_config_preserves_existing() {
  echo "TEST: Codex config preserves existing content"

  local home_dir="${TMPDIR}/home-codex-existing"
  local config_path="${TMPDIR}/codex-config-existing.toml"
  mkdir -p "${home_dir}"

  cat > "${config_path}" <<'EXISTING'
model = "gpt-5.3-codex"
model_provider = "openai"

[projects."/Users/test"]
trust_level = "trusted"

[mcp_servers.tabura]
EXISTING

  HOME="${home_dir}" \
  CODEX_CONFIG_PATH="${config_path}" \
  bash "${REPO_ROOT}/scripts/codex_set_llamacpp.sh" >/dev/null

  if grep -q 'model = "gpt-5.3-codex"' "${config_path}" && \
     grep -q '\[projects."/Users/test"\]' "${config_path}" && \
     grep -q '\[mcp_servers.tabura\]' "${config_path}" && \
     grep -q '\[model_providers.local\]' "${config_path}" && \
     grep -q 'web_search = "disabled"' "${config_path}"; then
    echo "PASS: Codex config preserves existing content and appends local profiles"
  else
    echo "FAIL: Codex config did not preserve existing content"
    cat "${config_path}"
    return 1
  fi
}

test_codex_config_updates_existing_block() {
  echo "TEST: Codex config updates existing devstral block"

  local home_dir="${TMPDIR}/home-codex-update"
  local config_path="${TMPDIR}/codex-config-update.toml"
  mkdir -p "${home_dir}"

  cat > "${config_path}" <<'EXISTING'
model = "gpt-5.3-codex"

# BEGIN DEVSTRAL LOCAL MODELS
[model_providers.local]
name = "old"
base_url = "http://127.0.0.1:9999/v1"
wire_api = "responses"
# END DEVSTRAL LOCAL MODELS
EXISTING

  HOME="${home_dir}" \
  CODEX_CONFIG_PATH="${config_path}" \
  CODEX_LOCAL_MODEL="qwen3.5-35b" \
  bash "${REPO_ROOT}/scripts/codex_set_llamacpp.sh" >/dev/null

  if grep -q 'model = "gpt-5.3-codex"' "${config_path}" && \
     grep -q 'base_url = "http://127.0.0.1:8080/v1"' "${config_path}" && \
     grep -q 'model = "qwen3.5-35b"' "${config_path}" && \
     ! grep -q 'base_url = "http://127.0.0.1:9999/v1"' "${config_path}"; then
    echo "PASS: Codex config replaced old block with new settings"
  else
    echo "FAIL: Codex config did not update correctly"
    cat "${config_path}"
    return 1
  fi
}

test_dual_instance_dry_run() {
  echo "TEST: llama.cpp dual-instance dry-run (fast profile)"

  local home_dir="${TMPDIR}/home-dual"
  local run_dir="${REPO_ROOT}/.run"
  local pid_file="${run_dir}/llamacpp-fast.pid"
  local port_file="${run_dir}/llamacpp-fast.port"
  local backup_dir="${TMPDIR}/run-backup-dual"
  mkdir -p "${home_dir}/.local/llama.cpp" "${home_dir}/.cache" "${backup_dir}"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"

  if [[ -f "${pid_file}" ]]; then mv "${pid_file}" "${backup_dir}/llamacpp-fast.pid"; fi
  if [[ -f "${port_file}" ]]; then mv "${port_file}" "${backup_dir}/llamacpp-fast.port"; fi

  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_MODEL="${TMPDIR}/Qwen3.5-9B-Q8_0.gguf" \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh" fast
  )"

  if [[ -f "${backup_dir}/llamacpp-fast.pid" ]]; then mv "${backup_dir}/llamacpp-fast.pid" "${pid_file}"; fi
  if [[ -f "${backup_dir}/llamacpp-fast.port" ]]; then mv "${backup_dir}/llamacpp-fast.port" "${port_file}"; fi

  if [[ "${output}" == *"--port 8081"* && \
        "${output}" == *"-c 131072"* && \
        "${output}" != *"--reasoning off"* && \
        "${output}" != *"--no-webui"* ]]; then
    echo "PASS: fast instance uses port 8081, 131K context, thinking on, WebUI on"
  else
    echo "FAIL: fast instance dry-run output incorrect"
    echo "${output}"
    return 1
  fi
}

echo "=== llama.cpp Profile Tests ==="

test_server_start_dry_run || FAILED=1
test_server_start_family_profiles || FAILED=1
test_dual_instance_dry_run || FAILED=1
test_exec_start_output || FAILED=1
test_opencode_config || FAILED=1
test_aider_config || FAILED=1
test_qwencode_config || FAILED=1
test_codex_config || FAILED=1
test_codex_model_catalog || FAILED=1
test_codex_config_preserves_existing || FAILED=1
test_codex_config_updates_existing_block || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
