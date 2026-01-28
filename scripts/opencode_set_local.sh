#!/usr/bin/env bash
# Configure OpenCode for local Ollama server with GLM-4.7-Flash
# Reference: https://opencode.ai/docs/providers
# Reference: https://docs.ollama.com/integrations/opencode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
    MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-glm-4.7-flash}"
    API_BASE="${OPENCODE_LOCAL_API_BASE:-http://localhost:11434/v1}"
else
    MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-glm-4.7-flash}"
    API_BASE="${OPENCODE_LOCAL_API_BASE:-http://127.0.0.1:11434/v1}"
fi

# OpenCode config locations (in priority order)
# 1. ./.opencode.json (local directory)
# 2. $XDG_CONFIG_HOME/opencode/.opencode.json
# 3. $HOME/.opencode.json
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
          "name": "GLM 4.7 Flash (local)"
        },
        "devstral-small-2": {
          "name": "Devstral Small 2 (local)"
        }
      }
    }
  }
}
EOF

echo "Configured OpenCode for local Ollama:"
echo "- config: ${CONFIG_PATH}"
echo "- model: ${MODEL_ID}"
echo "- api_base: ${API_BASE}"
echo ""
echo "Usage:"
echo "  1. Ensure Ollama is running: ollama serve"
echo "  2. Pull model if needed: ollama pull ${MODEL_ID}"
echo "  3. Run OpenCode: opencode"
echo "  4. Select model with /models command"
echo ""
echo "For tool calling, increase context (if issues):"
echo "  ollama run ${MODEL_ID} --num_ctx 16384"
