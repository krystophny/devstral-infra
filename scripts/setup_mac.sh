#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mac.sh must run on macOS"

VLLM_METAL_VENV="${HOME}/.venv-vllm-metal"

echo "installing vllm-metal..."
curl -sSL https://raw.githubusercontent.com/vllm-project/vllm-metal/main/install.sh | bash

echo "fixing dependency versions..."
uv pip install "transformers>=4.56,<5" "torchvision>=0.25.0" \
  --python "${VLLM_METAL_VENV}/bin/python"

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
