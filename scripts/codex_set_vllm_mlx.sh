#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LOCAL_API_BASE="${CODEX_LOCAL_API_BASE:-http://127.0.0.1:8080/v1}"
FAST_API_BASE="${CODEX_FAST_API_BASE:-http://127.0.0.1:8081/v1}"
LOCAL_MODEL="${CODEX_LOCAL_MODEL:-Qwen3.5-35B-A3B}"
FAST_MODEL="${CODEX_FAST_MODEL:-Qwen3.5-9B}"
LOCAL_CONTEXT="${CODEX_LOCAL_CONTEXT:-262144}"
FAST_CONTEXT="${CODEX_FAST_CONTEXT:-32768}"

CODEX_DIR="${CODEX_CONFIG_DIR:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_DIR}/config.toml}"
CATALOG_PATH="${CODEX_CATALOG_PATH:-${CODEX_DIR}/local-models.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")" "$(dirname "${CATALOG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
fi

python3 - "${SCRIPT_DIR}/vllm_mlx_models.py" "${CATALOG_PATH}" "${LOCAL_CONTEXT}" "${FAST_CONTEXT}" <<'PY'
import json
import subprocess
import sys

registry, catalog_path, local_ctx, fast_ctx = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
records = json.loads(subprocess.check_output([sys.executable, registry, "inventory", "--mode", "benchmark", "--json"], text=True))

def entry(slug, ctx):
    return {
        "slug": slug,
        "display_name": f"{slug} (local)",
        "base_instructions": "You have exactly these tools: exec_command (shell commands) and apply_patch (file edits). Do not use MCP, filesystem, or any tools not listed.",
        "context_window": ctx,
        "auto_compact_token_limit": int(ctx * 0.6),
        "default_reasoning_level": "medium",
        "supported_reasoning_levels": [
            {"effort": "low", "description": "Fast responses with lighter reasoning"},
            {"effort": "medium", "description": "Balances speed and reasoning depth"},
            {"effort": "high", "description": "Greater reasoning depth for complex problems"},
        ],
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": 0,
        "supports_reasoning_summaries": False,
        "support_verbosity": False,
        "truncation_policy": {"mode": "tokens", "limit": 10000},
        "supports_parallel_tool_calls": True,
        "experimental_supported_tools": [],
        "input_modalities": ["text"],
        "prefer_websockets": False,
    }

models = []
for record in records:
    ctx = fast_ctx if record["codex_model"] == "Qwen3.5-9B" else local_ctx
    models.append(entry(record["codex_model"], ctx))

with open(catalog_path, "w") as fh:
    json.dump({"models": models}, fh, indent=2)
    fh.write("\n")
PY

BEGIN_MARKER="# BEGIN DEVSTRAL LOCAL MODELS"
END_MARKER="# END DEVSTRAL LOCAL MODELS"
LEGACY_BEGIN_MARKER="# BEGIN TABURA LOCAL MODELS"
LEGACY_END_MARKER="# END TABURA LOCAL MODELS"
block="$(cat <<EOF
${BEGIN_MARKER}
model_catalog_json = "${CATALOG_PATH}"

[model_providers.local]
name = "Local vllm-mlx"
base_url = "${LOCAL_API_BASE}"
wire_api = "responses"

[model_providers.fast]
name = "Fast vllm-mlx"
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
  if grep -q "${BEGIN_MARKER}" "${CONFIG_PATH}" || grep -q "${LEGACY_BEGIN_MARKER}" "${CONFIG_PATH}"; then
    python3 - "${CONFIG_PATH}" "${BEGIN_MARKER}" "${END_MARKER}" "${LEGACY_BEGIN_MARKER}" "${LEGACY_END_MARKER}" "${block}" <<'PY'
import sys
path, begin, end, legacy_begin, legacy_end, new_block = sys.argv[1:7]
with open(path) as fh:
    content = fh.read()

def strip_block(text, block_begin, block_end):
    if block_begin not in text:
        return text
    start = text.index(block_begin)
    stop = text.index(block_end) + len(block_end)
    while stop < len(text) and text[stop] == "\n":
        stop += 1
    return text[:start].rstrip() + "\n\n" + text[stop:].lstrip()

content = strip_block(content, legacy_begin, legacy_end)
content = strip_block(content, begin, end)
with open(path, "w") as fh:
    if content and not content.endswith("\n"):
        content += "\n"
    fh.write(content.rstrip() + "\n\n" + new_block + "\n")
PY
  else
    printf '\n%s\n' "${block}" >> "${CONFIG_PATH}"
  fi
else
  printf '%s\n' "${block}" > "${CONFIG_PATH}"
fi

echo "Configured Codex CLI for local vllm-mlx:"
echo "- config: ${CONFIG_PATH}"
echo "- catalog: ${CATALOG_PATH}"
