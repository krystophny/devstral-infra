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
    LLAMACPP_PORT=18080 \
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

  # Thread caps: only pinned on non-Mac. On Mac the flags must be absent.
  local threads_ok=1
  if [[ "${platform}" == "Darwin" ]]; then
    [[ "${output}" != *"--threads "* ]] || threads_ok=0
    [[ "${output}" != *"--threads-http "* ]] || threads_ok=0
  else
    [[ "${output}" == *"--threads "* ]] || threads_ok=0
    [[ "${output}" == *"--threads-http 4"* ]] || threads_ok=0
  fi

  if [[ "${output}" == *"-c 262144"* && \
        "${output}" == *"--cache-type-k q8_0"* && \
        "${output}" == *"--cache-type-v q8_0"* && \
        "${output}" == *"-fa on"* && \
        "${output}" == *"--alias qwen"* && \
        "${output}" == *"--jinja"* && \
        "${output}" == *"--reasoning-format deepseek"* && \
        "${output}" == *"--top-p 0.95"* && \
        "${output}" == *"--top-k 20"* && \
        "${output}" == *"--port 18080"* && \
        "${output}" == *"-np 1"* && \
        "${output}" == *"Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"* && \
        "${cpu_moe_ok}" == "1" && \
        "${threads_ok}" == "1" ]]; then
    echo "PASS: launcher emits the blessed single-instance profile (-np 1)"
  else
    echo "FAIL: launcher profile mismatch (cpu_moe_ok=${cpu_moe_ok} threads_ok=${threads_ok})"
    echo "${output}"
    return 1
  fi
}

test_server_start_thread_override() {
  echo "TEST: launcher honors LLAMACPP_THREADS override"
  local home_dir="${TMPDIR}/home-threads"
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
    LLAMACPP_PORT=18082 \
    LLAMACPP_THREADS=7 \
    LLAMACPP_THREADS_HTTP=3 \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    # Mac still honors explicit overrides — user opts in, launcher emits.
    if [[ "${output}" == *"--threads 7"* && "${output}" == *"--threads-http 3"* ]]; then
      echo "PASS: explicit thread overrides emitted on Mac when requested"
    else
      echo "FAIL: Mac did not honor explicit LLAMACPP_THREADS override"
      echo "${output}"
      return 1
    fi
  else
    if [[ "${output}" == *"--threads 7"* && "${output}" == *"--threads-http 3"* ]]; then
      echo "PASS: launcher honors LLAMACPP_THREADS / LLAMACPP_THREADS_HTTP"
    else
      echo "FAIL: thread overrides not in emitted command"
      echo "${output}"
      return 1
    fi
  fi
}

