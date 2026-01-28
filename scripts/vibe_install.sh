#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Installing Vibe CLI..."

case "${platform}" in
  mac)
    if have brew; then
      brew install --cask vibe 2>/dev/null || {
        echo "Homebrew cask not available, using curl installer..."
        curl -sSL https://download.vibe.sh/cli | bash
      }
    else
      curl -sSL https://download.vibe.sh/cli | bash
    fi
    ;;
  linux|wsl)
    curl -sSL https://download.vibe.sh/cli | bash
    ;;
esac

if have vibe; then
  echo "OK - Vibe installed"
  vibe --version 2>/dev/null || true
else
  echo "Vibe installed but not in PATH. Add ~/.vibe/bin to your PATH:"
  echo '  export PATH="$HOME/.vibe/bin:$PATH"'
fi

echo ""
echo "Next steps:"
echo "  scripts/vibe_set_local.sh  # Configure Vibe to use local server"
echo "  scripts/security_harden.sh # Optional: block Vibe network access"
