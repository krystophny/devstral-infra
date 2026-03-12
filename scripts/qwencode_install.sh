#!/usr/bin/env bash
# Install qwen-code CLI
# Reference: https://qwen-code.alibaba.com/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Installing qwen-code..."

if have npm; then
  npm install -g @qwen-code/qwen-code@latest
elif [[ "${platform}" == "mac" ]] && have brew; then
  brew install qwen-code
else
  echo "No npm or brew found, trying curl installer..."
  bash -c "$(curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen.sh)"
fi

if have qwen; then
  echo "OK - qwen-code installed"
  qwen --version 2>/dev/null || true
else
  echo "qwen-code installed but not in PATH. Check your npm global bin directory:"
  echo '  npm config get prefix'
fi

echo ""
echo "Next steps:"
echo "  scripts/qwencode_set_llamacpp.sh  # Configure qwen-code for local llama.cpp"
echo "  scripts/security_harden.sh        # Optional: block network access"
