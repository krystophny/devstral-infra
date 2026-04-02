#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

BASE_URL="${SEARXNG_BASE_URL:-http://192.168.1.1:8888}"
MCP_SCRIPT="${SEARXNG_MCP_SCRIPT:-${REPO_ROOT}/server/searxng_mcp.py}"

CODEX_DIR="${CODEX_CONFIG_DIR:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_DIR}/config.toml}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

BEGIN_MARKER="# BEGIN DEVSTRAL SEARXNG MCP"
END_MARKER="# END DEVSTRAL SEARXNG MCP"

block="$(cat <<EOF
${BEGIN_MARKER}
[mcp_servers.searxng]
command = "python3"
args = ["${MCP_SCRIPT}"]

[mcp_servers.searxng.env]
SEARXNG_BASE_URL = "${BASE_URL}"
${END_MARKER}
EOF
)"

python3 - "${CONFIG_PATH}" "${BEGIN_MARKER}" "${END_MARKER}" "${block}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]
block = sys.argv[4]
content = path.read_text() if path.exists() else ""
content = re.sub(
    r'(?ms)^\[mcp_servers\.searxng\]\n(?:.+\n)*?(?=^\[|^#|\Z)',
    '',
    content,
)
content = re.sub(
    r'(?ms)^\[mcp_servers\.searxng\.env\]\n(?:.+\n)*?(?=^\[|^#|\Z)',
    '',
    content,
)
if begin in content and end in content:
    start = content.index(begin)
    stop = content.index(end) + len(end)
    tail = content[stop:]
    content = content[:start] + block + tail
elif content:
    content = content.rstrip() + "\n\n" + block + "\n"
else:
    content = block + "\n"
path.write_text(content)
PY

echo "Configured Codex MCP:"
echo "- config: ${CONFIG_PATH}"
echo "- command: python3 ${MCP_SCRIPT}"
echo "- base_url: ${BASE_URL}"
