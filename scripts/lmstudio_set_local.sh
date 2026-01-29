#!/usr/bin/env bash
# Configure OpenCode for LM Studio with GPT-OSS 20B (default) or GLM-4.7-Flash
# Reference: https://lmstudio.ai/docs/cli
# Reference: https://opencode.ai/docs/providers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

if [[ "${platform}" != "mac" ]]; then
    echo "Error: LM Studio only works on macOS in this setup"
    exit 1
fi

# Model settings - default to GPT-OSS 20B (efficient everywhere, 128k context)
# For GLM-4.7-Flash: LMSTUDIO_MODEL_HF=zai-org/GLM-4.7-Flash LMSTUDIO_MODEL_ID=glm-4.7-flash
MODEL_HF="${LMSTUDIO_MODEL_HF:-openai/gpt-oss-20b}"
MODEL_ID="${LMSTUDIO_MODEL_ID:-gpt-oss-20b}"
MODEL_NAME="${LMSTUDIO_MODEL_NAME:-GPT-OSS 20B 16k (local)}"
CONTEXT_SIZE="${LMSTUDIO_CONTEXT_SIZE:-16384}"
API_BASE="${LMSTUDIO_API_BASE:-http://localhost:1234/v1}"

# Use bundled lms CLI (more reliable than npx version)
LMS="/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"
if [[ ! -x "${LMS}" ]]; then
    echo "Error: LM Studio not found. Install with: brew install --cask lm-studio"
    exit 1
fi

# Check if model exists locally
if ! "${LMS}" ls 2>/dev/null | grep -qi "${MODEL_ID}"; then
    echo "Model ${MODEL_ID} not found locally."
    echo "Please download it in LM Studio GUI or run:"
    echo "  ${LMS} get ${MODEL_HF}"
    exit 1
fi

# Start LM Studio app if not running
if ! curl -s "${API_BASE}/models" &>/dev/null; then
    echo "Starting LM Studio..."
    open -a "LM Studio"
    sleep 5
fi

# Unload all models and load with proper context and identifier
echo "Loading ${MODEL_ID} with ${CONTEXT_SIZE} context..."
"${LMS}" unload --all 2>/dev/null || true
"${LMS}" load "${MODEL_HF}" --gpu max -c "${CONTEXT_SIZE}" --identifier "${MODEL_ID}"

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
          "name": "${MODEL_NAME}"
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
echo ""
echo "Usage:"
echo "  opencode"
