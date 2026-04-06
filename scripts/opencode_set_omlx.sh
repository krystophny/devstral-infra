#!/usr/bin/env bash
# Configure OpenCode for local oMLX server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

OMLX_PORT="${OMLX_PORT:-8000}"
MODEL_ID="${OPENCODE_OMLX_MODEL_ID:-Devstral-2-123B-Instruct-2512-4bit}"
API_BASE="http://127.0.0.1:${OMLX_PORT}/v1"

CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${HOME}/.config/opencode/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.omlx.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

cat > "${CONFIG_PATH}" << JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "omlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "oMLX (Local)",
      "options": {
        "baseURL": "${API_BASE}",
        "apiKey": "omlx-local"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "oMLX Local Model",
          "limit": {
            "context": 32000,
            "output": 8192
          }
        }
      }
    }
  },
  "model": "omlx/${MODEL_ID}",
  "small_model": "omlx/${MODEL_ID}",
  "agent": {
    "title": {
      "disable": true
    }
  }
}
JSON

echo "Configured OpenCode for oMLX:"
echo "- config: ${CONFIG_PATH}"
echo "- model: omlx/${MODEL_ID}"
echo "- api_base: ${API_BASE}"
