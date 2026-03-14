#!/usr/bin/env bash
# Configure Codex CLI for local llama.cpp server with two profiles:
#   local (thinking/coding on port 8080) and fast (non-thinking on port 8081).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LOCAL_API_BASE="${CODEX_LOCAL_API_BASE:-http://127.0.0.1:8080/v1}"
FAST_API_BASE="${CODEX_FAST_API_BASE:-http://127.0.0.1:8081/v1}"
LOCAL_MODEL="${CODEX_LOCAL_MODEL:-qwen3.5}"
FAST_MODEL="${CODEX_FAST_MODEL:-qwen3.5}"

CONFIG_PATH="${CODEX_CONFIG_PATH:-${HOME}/.codex/config.toml}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

BEGIN_MARKER="# BEGIN DEVSTRAL LOCAL MODELS"
END_MARKER="# END DEVSTRAL LOCAL MODELS"

block="$(cat <<EOF
${BEGIN_MARKER}
[model_providers.local]
name = "Local llama.cpp"
base_url = "${LOCAL_API_BASE}"
wire_api = "responses"

[model_providers.fast]
name = "Fast llama.cpp"
base_url = "${FAST_API_BASE}"
wire_api = "responses"

[profiles.local]
model_provider = "local"
model = "${LOCAL_MODEL}"
web_search = "disabled"

[profiles.fast]
model_provider = "fast"
model = "${FAST_MODEL}"
web_search = "disabled"
${END_MARKER}
EOF
)"

if [[ -f "${CONFIG_PATH}" ]]; then
    if grep -q "${BEGIN_MARKER}" "${CONFIG_PATH}"; then
        # Replace existing block in-place
        python3 - "${CONFIG_PATH}" "${BEGIN_MARKER}" "${END_MARKER}" "${block}" <<'PY'
import sys
path, begin, end, new_block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
start = content.index(begin)
stop = content.index(end) + len(end)
# Preserve trailing newline
tail = content[stop:]
content = content[:start] + new_block + tail
with open(path, "w") as f:
    f.write(content)
PY
    else
        # Append block to existing config
        printf '\n%s\n' "${block}" >> "${CONFIG_PATH}"
    fi
else
    printf '%s\n' "${block}" > "${CONFIG_PATH}"
fi

echo "Configured Codex CLI for local llama.cpp:"
echo "- config: ${CONFIG_PATH}"
echo "- profile 'local': ${LOCAL_MODEL} at ${LOCAL_API_BASE}"
echo "- profile 'fast': ${FAST_MODEL} at ${FAST_API_BASE}"
echo "- web_search: disabled (llama.cpp does not support Codex web_search tool)"
echo ""
echo "Usage:"
echo "  1. Start servers: scripts/server_start_llamacpp.sh local"
echo "                    scripts/server_start_llamacpp.sh fast"
echo "  2. Run: codex -p local"
echo "  3. Or:  codex -p fast"
