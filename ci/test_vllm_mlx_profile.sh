#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

test_registry_resolution() {
  echo "TEST: vllm-mlx model registry resolution"
  local repo
  repo="$(python3 "${REPO_ROOT}/scripts/vllm_mlx_models.py" resolve qwen3.5-27b --field repo_id)"
  if [[ "${repo}" == "mlx-community/Qwen3.5-27B-8bit" ]]; then
    echo "PASS: registry resolves canonical MLX repo ids"
  else
    echo "FAIL: unexpected repo id: ${repo}"
    return 1
  fi
}

test_server_start_dry_run() {
  echo "TEST: vllm-mlx launcher dry-run profile"
  local output
  output="$(
    VLLM_MLX_PYTHON="/Users/user/code/.venv/bin/python" \
    VLLM_MLX_REPO="/Users/user/code/vllm-mlx" \
    VLLM_MLX_MODEL_ALIAS="qwen3.5-4b" \
    VLLM_MLX_SERVED_MODEL_NAME="Qwen3.5-4B" \
    VLLM_MLX_SMOKE_TEST=false \
    VLLM_MLX_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_vllm_mlx.sh"
  )"
  if [[ "${output}" == *"vllm_mlx.cli serve"* && \
        "${output}" == *"mlx-community/Qwen3.5-4B-MLX-8bit"* && \
        "${output}" == *"--served-model-name Qwen3.5-4B"* && \
        "${output}" == *"--host 0.0.0.0"* && \
        "${output}" == *"--tool-call-parser qwen"* && \
        "${output}" == *"--reasoning-parser qwen3"* && \
        "${output}" == *"--continuous-batching"* && \
        "${output}" != *"--use-paged-cache"* ]]; then
    echo "PASS: launcher emits the expected continuous-batching LAN profile"
  else
    echo "FAIL: launcher output did not include expected fields"
    echo "${output}"
    return 1
  fi
}

test_server_start_default_local_profile() {
  echo "TEST: vllm-mlx launcher default local profile"
  local output
  output="$(
    VLLM_MLX_PYTHON="/Users/user/code/.venv/bin/python" \
    VLLM_MLX_REPO="/Users/user/code/vllm-mlx" \
    VLLM_MLX_SMOKE_TEST=false \
    VLLM_MLX_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_vllm_mlx.sh"
  )"
  if [[ "${output}" == *"mlx-community/Qwen3-Coder-Next-8bit"* && \
        "${output}" == *"--served-model-name qwen"* && \
        "${output}" == *"--host 0.0.0.0"* && \
        "${output}" == *"--max-tokens 262144"* && \
        "${output}" == *"--tool-call-parser qwen3_coder"* && \
        "${output}" == *"--reasoning-parser qwen3"* ]]; then
    echo "PASS: local launcher defaults to the coder-next LAN profile"
  else
    echo "FAIL: local launcher default profile is not the expected coder-next config"
    echo "${output}"
    return 1
  fi
}

test_server_start_requires_served_model_name_support() {
  echo "TEST: vllm-mlx launcher fails fast without --served-model-name support"
  local fake_python="${TMPDIR}/fake-vllm-python.sh"
  local fake_repo="${TMPDIR}/fake-vllm-repo"
  mkdir -p "${fake_repo}"
  cat > "${fake_python}" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-m vllm_mlx.cli serve --help"* ]]; then
  cat <<'HELP'
usage: cli.py serve [-h] [--host HOST] [--port PORT]
HELP
  exit 0
fi
echo "unexpected invocation: $*" >&2
exit 99
EOF
  chmod +x "${fake_python}"

  local output
  if output="$(
    VLLM_MLX_PYTHON="${fake_python}" \
    VLLM_MLX_REPO="${fake_repo}" \
    VLLM_MLX_MODEL_ALIAS="qwen3.5-4b" \
    VLLM_MLX_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_vllm_mlx.sh" 2>&1
  )"; then
    echo "FAIL: launcher succeeded against a CLI without --served-model-name"
    echo "${output}"
    return 1
  fi

  if [[ "${output}" == *"does not support --served-model-name"* && \
        "${output}" == *"waybarrios/vllm-mlx#125"* ]]; then
    echo "PASS: launcher reports the upstream served-model-name requirement clearly"
  else
    echo "FAIL: launcher did not report the served-model-name requirement clearly"
    echo "${output}"
    return 1
  fi
}

