#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mac.sh must run on macOS"

# macOS uses Ollama (native Metal support, tool calling works)
# Default to GLM-4.7-Flash with 12k context for OpenCode compatibility

echo "=== Setting up Ollama on macOS ==="

# Install Ollama if not present
if ! have ollama; then
    echo "installing Ollama..."
    if have brew; then
        brew install ollama
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi
fi

# Verify Ollama version (need 0.14.3+ for gpt-oss:20b)
OLLAMA_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")"
MIN_VERSION="0.14.3"
if [[ "$(printf '%s\n' "${MIN_VERSION}" "${OLLAMA_VERSION}" | sort -V | head -1)" != "${MIN_VERSION}" ]]; then
    warn "Ollama ${OLLAMA_VERSION} may be too old. gpt-oss:20b requires 0.14.3+"
fi

echo "Ollama version: ${OLLAMA_VERSION}"

# Start Ollama if not running
if ! pgrep -x "ollama" >/dev/null 2>&1; then
    echo "starting Ollama server..."
    ollama serve >/dev/null 2>&1 &
    sleep 3
fi

# Pull and configure model with 12k context for tool calling
BASE_MODEL="${DEVSTRAL_OLLAMA_BASE_MODEL:-gpt-oss:20b}"
MODEL="${DEVSTRAL_OLLAMA_MODEL:-gpt-oss:20b-12k}"
CONTEXT_SIZE=12288

echo "pulling base model ${BASE_MODEL} (~14GB)..."
ollama pull "${BASE_MODEL}"

# Create 12k context variant if needed
if [[ "${MODEL}" == *"-12k" ]] && ! ollama list 2>/dev/null | grep -q "^${MODEL}"; then
    echo "Creating ${MODEL} with ${CONTEXT_SIZE} context..."
    cat > /tmp/Modelfile-setup <<EOF
FROM ${BASE_MODEL}
PARAMETER num_ctx ${CONTEXT_SIZE}
EOF
    ollama create "${MODEL}" -f /tmp/Modelfile-setup
    rm -f /tmp/Modelfile-setup
fi

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
3. Configure OpenCode: scripts/opencode_set_local.sh
EOF
