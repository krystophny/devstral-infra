#!/usr/bin/env bash
# Configure aider for local llama.cpp server with Qwen3.5-122B-A10B Q8_0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

# llama.cpp uses port 8080 by default
PORT="${DEVSTRAL_PORT:-8080}"
HOST="${DEVSTRAL_HOST:-127.0.0.1}"
API_BASE="${AIDER_LOCAL_API_BASE:-http://${HOST}:${PORT}/v1}"

# Model identifier for aider
MODEL_ID="${AIDER_LOCAL_MODEL_ID:-openai/qwen}"
EDIT_FORMAT="${AIDER_LOCAL_EDIT_FORMAT:-diff}"
CONTEXT_SIZE="${AIDER_LOCAL_CONTEXT:-262144}"

# aider global config
CONF_PATH="${HOME}/.aider.conf.yml"
CONF_BACKUP="${CONF_PATH}.devstral-infra.bak"
if [[ -f "${CONF_PATH}" && ! -f "${CONF_BACKUP}" ]]; then
    cp "${CONF_PATH}" "${CONF_BACKUP}"
    echo "backup: ${CONF_BACKUP}"
fi

cat > "${CONF_PATH}" <<EOF
model: ${MODEL_ID}
openai-api-base: ${API_BASE}
openai-api-key: local
auto-commits: false
yes-always: true
stream: true
edit-format: ${EDIT_FORMAT}
map-tokens: 4096
EOF

# aider model settings
MODEL_SETTINGS_PATH="${HOME}/.aider.model.settings.yml"
MODEL_SETTINGS_BACKUP="${MODEL_SETTINGS_PATH}.devstral-infra.bak"
if [[ -f "${MODEL_SETTINGS_PATH}" && ! -f "${MODEL_SETTINGS_BACKUP}" ]]; then
    cp "${MODEL_SETTINGS_PATH}" "${MODEL_SETTINGS_BACKUP}"
    echo "backup: ${MODEL_SETTINGS_BACKUP}"
fi

cat > "${MODEL_SETTINGS_PATH}" <<EOF
- name: ${MODEL_ID}
  edit_format: ${EDIT_FORMAT}
  use_repo_map: true
  send_undo_reply: false
  extra_params:
    temperature: 0.6
    top_p: 0.95
    max_tokens: 32768
EOF

echo "Configured aider for local llama.cpp:"
echo "- config: ${CONF_PATH}"
echo "- model settings: ${MODEL_SETTINGS_PATH}"
echo "- model: ${MODEL_ID}"
echo "- edit format: ${EDIT_FORMAT}"
echo "- api_base: ${API_BASE}"
echo ""
echo "Usage:"
echo "  1. Start server: scripts/server_start_llamacpp.sh"
echo "  2. Run: aider"