test_server_start_instance_overrides() {
  echo "TEST: launcher honors LLAMACPP_INSTANCE and LLAMACPP_SERVED_ALIAS"
  local home_dir="${TMPDIR}/home-inst"
  local model_path="${TMPDIR}/Qwen_Qwen3.6-27B-Q4_K_M.gguf"
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
    LLAMACPP_PORT=18081 \
    LLAMACPP_INSTANCE=27b \
    LLAMACPP_SERVED_ALIAS=qwen-27b \
    LLAMACPP_SMOKE_TEST=false \
    LLAMACPP_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh"
  )"

  if [[ "${output}" == *"--alias qwen-27b"* && \
        "${output}" == *"--port 18081"* && \
        "${output}" == *"- instance: 27b"* && \
        "${output}" == *"-np 1"* ]]; then
    echo "PASS: instance suffix and served alias take effect"
  else
    echo "FAIL: instance override did not propagate"
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
  OPENCODE_SKIP_PRIVACY_ENV=true \
  bash "${REPO_ROOT}/scripts/opencode_set_llamacpp.sh" >/dev/null

  local common_ok=1
  grep -q '"disable": true' "${config_path}" || common_ok=0
  grep -q '"permission": "allow"' "${config_path}" || common_ok=0
  grep -q '"output": 16384' "${config_path}" || common_ok=0
  grep -q '"reasoning": true' "${config_path}" || common_ok=0
  grep -q '"thinking_budget": 4096' "${config_path}" || common_ok=0
  grep -q '"temperature": 0.6' "${config_path}" || common_ok=0
  grep -q '"top_p": 0.95' "${config_path}" || common_ok=0
  grep -q '"top_k": 20' "${config_path}" || common_ok=0
  grep -q '"min_p": 0.0' "${config_path}" || common_ok=0
  grep -q '"presence_penalty": 0.0' "${config_path}" || common_ok=0
  grep -q '"repeat_penalty": 1.0' "${config_path}" || common_ok=0
  grep -q '"websearch": false' "${config_path}" || common_ok=0
  grep -q '"openTelemetry": false' "${config_path}" || common_ok=0
  grep -q '"share": "disabled"' "${config_path}" || common_ok=0
  grep -q '"autoupdate": false' "${config_path}" || common_ok=0
  grep -q '"opencode"' "${config_path}" || common_ok=0
  grep -q '"llmgateway"' "${config_path}" || common_ok=0
  grep -q '"github-copilot"' "${config_path}" || common_ok=0
  grep -q '"disabled_providers": \["exa",' "${config_path}" || common_ok=0

  local platform_ok=1
  if [[ "$(uname -s)" == "Darwin" ]]; then
    grep -q '"model": "llamacpp/qwen-27b"' "${config_path}" || platform_ok=0
    grep -q '"small_model": "llamacpp-moe/qwen-35b-a3b"' "${config_path}" || platform_ok=0
    grep -q '"context": 262144' "${config_path}" || platform_ok=0
    grep -q 'http://127.0.0.1:8081/v1' "${config_path}" || platform_ok=0
    grep -q 'http://127.0.0.1:8080/v1' "${config_path}" || platform_ok=0
    grep -q 'Qwen3.6 27B Q4 + KV-Q8 (Local dense)' "${config_path}" || platform_ok=0
    grep -q 'Qwen3.6 35B A3B Q4 + KV-Q8 (Local MoE)' "${config_path}" || platform_ok=0
  else
    grep -q '"model": "llamacpp/qwen"' "${config_path}" || platform_ok=0
    grep -q '"context": 262144' "${config_path}" || platform_ok=0
    grep -q 'http://127.0.0.1:8080/v1' "${config_path}" || platform_ok=0
    grep -q 'Qwen3.6 35B A3B Q4 + KV-Q8 (Local)' "${config_path}" || platform_ok=0
  fi

  if [[ "${common_ok}" == "1" && "${platform_ok}" == "1" ]]; then
    echo "PASS: OpenCode config matches the blessed profile for $(uname -s)"
  else
    echo "FAIL: OpenCode config missing expected fields (common=${common_ok} platform=${platform_ok})"
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

test_setup_backend_selection() {
  echo "TEST: setup_llamacpp.sh backend selection"
  local home_dir="${TMPDIR}/home-setup"
  local fake_bin="${TMPDIR}/fake-bin"
  mkdir -p "${home_dir}/.local/llama.cpp" "${fake_bin}"

  # Fake `curl` so the script never hits the network. Emits a minimal release
  # payload so only the dispatch branching is exercised.
  cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"tag_name":"bTEST","assets":[]}'
EOF
  chmod +x "${fake_bin}/curl"

  run_setup() {
    local var="$1"
    env -i \
      HOME="${home_dir}" \
      PATH="${fake_bin}:/usr/bin:/bin" \
      LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
      LLAMACPP_BACKEND="${var}" \
      bash "${REPO_ROOT}/scripts/setup_llamacpp.sh" 2>&1 || true
  }

  local out_prebuilt out_cuda out_bogus
  out_prebuilt="$(run_setup prebuilt)"
  if [[ "${out_prebuilt}" != *"backend: prebuilt"* ]]; then
    echo "FAIL: explicit LLAMACPP_BACKEND=prebuilt not honored"
    echo "${out_prebuilt}"
    return 1
  fi

  out_cuda="$(run_setup cuda-source)"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "${out_cuda}" != *"only supported on Linux"* ]]; then
      echo "FAIL: cuda-source should refuse non-Linux platforms"
      echo "${out_cuda}"
      return 1
    fi
  else
    if [[ "${out_cuda}" != *"backend: cuda-source"* ]]; then
      echo "FAIL: explicit LLAMACPP_BACKEND=cuda-source not honored on Linux"
      echo "${out_cuda}"
      return 1
    fi
  fi

  out_bogus="$(run_setup nope)"
  if [[ "${out_bogus}" != *"unknown LLAMACPP_BACKEND"* ]]; then
    echo "FAIL: invalid backend value not rejected"
    echo "${out_bogus}"
    return 1
  fi

  echo "PASS: setup backend dispatch accepts prebuilt/cuda-source, rejects bogus"
}

