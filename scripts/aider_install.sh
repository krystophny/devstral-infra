#!/usr/bin/env bash
# Install aider-chat CLI
# Reference: https://aider.chat/docs/install.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Installing aider-chat..."

if have pip3; then
  pip3 install aider-chat
elif have pip; then
  pip install aider-chat
elif have uv; then
  uv tool install aider-chat
else
  echo "No pip or uv found, trying curl installer..."
  curl -LsSf https://aider.chat/install.sh | sh
fi

if have aider; then
  echo "OK - aider installed"
  aider --version 2>/dev/null || true
else
  echo "aider installed but not in PATH. Add ~/.local/bin to your PATH:"
  # shellcheck disable=SC2016  # intentionally literal $HOME for user to copy
  echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo "Next steps:"
echo "  scripts/aider_set_llamacpp.sh  # Configure aider for local llama.cpp"
echo "  scripts/security_harden.sh     # Optional: block network access"