test_opencode_config() {
  echo "TEST: OpenCode vllm-mlx config generation"
  local home_dir="${TMPDIR}/home-opencode"
  local config_path="${TMPDIR}/opencode.json"
  mkdir -p "${home_dir}"
  HOME="${home_dir}" OPENCODE_CONFIG_PATH="${config_path}" bash "${REPO_ROOT}/scripts/opencode_set_vllm_mlx.sh" >/dev/null
  if grep -q '"model": "local/qwen"' "${config_path}" && \
     grep -q '"name": "vllm-mlx"' "${config_path}" && \
     grep -q '"npm": "@ai-sdk/openai"' "${config_path}" && \
     grep -q '"tool_call": true' "${config_path}" && \
     grep -q '"baseURL": "http://10.77.0.20:8080/v1"' "${config_path}"; then
    echo "PASS: OpenCode config uses Responses-capable local vllm-mlx"
  else
    echo "FAIL: OpenCode config missing expected fields"
    cat "${config_path}"
    return 1
  fi
}

test_codex_config() {
  echo "TEST: Codex vllm-mlx config generation"
  local home_dir="${TMPDIR}/home-codex"
  local config_path="${TMPDIR}/codex.toml"
  local catalog_path="${TMPDIR}/catalog.json"
  mkdir -p "${home_dir}"
  HOME="${home_dir}" CODEX_CONFIG_PATH="${config_path}" CODEX_CATALOG_PATH="${catalog_path}" bash "${REPO_ROOT}/scripts/codex_set_vllm_mlx.sh" >/dev/null
  if grep -q 'name = "Local vllm-mlx"' "${config_path}" && \
     grep -q 'wire_api = "responses"' "${config_path}" && \
     grep -q 'base_url = "http://10.77.0.20:8080/v1"' "${config_path}" && \
     grep -q 'base_url = "http://127.0.0.1:8081/v1"' "${config_path}" && \
     [[ "$(grep -c '^model = "qwen"$' "${config_path}")" -eq 2 ]] && \
     python3 - "${catalog_path}" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
slugs = {item["slug"] for item in data["models"]}
required = {
    "Qwen3.5-4B",
    "Qwen3-Coder-Next",
    "GPT-OSS-20B",
    "Devstral-2-123B-Instruct-2512",
}
missing = required - slugs
if missing:
    raise SystemExit(f"missing slugs: {sorted(missing)}")
PY
  then
    echo "PASS: Codex config and model catalog cover the benchmark roster"
  else
    echo "FAIL: Codex config or catalog missing expected fields"
    cat "${config_path}"
    return 1
  fi
}

test_codex_config_replaces_legacy_block() {
  echo "TEST: Codex vllm-mlx config migrates legacy managed block"
  local home_dir="${TMPDIR}/home-codex-legacy"
  local config_path="${TMPDIR}/codex-legacy.toml"
  local catalog_path="${TMPDIR}/catalog-legacy.json"
  mkdir -p "${home_dir}"
  cat > "${config_path}" <<'EOF'
model = "gpt-5.4"

# BEGIN TABURA LOCAL MODELS
[model_providers.local]
name = "Local llama.cpp"
base_url = "http://127.0.0.1:8080/v1"
wire_api = "responses"

[profiles.local]
model_provider = "local"
model = "Qwen3.5-122B-A10B"
# END TABURA LOCAL MODELS
EOF
  HOME="${home_dir}" CODEX_CONFIG_PATH="${config_path}" CODEX_CATALOG_PATH="${catalog_path}" bash "${REPO_ROOT}/scripts/codex_set_vllm_mlx.sh" >/dev/null
  if grep -q '# BEGIN DEVSTRAL LOCAL MODELS' "${config_path}" && \
     ! grep -q '# BEGIN TABURA LOCAL MODELS' "${config_path}" && \
     [[ "$(grep -c '^\[model_providers.local\]' "${config_path}")" -eq 1 ]]; then
    echo "PASS: legacy Codex local-model block is replaced cleanly"
  else
    echo "FAIL: legacy Codex block migration left duplicates"
    cat "${config_path}"
    return 1
  fi
}

test_registry_resolution || FAILED=1
test_server_start_dry_run || FAILED=1
test_server_start_default_local_profile || FAILED=1
test_server_start_requires_served_model_name_support || FAILED=1
test_opencode_config || FAILED=1
test_codex_config || FAILED=1
test_codex_config_replaces_legacy_block || FAILED=1

exit "${FAILED}"