test_server_exec_mode() {
  echo "TEST: LLAMACPP_EXEC=true replaces the shell with llama-server"
  local home_dir="${TMPDIR}/home-exec"
  local model_path="${TMPDIR}/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
  local stamp="${TMPDIR}/exec-args"
  mkdir -p "${home_dir}/.local/llama.cpp"
  cat > "${home_dir}/.local/llama.cpp/llama-server" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${stamp}"
exit 0
EOF
  chmod +x "${home_dir}/.local/llama.cpp/llama-server"
  : > "${model_path}"

  HOME="${home_dir}" \
  LLAMACPP_HOME="${home_dir}/.local/llama.cpp" \
  LLAMACPP_MODEL="${model_path}" \
  LLAMACPP_PORT=18084 \
  LLAMACPP_SMOKE_TEST=false \
  LLAMACPP_EXEC=true \
  bash "${REPO_ROOT}/scripts/server_start_llamacpp.sh" >/dev/null 2>&1

  if [[ ! -s "${stamp}" ]]; then
    echo "FAIL: exec-mode launcher did not invoke llama-server"
    return 1
  fi
  if grep -qx -- '-np' "${stamp}" \
    && grep -qx -- '1' "${stamp}" \
    && grep -qx -- '--port' "${stamp}" \
    && grep -qx -- '18084' "${stamp}"; then
    echo "PASS: exec-mode passes -np 1 and --port through to llama-server"
  else
    echo "FAIL: exec-mode argv did not include expected flags"
    cat "${stamp}"
    return 1
  fi
}

test_install_linux_systemd_dry_run() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP: install_linux_systemd dry-run (Linux-only)"
    return 0
  fi
  echo "TEST: install_linux_systemd.sh dry-run writes the expected unit"
  local home_dir="${TMPDIR}/home-install"
  local unit_dir="${TMPDIR}/units"
  mkdir -p "${home_dir}" "${unit_dir}"
  local unit_file="${unit_dir}/devstral-llamacpp.service"

  HOME="${home_dir}" \
  INSTALL_DRY_RUN=true \
  UNIT_DIR="${unit_dir}" \
  bash "${REPO_ROOT}/scripts/install_linux_systemd.sh" >/dev/null

  if [[ ! -f "${unit_file}" ]]; then
    echo "FAIL: unit file was not written"
    return 1
  fi
  if grep -q '^ExecStart=.*server_start_llamacpp\.sh$' "${unit_file}" \
    && grep -q '^Environment=LLAMACPP_EXEC=true$' "${unit_file}" \
    && grep -q '^Environment=LLAMACPP_SMOKE_TEST=false$' "${unit_file}" \
    && grep -q '^Restart=on-failure$' "${unit_file}" \
    && grep -q '^\[Install\]$' "${unit_file}" \
    && grep -q '^WantedBy=default.target$' "${unit_file}"; then
    echo "PASS: unit invokes the launcher in exec mode with restart policy"
  else
    echo "FAIL: unit file missing expected directives"
    cat "${unit_file}"
    return 1
  fi
}

test_server_start_dry_run || FAILED=$((FAILED + 1))
test_server_start_instance_overrides || FAILED=$((FAILED + 1))
test_server_start_thread_override || FAILED=$((FAILED + 1))
test_server_exec_mode || FAILED=$((FAILED + 1))
test_opencode_config || FAILED=$((FAILED + 1))
test_models_default_alias || FAILED=$((FAILED + 1))
test_setup_backend_selection || FAILED=$((FAILED + 1))
test_install_linux_systemd_dry_run || FAILED=$((FAILED + 1))

if [[ "${FAILED}" -gt 0 ]]; then
  echo "${FAILED} test(s) failed"
  exit 1
fi
echo "all llama.cpp profile tests passed"
