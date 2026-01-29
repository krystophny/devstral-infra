#!/usr/bin/env bash
# Configure OpenCode for LM Studio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
MODEL_ID="${OPENCODE_LOCAL_MODEL_ID:-gpt-oss-20b}"
API_BASE="http://127.0.0.1:${LMSTUDIO_PORT}/v1"

CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${HOME}/.config/opencode/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.lmstudio.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

# Generate config for LM Studio
cat > "${CONFIG_PATH}" << JSON
{
  "model": "lmstudio/${MODEL_ID}",
  "provider": {
    "lmstudio": {
      "name": "LM Studio",
      "kind": "openai",
      "baseURL": "${API_BASE}",
      "apiKey": "lm-studio"
    }
  },
  "autoupdate": {
    "enabled": false
  },
  "telemetry": {
    "enabled": false
  }
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
