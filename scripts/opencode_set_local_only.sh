#!/usr/bin/env bash
# Configure OpenCode for local-only use: disable telemetry, autoupdate, remote providers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LLAMA_PORT="${LLAMA_PORT:-8081}"
MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-qwen3.5-9b}"
API_BASE="http://127.0.0.1:${LLAMA_PORT}/v1"

CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${HOME}/.config/opencode/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

if [[ -f "${CONFIG_PATH}" ]]; then
    BACKUP_PATH="${CONFIG_PATH}.local-only.bak"
    if [[ ! -f "${BACKUP_PATH}" ]]; then
        cp "${CONFIG_PATH}" "${BACKUP_PATH}"
        echo "backup: ${BACKUP_PATH}"
    fi
fi

cat > "${CONFIG_PATH}" << JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "agent": {
    "title": {
      "disable": true
    }
  },
  "autoupdate": false,
  "share": "disabled",
  "disabled_providers": [
    "openai",
    "anthropic",
    "google",
    "aws-bedrock",
    "azure",
    "xai",
    "groq",
    "fireworks",
    "deepseek",
    "mistral",
    "copilot"
  ],
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (Local)",
      "options": {
        "baseURL": "${API_BASE}",
        "apiKey": "local"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "Qwen3.5 9B (Local)",
          "limit": {
            "context": 32768,
            "output": 8192
          }
        }
      }
    }
  },
  "model": "llamacpp/${MODEL_ID}"
}
JSON

echo "Configured OpenCode for local-only use:"
echo "  config: ${CONFIG_PATH}"
echo "  autoupdate: disabled"
echo "  share: disabled"
echo "  remote providers: all disabled"
echo "  local provider: llama.cpp @ ${API_BASE}"
echo "  model: llamacpp/${MODEL_ID}"
