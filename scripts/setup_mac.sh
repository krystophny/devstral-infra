#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mac.sh must run on macOS"

# macOS uses Ollama for Devstral (native Metal support, tool calling works)
# vllm-metal has issues with official Mistral FP8 format

echo "=== Setting up Ollama for Devstral on macOS ==="

# Install Ollama if not present
if ! have ollama; then
    echo "installing Ollama..."
    if have brew; then
        brew install ollama
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi
fi

# Verify Ollama version (need 0.13.3+ for devstral-small-2)
OLLAMA_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")"
MIN_VERSION="0.13.3"
if [[ "$(printf '%s\n' "${MIN_VERSION}" "${OLLAMA_VERSION}" | sort -V | head -1)" != "${MIN_VERSION}" ]]; then
    warn "Ollama ${OLLAMA_VERSION} may be too old. devstral-small-2 requires 0.13.3+"
fi

echo "Ollama version: ${OLLAMA_VERSION}"

# Start Ollama if not running
if ! pgrep -x "ollama" >/dev/null 2>&1; then
    echo "starting Ollama server..."
    ollama serve >/dev/null 2>&1 &
    sleep 3
fi

# Pull the model
MODEL="${DEVSTRAL_OLLAMA_MODEL:-devstral-small-2}"
echo "pulling model ${MODEL} (this may take a while, ~15GB)..."
ollama pull "${MODEL}"

# Create runtime directories
mkdir -p "${RUN_DIR}"

cat <<EOF
OK (macOS + Ollama)
- Ollama: ${OLLAMA_VERSION}
- Model: ${MODEL}
- Backend: Metal (Apple Silicon)

Next:
1. Start Ollama server: ollama serve
2. Or use: scripts/server_start.sh (starts Ollama automatically)
3. Configure Vibe: scripts/vibe_set_local.sh
EOF
