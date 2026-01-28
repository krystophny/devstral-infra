#!/usr/bin/env bash
# Configure OpenCode for local Ollama server with GLM-4.7-Flash (32k context)
# Reference: https://opencode.ai/docs/providers
# Reference: https://docs.ollama.com/integrations/opencode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

# Default model with 16k context for tool calling
# OpenCode requires at least 16k context for tools to work
# 16k balances tool calling with memory usage on 32GB machines
MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-glm-4.7-flash-16k}"
BASE_MODEL="glm-4.7-flash"
CONTEXT_SIZE=16384

if [[ "${platform}" == "mac" ]]; then
    API_BASE="${OPENCODE_LOCAL_API_BASE:-http://localhost:11434/v1}"
else
    API_BASE="${OPENCODE_LOCAL_API_BASE:-http://127.0.0.1:11434/v1}"
fi

# Create 32k context variant if it doesn't exist
if ! ollama list 2>/dev/null | grep -q "${MODEL_ID}"; then
    echo "Creating ${MODEL_ID} with ${CONTEXT_SIZE} context..."
    if ! ollama list 2>/dev/null | grep -q "${BASE_MODEL}"; then
        echo "Pulling base model ${BASE_MODEL}..."
        ollama pull "${BASE_MODEL}"
    fi
    cat > /tmp/Modelfile-opencode <<EOF
FROM ${BASE_MODEL}
PARAMETER num_ctx ${CONTEXT_SIZE}
EOF
    ollama create "${MODEL_ID}" -f /tmp/Modelfile-opencode
    rm -f /tmp/Modelfile-opencode
    echo "Created ${MODEL_ID}"
fi

# OpenCode config location
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

# Generate OpenCode config
# Disable telemetry, autoupdate, and external services
cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollama/${MODEL_ID}",
  "share": "disabled",
  "autoupdate": false,
  "experimental": {
    "openTelemetry": false
  },
  "tools": {
    "websearch": false
  },
  "disabled_providers": ["exa", "openai", "anthropic", "google", "mistral", "groq", "xai"],
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "${API_BASE}"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "GLM 4.7 Flash 32k (local)"
        }
      }
    }
  }
}
EOF

echo "Configured OpenCode for local Ollama:"
echo "- config: ${CONFIG_PATH}"
echo "- model: ${MODEL_ID}"
echo "- context: ${CONTEXT_SIZE} tokens"
echo "- api_base: ${API_BASE}"
echo ""
echo "Usage:"
echo "  opencode -m ollama/${MODEL_ID}"
