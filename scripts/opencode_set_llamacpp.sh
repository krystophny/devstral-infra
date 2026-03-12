#!/usr/bin/env bash
# Configure OpenCode for local llama.cpp server with Qwen3.5-35B-A3B.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

# llama.cpp uses port 8080 by default
PORT="${DEVSTRAL_PORT:-8080}"
HOST="${DEVSTRAL_HOST:-127.0.0.1}"
API_BASE="${OPENCODE_LOCAL_API_BASE:-http://${HOST}:${PORT}/v1}"

# Model identifier for OpenCode
MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-qwen}"
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-262144}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-32768}"
PROVIDER_NAME="${OPENCODE_LOCAL_PROVIDER_NAME:-llama.cpp (local upstream-master Q4 profile)}"
MODEL_NAME="${OPENCODE_LOCAL_MODEL_NAME:-Qwen3.5-35B-A3B UD-Q4_K_XL (local upstream-master default)}"

# OpenCode config location
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

# Generate OpenCode config for llama.cpp
# Disable telemetry, autoupdate, and external services
cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "llamacpp/${MODEL_ID}",
  "share": "disabled",
  "autoupdate": false,
  "permission": "allow",
  "experimental": {
    "openTelemetry": false
  },
  "disabled_providers": ["exa", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"],
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "${PROVIDER_NAME}",
      "options": {
        "baseURL": "${API_BASE}"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "${MODEL_NAME}",
          "limit": {
            "context": ${CONTEXT_SIZE},
            "output": ${OUTPUT_LIMIT}
          }
        }
      }
    }
  }
}
EOF

echo "Configured OpenCode for local llama.cpp:"
echo "- config: ${CONFIG_PATH}"
echo "- model: ${MODEL_ID}"
echo "- context: ${CONTEXT_SIZE} tokens"
echo "- output limit: ${OUTPUT_LIMIT} tokens"
echo "- api_base: ${API_BASE}"
echo "- permission: allow"
echo ""
echo "Usage:"
echo "  1. Start server: scripts/server_start_llamacpp.sh"
echo "  2. Run: opencode"
