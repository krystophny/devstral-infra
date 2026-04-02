#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

BASE_URL="${SEARXNG_BASE_URL:-http://192.168.1.1:8888}"
MCP_SCRIPT="${SEARXNG_MCP_SCRIPT:-${REPO_ROOT}/server/searxng_mcp.py}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

python3 - "${CONFIG_PATH}" "${MCP_SCRIPT}" "${BASE_URL}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
script_path = sys.argv[2]
base_url = sys.argv[3]
data = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else {}
mcp = data.setdefault("mcp", {})
mcp["searxng"] = {
    "type": "local",
    "enabled": True,
    "command": ["python3", script_path],
    "environment": {"SEARXNG_BASE_URL": base_url},
    "timeout": 10000,
}
path.write_text(json.dumps(data, indent=2) + "\n")
PY

echo "Configured OpenCode MCP:"
echo "- config: ${CONFIG_PATH}"
echo "- command: python3 ${MCP_SCRIPT}"
echo "- base_url: ${BASE_URL}"
