#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

echo "Installing Mistral Vibe CLI..."

# Official installer from mistral.ai (works on macOS, Linux, WSL)
curl -LsSf https://mistral.ai/vibe/install.sh | bash

if have vibe; then
  echo "OK - Vibe installed"
  vibe --version 2>/dev/null || true
else
  echo "Vibe installed but not in PATH. Add ~/.local/bin to your PATH:"
  # shellcheck disable=SC2016  # intentionally literal $HOME for user to copy
  echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo "Next steps:"
echo "  scripts/vibe_set_local.sh  # Configure Vibe to use local server"
echo "  scripts/security_harden.sh # Optional: block Vibe network access"
