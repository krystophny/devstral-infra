#!/usr/bin/env bash
# Install OpenCode CLI
# Reference: https://opencode.ai/docs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Installing OpenCode CLI..."

case "${platform}" in
  mac)
    if have brew; then
      brew install anomalyco/tap/opencode
    else
      curl -fsSL https://opencode.ai/install | bash
    fi
    ;;
  linux|wsl)
    curl -fsSL https://opencode.ai/install | bash
    ;;
esac

if have opencode; then
  echo "OK - OpenCode installed"
  opencode --version 2>/dev/null || true
else
  echo "OpenCode installed but not in PATH. Add ~/.opencode/bin to your PATH:"
  # shellcheck disable=SC2016  # intentionally literal $HOME for user to copy
  echo '  export PATH="$HOME/.opencode/bin:$PATH"'
fi

echo ""
echo "Next steps:"
echo "  scripts/opencode_set_local.sh  # Configure OpenCode for local Ollama"
echo "  scripts/security_harden.sh     # Optional: block network access"
