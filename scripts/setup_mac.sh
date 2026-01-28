#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mac.sh must run on macOS"

VLLM_METAL_VENV="${HOME}/.venv-vllm-metal"

# Use our fork with vLLM 0.14.1 for transformers 5.x compatibility
# See: https://github.com/krystophny/vllm-metal/issues/6
VLLM_METAL_FORK_BRANCH="${VLLM_METAL_FORK_BRANCH:-main}"
VLLM_METAL_FORK_REPO="${VLLM_METAL_FORK_REPO:-krystophny/vllm-metal}"

echo "installing vllm-metal from fork (${VLLM_METAL_FORK_REPO}@${VLLM_METAL_FORK_BRANCH})..."
curl -sSL "https://raw.githubusercontent.com/${VLLM_METAL_FORK_REPO}/${VLLM_METAL_FORK_BRANCH}/install.sh" | bash

echo "fixing torchvision version..."
uv pip install "torchvision>=0.25.0" --python "${VLLM_METAL_VENV}/bin/python"

if [[ -d "${VLLM_METAL_VENV}" ]]; then
  rm -rf "${VENV_DIR}"
  ln -sf "${VLLM_METAL_VENV}" "${VENV_DIR}"
  echo "linked ${VENV_DIR} -> ${VLLM_METAL_VENV}"
else
  die "vllm-metal venv not found at ${VLLM_METAL_VENV}"
fi

mkdir -p "${HF_HOME_DIR}"

cat <<EOF
OK (macOS + vllm-metal)
- venv: ${VENV_DIR} -> ${VLLM_METAL_VENV}
- HF cache: ${HF_HOME_DIR}
- GPU: Metal (Apple Silicon)

Next:
- Start server: scripts/server_start.sh
EOF
