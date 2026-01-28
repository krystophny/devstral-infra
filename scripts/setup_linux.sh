#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"
[[ "${platform}" == "linux" || "${platform}" == "wsl" ]] \
  || die "setup_linux.sh must run on Linux or WSL"

ensure_python_venv
activate_venv

python -m pip install -U pip >/dev/null

gpu="$(detect_gpu)"
case "${gpu}" in
  cuda)
    echo "installing vllm (NVIDIA CUDA)..."
    python -m pip install "vllm>=0.8.0"
    ;;
  cpu)
    echo "installing vllm (CPU-only)..."
    python -m pip install "vllm>=0.8.0" \
      --extra-index-url https://download.pytorch.org/whl/cpu
    ;;
esac

mkdir -p "${HF_HOME_DIR}"

cat <<EOF
OK (Linux + vLLM, backend: ${gpu})
- venv: ${VENV_DIR}
- HF cache: ${HF_HOME_DIR}

Next:
- Start server: scripts/server_start.sh
EOF
