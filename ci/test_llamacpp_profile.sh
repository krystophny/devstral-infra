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
  local pid_file="${run_dir}/llamacpp.pid"
  local port_file="${run_dir}/llamacpp.port"
  local tmux_file="${run_dir}/llamacpp.tmux"
  local backup_dir="${TMPDIR}/run-backup"
  mkdir -p "${home_dir}/.local/llama.cpp" "${home_dir}/.cache"
  mkdir -p "${backup_dir}"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"

  if [[ -f "${pid_file}" ]]; then mv "${pid_file}" "${backup_dir}/llamacpp.pid"; fi
  if [[ -f "${port_file}" ]]; then mv "${port_file}" "${backup_dir}/llamacpp.port"; fi
  if [[ -f "${tmux_file}" ]]; then mv "${tmux_file}" "${backup_dir}/llamacpp.tmux"; fi

  local output
  output="$(
    HOME="${home_dir}" \
    LLAMACPP_MODEL="${TMPDIR}/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf" \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ -f "${backup_dir}/llamacpp.pid" ]]; then mv "${backup_dir}/llamacpp.pid" "${pid_file}"; fi
  if [[ -f "${backup_dir}/llamacpp.port" ]]; then mv "${backup_dir}/llamacpp.port" "${port_file}"; fi
  if [[ -f "${backup_dir}/llamacpp.tmux" ]]; then mv "${backup_dir}/llamacpp.tmux" "${tmux_file}"; fi

  local has_reasoning_flag="false"
  if [[ "${output}" == *"--reasoning off"* || "${output}" == *"enable_thinking"* ]]; then
    has_reasoning_flag="true"
  fi

  if [[ "${output}" == *"-c 262144"* && \
        "${output}" == *"--ctx-checkpoints 64"* && \
        "${output}" == *"--checkpoint-every-n-tokens 4096"* && \
        "${output}" == *"-b 2048"* && \
        "${output}" == *"-ub 512"* && \
        "${has_reasoning_flag}" == "true" ]]; then
    echo "PASS: launcher emits the recommended local profile"
  else
    echo "FAIL: launcher output did not include the expected profile"
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
  OPENCODE_LOCAL_API_BASE="http://127.0.0.1:8080/v1" \
  bash "${REPO_ROOT}/scripts/opencode_set_llamacpp.sh" >/dev/null

  if grep -q '"model": "llamacpp/qwen"' "${config_path}" && \
     grep -q '"permission": "allow"' "${config_path}" && \
     grep -q '"context": 262144' "${config_path}" && \
     grep -q '"output": 32768' "${config_path}" && \
     grep -q 'http://127.0.0.1:8080/v1' "${config_path}"; then
    echo "PASS: OpenCode config uses the recommended local profile"
  else
    echo "FAIL: OpenCode config missing expected fields"
    cat "${config_path}"
    return 1
  fi
}

echo "=== llama.cpp Profile Tests ==="

test_server_start_dry_run || FAILED=1
test_opencode_config || FAILED=1

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
