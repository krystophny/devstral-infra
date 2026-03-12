#!/usr/bin/env bash
# Configure qwen-code for local llama.cpp server with Qwen3.5-122B-A10B Q8_0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

# llama.cpp uses port 8080 by default
PORT="${DEVSTRAL_PORT:-8080}"
HOST="${DEVSTRAL_HOST:-127.0.0.1}"
API_BASE="${QWENCODE_LOCAL_API_BASE:-http://${HOST}:${PORT}/v1}"

# Model identifier for qwen-code
MODEL_ID="${QWENCODE_LOCAL_MODEL_ID:-qwen}"
CONTEXT_SIZE="${QWENCODE_LOCAL_CONTEXT:-262144}"
OUTPUT_LIMIT="${QWENCODE_LOCAL_OUTPUT:-32768}"
TEMPERATURE="${QWENCODE_LOCAL_TEMPERATURE:-0.6}"
TOP_P="${QWENCODE_LOCAL_TOP_P:-0.95}"

# qwen-code config location
CONFIG_DIR="${HOME}/.qwen"
CONFIG_PATH="${CONFIG_DIR}/settings.json"
mkdir -p "${CONFIG_DIR}"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

cat > "${CONFIG_PATH}" <<EOF
{
  "modelProviders": {
    "openai": [
      {
        "id": "${MODEL_ID}",
        "name": "Local Qwen3.5-122B via llama.cpp",
        "baseUrl": "${API_BASE}",
        "envKey": "QWEN_CODE_API_KEY",
        "generationConfig": {
          "timeout": 600000,
          "maxRetries": 1,
          "contextWindowSize": ${CONTEXT_SIZE},
          "samplingParams": {
            "temperature": ${TEMPERATURE},
            "top_p": ${TOP_P},
            "max_tokens": ${OUTPUT_LIMIT}
          }
        }
      }
    ]
  },
  "env": {
    "QWEN_CODE_API_KEY": "local"
  },
  "model": {
    "name": "${MODEL_ID}"
  },
  "tools": {
    "approvalMode": "yolo"
  }
}
EOF

echo "Configured qwen-code for local llama.cpp:"
echo "- config: ${CONFIG_PATH}"
echo "- model: ${MODEL_ID}"
echo "- context: ${CONTEXT_SIZE} tokens"
echo "- output limit: ${OUTPUT_LIMIT} tokens"
echo "- api_base: ${API_BASE}"
echo "- temperature: ${TEMPERATURE}"
echo "- top_p: ${TOP_P}"
echo "- approval mode: yolo"
echo ""
echo "Usage:"
echo "  1. Start server: scripts/server_start_llamacpp.sh"
echo "  2. Run: qwen"
