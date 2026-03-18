#!/usr/bin/env bash
# Configure qwen-code for local-only use: disable telemetry, remote providers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LLAMA_PORT="${LLAMA_PORT:-8081}"
MODEL_ID="${QWEN_LOCAL_MODEL_ID:-qwen3.5-9b}"
API_BASE="http://127.0.0.1:${LLAMA_PORT}/v1"

CONFIG_DIR="${HOME}/.qwen"
CONFIG_PATH="${CONFIG_DIR}/settings.json"
mkdir -p "${CONFIG_DIR}"

if [[ -f "${CONFIG_PATH}" ]]; then
    BACKUP_PATH="${CONFIG_PATH}.bak"
    if [[ ! -f "${BACKUP_PATH}" ]]; then
        cp "${CONFIG_PATH}" "${BACKUP_PATH}"
        echo "backup: ${BACKUP_PATH}"
    fi
fi

cat > "${CONFIG_PATH}" << JSON
{
  "telemetry": {
    "enabled": false
  },
  "privacy": {
    "usageStatisticsEnabled": false
  },
  "model": {
    "enableOpenAILogging": false
  }
}
JSON

echo "Configured qwen-code for local-only use:"
echo "  config: ${CONFIG_PATH}"
echo "  telemetry: disabled"
echo "  usage statistics: disabled (blocks play.googleapis.com)"
echo "  OpenAI logging: disabled"
echo ""
echo "To use with the local llama.cpp server, launch qwen-code with:"
echo "  OPENAI_BASE_URL=${API_BASE} OPENAI_API_KEY=local OPENAI_MODEL=${MODEL_ID} qwen"
