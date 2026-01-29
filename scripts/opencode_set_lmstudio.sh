#!/usr/bin/env bash
# Configure OpenCode for LM Studio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-Devstral-Small-2-24B-Instruct-2512-Q3_K_L}"
API_BASE="http://127.0.0.1:${LMSTUDIO_PORT}/v1"

CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${HOME}/.config/opencode/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.lmstudio.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

# Generate config for LM Studio (correct OpenCode schema)
cat > "${CONFIG_PATH}" << JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LM Studio (Local)",
      "options": {
        "baseURL": "${API_BASE}",
        "apiKey": "lm-studio"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "Devstral Small 2 32K",
          "limit": {
            "context": 32000,
            "output": 8192
          }
        }
      }
    }
  },
  "model": "lmstudio/${MODEL_ID}"
}
JSON

echo "Configured OpenCode for LM Studio:"
echo "- config: ${CONFIG_PATH}"
echo "- model: lmstudio/${MODEL_ID}"
echo "- api_base: ${API_BASE}"
echo ""
echo "Usage:"
echo "  1. Start LM Studio server: scripts/lmstudio_server_start.sh"
echo "  2. Load a model: lms load <model-path>"
echo "  3. Run OpenCode: opencode"
