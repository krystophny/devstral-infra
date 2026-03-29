#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PORT="${DEVSTRAL_PORT:-8080}"
HOST="${DEVSTRAL_HOST:-10.77.0.20}"
API_BASE="${OPENCODE_LOCAL_API_BASE:-http://${HOST}:${PORT}/v1}"
MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-qwen}"
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-262144}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-32768}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
fi

cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "local/${MODEL_ID}",
  "share": "disabled",
  "autoupdate": false,
  "permission": "allow",
  "experimental": {
    "openTelemetry": false
  },
  "disabled_providers": ["exa", "openai", "google", "mistral", "groq", "xai", "ollama"],
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai",
      "name": "vllm-mlx",
      "options": {
        "baseURL": "${API_BASE}",
        "apiKey": "dummy"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "${MODEL_ID}",
          "tool_call": true,
          "limit": {
            "context": ${CONTEXT_SIZE},
            "output": ${OUTPUT_LIMIT}
          },
          "options": {
            "temperature": 0.6,
            "top_p": 0.95,
            "top_k": 20,
            "min_p": 0.0,
            "presence_penalty": 0.0,
            "repeat_penalty": 1.0
          }
        }
      }
    }
  }
}
EOF

echo "Configured OpenCode for local vllm-mlx:"
echo "- config: ${CONFIG_PATH}"
echo "- model: local/${MODEL_ID}"
echo "- api_base: ${API_BASE}"
