#!/usr/bin/env bash
# Setup llama.cpp for the local Qwen3.5 OpenCode profile with 256k context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LLAMACPP_VERSION="${LLAMACPP_VERSION:-latest}"
LLAMACPP_DIR="${HOME}/.local/llama.cpp"

platform="$(detect_platform)"
gpu="$(detect_gpu)"

echo "=== Setting up llama.cpp ==="
echo "Platform: ${platform}"
echo "GPU: ${gpu}"

# Determine which binary to download
case "${platform}" in
  mac)
    ARCH="$(uname -m)"
    if [[ "${ARCH}" == "arm64" ]]; then
      BINARY_SUFFIX="macos-arm64"
    else
      BINARY_SUFFIX="macos-x64"
    fi
    ;;
  linux|wsl)
    if [[ "${gpu}" == "cuda" ]]; then
      # Use Vulkan build for NVIDIA (works via Vulkan API, no CUDA toolkit needed)
      BINARY_SUFFIX="ubuntu-vulkan-x64"
    else
      BINARY_SUFFIX="ubuntu-x64"
    fi
    ;;
esac

# Get latest release tag if not specified
if [[ "${LLAMACPP_VERSION}" == "latest" ]]; then
  echo "Fetching latest release..."
  LLAMACPP_VERSION=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | \
    grep '"tag_name"' | sed 's/.*"tag_name": "\([^"]*\)".*/\1/')
fi

echo "Version: ${LLAMACPP_VERSION}"

# Download URL
DOWNLOAD_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_VERSION}/llama-${LLAMACPP_VERSION}-bin-${BINARY_SUFFIX}.tar.gz"

mkdir -p "${LLAMACPP_DIR}"
cd "${LLAMACPP_DIR}"

# Download and extract
echo "Downloading from ${DOWNLOAD_URL}..."
curl -L -o "llama-${LLAMACPP_VERSION}.tar.gz" "${DOWNLOAD_URL}"
tar xzf "llama-${LLAMACPP_VERSION}.tar.gz"

# Find the extracted directory
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "llama-*" | head -1)
if [[ -z "${EXTRACTED_DIR}" ]]; then
  die "Failed to find extracted llama.cpp directory"
fi

# Create symlinks for easy access
ln -sf "${EXTRACTED_DIR}/llama-server" "${LLAMACPP_DIR}/llama-server"
ln -sf "${EXTRACTED_DIR}/llama-cli" "${LLAMACPP_DIR}/llama-cli"

# Verify installation
if [[ ! -x "${LLAMACPP_DIR}/llama-server" ]]; then
  die "llama-server not found or not executable"
fi

VERSION_INFO=$("${LLAMACPP_DIR}/llama-server" --version 2>&1 | grep "version:" || echo "unknown")

cat <<EOF
OK (llama.cpp installed)
- Directory: ${LLAMACPP_DIR}
- Binary: ${BINARY_SUFFIX}
- ${VERSION_INFO}

Next:
- Start server: scripts/server_start_llamacpp.sh
- Configure OpenCode: scripts/opencode_set_llamacpp.sh
- Configure Aider: scripts/aider_set_llamacpp.sh
- Configure Qwen Code: scripts/qwencode_set_llamacpp.sh
EOF
