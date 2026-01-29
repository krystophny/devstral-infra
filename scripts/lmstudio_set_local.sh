#!/usr/bin/env bash
# Configure OpenCode for LM Studio with Devstral-2 123B (32k context)
# Reference: https://lmstudio.ai/docs/cli
# Reference: https://opencode.ai/docs/providers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

if [[ "${platform}" != "mac" ]]; then
    echo "Error: LM Studio MLX backend only works on macOS"
    exit 1
fi

# Model settings
MODEL_HF="mlx-community/GLM-4.7-REAP-50-mxfp4"
MODEL_ID="${LMSTUDIO_MODEL_ID:-glm-4.7-reap-50}"
CONTEXT_SIZE="${LMSTUDIO_CONTEXT_SIZE:-32768}"
API_BASE="${LMSTUDIO_API_BASE:-http://localhost:1234/v1}"

# Check lms CLI
if ! command -v lms &>/dev/null; then
    echo "Error: lms CLI not found. Run scripts/lmstudio_install.sh first"
    exit 1
fi

# Download model if not present
if ! lms ls 2>/dev/null | grep -qi "devstral-2-123b"; then
    echo "Downloading ${MODEL_HF}..."
    lms get "${MODEL_HF}"
fi

# Start server if not running
if ! curl -s "${API_BASE}/models" &>/dev/null; then
    echo "Starting LM Studio server..."
    lms server start
    sleep 3
fi

# Load model with context size
echo "Loading ${MODEL_ID} with ${CONTEXT_SIZE} context..."
lms unload --all 2>/dev/null || true
lms load "${MODEL_ID}" --gpu max -c "${CONTEXT_SIZE}"

# OpenCode config
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

# Generate OpenCode config for LM Studio
cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "lmstudio/${MODEL_ID}",
  "share": "disabled",
  "autoupdate": false,
  "experimental": {
    "openTelemetry": false
  },
  "tools": {
    "websearch": false
  },
  "disabled_providers": ["exa", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"],
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LM Studio (local)",
      "options": {
        "baseURL": "${API_BASE}"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "Devstral-2 123B 4bit (local)"
        }
      }
    }
  }
}
EOF

echo ""
echo "Configured OpenCode for LM Studio:"
echo "- config: ${CONFIG_PATH}"
echo "- model: ${MODEL_ID}"
echo "- context: ${CONTEXT_SIZE} tokens"
echo "- api_base: ${API_BASE}"
echo "- quantization: 4-bit MLX"
echo ""
echo "Usage:"
echo "  opencode"
