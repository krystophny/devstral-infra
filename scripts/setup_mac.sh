#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mac.sh must run on macOS"

# Use our fork with vLLM 0.14.x fixes
VLLM_METAL_FORK_REPO="${VLLM_METAL_FORK_REPO:-krystophny/vllm-metal}"
VLLM_METAL_FORK_BRANCH="${VLLM_METAL_FORK_BRANCH:-main}"
VLLM_VERSION="${VLLM_VERSION:-0.14.1}"

echo "=== Setting up vllm-metal from fork (${VLLM_METAL_FORK_REPO}@${VLLM_METAL_FORK_BRANCH}) ==="

# Create venv
echo "creating venv at ${VENV_DIR}..."
rm -rf "${VENV_DIR}"
uv venv "${VENV_DIR}" --python 3.12
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

# Install vLLM from source tarball
echo "installing vLLM ${VLLM_VERSION} from source..."
VLLM_TARBALL="vllm-${VLLM_VERSION}.tar.gz"
VLLM_URL="https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/${VLLM_TARBALL}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

curl -fsSL "${VLLM_URL}" -o "${TMP_DIR}/${VLLM_TARBALL}"
tar -xzf "${TMP_DIR}/${VLLM_TARBALL}" -C "${TMP_DIR}"

pushd "${TMP_DIR}/vllm-${VLLM_VERSION}" > /dev/null
uv pip install -r requirements/cpu.txt --index-strategy unsafe-best-match
uv pip install .
popd > /dev/null

# Install vllm-metal from our fork (source, not pre-built wheel)
echo "installing vllm-metal from git (${VLLM_METAL_FORK_REPO}@${VLLM_METAL_FORK_BRANCH})..."
uv pip install "git+https://github.com/${VLLM_METAL_FORK_REPO}.git@${VLLM_METAL_FORK_BRANCH}"

# Fix torchvision version for torch 2.10.x compatibility
echo "fixing torchvision version..."
uv pip install "torchvision>=0.25.0"

mkdir -p "${HF_HOME_DIR}"

cat <<EOF
OK (macOS + vllm-metal)
- venv: ${VENV_DIR}
- HF cache: ${HF_HOME_DIR}
- GPU: Metal (Apple Silicon)
- vLLM: ${VLLM_VERSION}
- vllm-metal: ${VLLM_METAL_FORK_REPO}@${VLLM_METAL_FORK_BRANCH}

Next:
- Start server: scripts/server_start.sh
EOF
