#!/usr/bin/env bash
# Configure OpenCode for the local llama.cpp server.
#
# Single blessed profile: Qwen3.6 35B A3B Q4_K_M over the local
# llama-server on http://127.0.0.1:8080/v1, served as model "qwen",
# with title generation disabled for latency and all non-local providers off.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

HOST="${LLAMACPP_HOST:-127.0.0.1}"
PORT="${LLAMACPP_PORT:-8080}"
API_BASE="${OPENCODE_LOCAL_API_BASE:-http://${HOST}:${PORT}/v1}"

MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-qwen}"
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-131072}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-16384}"
PROVIDER_NAME="${OPENCODE_LOCAL_PROVIDER_NAME:-llama.cpp (Local)}"
MODEL_NAME="${OPENCODE_LOCAL_MODEL_NAME:-Qwen3.6 35B A3B Q4 + KV-Q8 (Local)}"
TEMPERATURE="${OPENCODE_LOCAL_TEMPERATURE:-0.6}"
TOP_P="${OPENCODE_LOCAL_TOP_P:-0.95}"
TOP_K="${OPENCODE_LOCAL_TOP_K:-20}"
MIN_P="${OPENCODE_LOCAL_MIN_P:-0.0}"
PRESENCE_PENALTY="${OPENCODE_LOCAL_PRESENCE_PENALTY:-0.0}"
REPEAT_PENALTY="${OPENCODE_LOCAL_REPEAT_PENALTY:-1.0}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "llamacpp/${MODEL_ID}",
  "small_model": "llamacpp/${MODEL_ID}",
  "agent": {
    "title": { "disable": true }
  },
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
          },
          "reasoning": true,
          "tool_call": true,
          "options": {
            "temperature": ${TEMPERATURE},
            "top_p": ${TOP_P},
            "top_k": ${TOP_K},
            "min_p": ${MIN_P},
            "presence_penalty": ${PRESENCE_PENALTY},
            "repeat_penalty": ${REPEAT_PENALTY},
            "thinking_budget": 4096
          }
        }
      }
    }
  }
}
EOF

echo "configured OpenCode:"
echo "- config:   ${CONFIG_PATH}"
echo "- provider: llamacpp -> ${API_BASE}"
echo "- model:    ${MODEL_ID} (${CONTEXT_SIZE} ctx, ${OUTPUT_LIMIT} out)"
echo "- title:    disabled"
echo "- permission: allow"
