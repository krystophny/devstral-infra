#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

test_model_path_resolver() {
  echo "TEST: benchmark model path resolver honors overrides"

  local gguf="${TMPDIR}/Qwen3.5-9B-Q4_K_M.gguf"
  local mlx="${TMPDIR}/mlx-model"
  touch "${gguf}"
  mkdir -p "${mlx}"
  touch "${mlx}/config.json"

  local gguf_resolved
  gguf_resolved="$(
    BENCHMARK_GGUF_MODEL="${gguf}" \
    python3 "${REPO_ROOT}/scripts/benchmark_model_paths.py" resolve gguf-qwen3.5-9b-q4
  )"
  local mlx_resolved
  mlx_resolved="$(
    BENCHMARK_MLX_MODEL="${mlx}" \
    python3 "${REPO_ROOT}/scripts/benchmark_model_paths.py" resolve mlx-qwen3.5-9b-4bit
  )"

  if [[ "${gguf_resolved}" == "${gguf}" && "${mlx_resolved}" == "${mlx}" ]]; then
    echo "PASS: model path resolver uses explicit overrides"
  else
    echo "FAIL: benchmark model resolver returned unexpected paths"
    return 1
  fi
}

test_mlx_lm_dry_run() {
  echo "TEST: mlx-lm launcher dry-run profile"

  local fake_model="${TMPDIR}/mlx-qwen"
  mkdir -p "${fake_model}"
  touch "${fake_model}/config.json"
  local fake_bin="${TMPDIR}/mlx_lm.server"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}"
  chmod +x "${fake_bin}"

  local output
  output="$(
    MLX_LM_SERVER_BIN="${fake_bin}" \
    MLX_LM_MODEL="${fake_model}" \
    DEVSTRAL_PORT=8091 \
    MLX_LM_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_mlx_lm.sh"
  )"

  if [[ "${output}" == *"${fake_bin}"* && "${output}" == *"--model ${fake_model}"* && "${output}" == *"--port 8091"* ]]; then
    echo "PASS: mlx-lm launcher renders the expected command"
  else
    echo "FAIL: mlx-lm dry-run output is wrong"
    echo "${output}"
    return 1
  fi
}

test_vllm_metal_dry_run() {
  echo "TEST: vllm-metal launcher dry-run profile"

  local fake_bin="${TMPDIR}/vllm-metal"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}"
  chmod +x "${fake_bin}"

  local output
  output="$(
    VLLM_METAL_BIN="${fake_bin}" \
    VLLM_METAL_MODEL="mlx-community/Qwen3.5-9B-4bit" \
    DEVSTRAL_PORT=8093 \
    VLLM_METAL_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_vllm_metal.sh"
  )"

  if [[ "${output}" == *"${fake_bin}"* && "${output}" == *"--model mlx-community/Qwen3.5-9B-4bit"* && "${output}" == *"--port 8093"* ]]; then
    echo "PASS: vllm-metal launcher renders the expected command"
  else
    echo "FAIL: vllm-metal dry-run output is wrong"
    echo "${output}"
    return 1
  fi
}

test_omlx_dry_run() {
  echo "TEST: oMLX launcher dry-run profile"

  local fake_model="${TMPDIR}/omlx-qwen"
  mkdir -p "${fake_model}"
  touch "${fake_model}/config.json"

  local fake_bin_dir="${TMPDIR}/bin"
  mkdir -p "${fake_bin_dir}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin_dir}/omlx"
  chmod +x "${fake_bin_dir}/omlx"

  local output
  output="$(
    PATH="${fake_bin_dir}:${PATH}" \
    OMLX_MODEL_PATH="${fake_model}" \
    OMLX_DRY_RUN=true \
    bash "${REPO_ROOT}/scripts/server_start_omlx.sh"
  )"

  if [[ "${output}" == *"omlx serve"* && "${output}" == *"--model-dir"* && "${output}" == *"--paged-ssd-cache-dir"* ]]; then
    echo "PASS: oMLX launcher renders the expected command"
  else
    echo "FAIL: oMLX dry-run output is wrong"
    echo "${output}"
    return 1
  fi
}

test_benchmark_harness_dry_run() {
  echo "TEST: unified benchmark harness dry-run"

  local gguf="${TMPDIR}/Qwen3.5-9B-Q4_K_M.gguf"
  local mlx="${TMPDIR}/mlx-model"
  touch "${gguf}"
  mkdir -p "${mlx}"
  touch "${mlx}/config.json"

  local output
  output="$(
    BENCHMARK_GGUF_MODEL="${gguf}" \
    BENCHMARK_MLX_MODEL="${mlx}" \
    bash "${REPO_ROOT}/scripts/benchmark_local_stacks.sh" --dry-run --stacks llamacpp mlx-lm vllm-mlx vllm-metal omlx
  )"

  if [[ "${output}" == *'"slug": "llamacpp"'* && \
        "${output}" == *'"slug": "mlx-lm"'* && \
        "${output}" == *'"slug": "vllm-mlx"'* && \
        "${output}" == *'"slug": "vllm-metal"'* && \
        "${output}" == *'"slug": "omlx"'* ]]; then
    echo "PASS: benchmark harness includes all local Mac runtime stacks"
  else
    echo "FAIL: benchmark harness dry-run output is missing expected stacks"
    echo "${output}"
    return 1
  fi
}

run_test() {
  local name="$1"
  if "${name}"; then
    :
  else
    FAILED=1
  fi
  echo ""
}

run_test test_model_path_resolver
run_test test_mlx_lm_dry_run
run_test test_vllm_metal_dry_run
run_test test_omlx_dry_run
run_test test_benchmark_harness_dry_run

exit "${FAILED}"
