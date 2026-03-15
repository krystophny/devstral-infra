#!/usr/bin/env bash
# Configure Codex CLI for local llama.cpp server with two profiles:
#   local (thinking/coding on port 8080) and fast (non-thinking on port 8081).
# Also generates model catalog JSON to eliminate metadata warnings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LOCAL_API_BASE="${CODEX_LOCAL_API_BASE:-http://127.0.0.1:8080/v1}"
FAST_API_BASE="${CODEX_FAST_API_BASE:-http://127.0.0.1:8081/v1}"
LOCAL_MODEL="${CODEX_LOCAL_MODEL:-Qwen3.5-35B-A3B}"
FAST_MODEL="${CODEX_FAST_MODEL:-Qwen3.5-9B}"
LOCAL_CONTEXT="${CODEX_LOCAL_CONTEXT:-$(default_local_agent_context)}"
FAST_CONTEXT="${CODEX_FAST_CONTEXT:-$(default_fast_agent_context)}"
SUPPORTED_LOCAL_MODELS_JSON="${CODEX_SUPPORTED_LOCAL_MODELS_JSON:-[
  [\"Qwen3.5-0.8B\", 262144, \"medium\"],
  [\"Qwen3.5-2B\", 262144, \"medium\"],
  [\"Qwen3.5-4B\", 262144, \"medium\"],
  [\"Qwen3.5-9B\", 262144, \"medium\"],
  [\"GPT-OSS-20B\", 131072, \"medium\"],
  [\"Devstral-Small-2-24B-Instruct-2512\", 57344, \"medium\"],
  [\"Qwen3.5-27B\", 65536, \"medium\"],
  [\"Qwen3-Coder-30B-A3B-Instruct\", 50000, \"medium\"],
  [\"Qwen3.5-35B-A3B\", 50000, \"medium\"]
]}"

CODEX_DIR="${CODEX_CONFIG_DIR:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_DIR}/config.toml}"
CATALOG_PATH="${CODEX_CATALOG_PATH:-${CODEX_DIR}/local-models.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")" "$(dirname "${CATALOG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
    cp "${CONFIG_PATH}" "${BACKUP_PATH}"
    echo "backup: ${BACKUP_PATH}"
fi

BASE_INSTRUCTIONS="You are a helpful coding assistant. Use exec_command for shell commands and apply_patch for file edits. Do not use MCP or filesystem tools."

# Generate model catalog JSON
python3 - "${CATALOG_PATH}" "${LOCAL_MODEL}" "${LOCAL_CONTEXT}" "${FAST_MODEL}" "${FAST_CONTEXT}" "${BASE_INSTRUCTIONS}" "${SUPPORTED_LOCAL_MODELS_JSON}" <<'PY'
import json
import sys

path = sys.argv[1]
local_model, local_ctx = sys.argv[2], int(sys.argv[3])
fast_model, fast_ctx = sys.argv[4], int(sys.argv[5])
base_instructions = sys.argv[6]
supported_local_models = json.loads(sys.argv[7])

def model_entry(slug, display, ctx, reasoning_level, reasoning_levels):
    return {
        "slug": slug,
        "display_name": display,
        "base_instructions": base_instructions,
        "context_window": ctx,
        "auto_compact_token_limit": int(ctx * 0.6),
        "default_reasoning_level": reasoning_level,
        "supported_reasoning_levels": reasoning_levels,
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

thinking_levels = [
    {"effort": "low", "description": "Fast responses with lighter reasoning"},
    {"effort": "medium", "description": "Balances speed and reasoning depth"},
    {"effort": "high", "description": "Greater reasoning depth for complex problems"},
]
fast_levels = [
    {"effort": "low", "description": "Fast responses"},
    {"effort": "medium", "description": "Moderate reasoning"},
]

catalog_models = []
seen = set()
for slug, ctx, default_reasoning in supported_local_models:
    if slug in seen:
        continue
    seen.add(slug)
    reasoning_levels = thinking_levels if default_reasoning != "low" else fast_levels
    catalog_models.append(model_entry(slug, f"{slug} (local)", int(ctx), default_reasoning, reasoning_levels))

if local_model not in seen:
    seen.add(local_model)
    catalog_models.append(model_entry(local_model, f"{local_model} (local)", local_ctx, "medium", thinking_levels))

if fast_model not in seen:
    seen.add(fast_model)
    catalog_models.append(model_entry(fast_model, f"{fast_model} (local fast)", fast_ctx, "low", fast_levels))

catalog = {"models": catalog_models}

with open(path, "w") as f:
    json.dump(catalog, f, indent=2)
    f.write("\n")
PY

echo "catalog: ${CATALOG_PATH}"

# Note: we do NOT strip top-level model/model_reasoning_effort — those are the
# user's default OpenAI settings.  Profiles are selected explicitly with -p.

# Generate config blocks
CATALOG_BEGIN="# BEGIN DEVSTRAL MODEL CATALOG"
CATALOG_END="# END DEVSTRAL MODEL CATALOG"
CATALOG_BLOCK="$(cat <<EOF
${CATALOG_BEGIN}
model_catalog_json = "${CATALOG_PATH}"
${CATALOG_END}
EOF
)"

BEGIN_MARKER="# BEGIN DEVSTRAL LOCAL MODELS"
END_MARKER="# END DEVSTRAL LOCAL MODELS"
BLOCK="$(cat <<EOF
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

replace_block() {
    local path="$1" begin="$2" end="$3" new_block="$4"
    python3 - "$path" "$begin" "$end" "$new_block" <<'PY'
import sys
path, begin, end, new_block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
start = content.index(begin)
stop = content.index(end) + len(end)
tail = content[stop:]
content = content[:start] + new_block + tail
with open(path, "w") as f:
    f.write(content)
PY
}

prepend_block() {
    local path="$1" new_block="$2"
    python3 - "$path" "$new_block" <<'PY'
import sys
path, new_block = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
with open(path, "w") as f:
    f.write(new_block)
    f.write("\n\n")
    f.write(content)
PY
}

if [[ -f "${CONFIG_PATH}" ]]; then
    if grep -q "${CATALOG_BEGIN}" "${CONFIG_PATH}"; then
        replace_block "${CONFIG_PATH}" "${CATALOG_BEGIN}" "${CATALOG_END}" "${CATALOG_BLOCK}"
    else
        prepend_block "${CONFIG_PATH}" "${CATALOG_BLOCK}"
    fi
    if grep -q "${BEGIN_MARKER}" "${CONFIG_PATH}"; then
        replace_block "${CONFIG_PATH}" "${BEGIN_MARKER}" "${END_MARKER}" "${BLOCK}"
    else
        printf '\n%s\n' "${BLOCK}" >> "${CONFIG_PATH}"
    fi
else
    printf '%s\n\n%s\n' "${CATALOG_BLOCK}" "${BLOCK}" > "${CONFIG_PATH}"
fi

echo "Configured Codex CLI for local llama.cpp:"
echo "- config: ${CONFIG_PATH}"
echo "- catalog: ${CATALOG_PATH}"
echo "- profile 'local': ${LOCAL_MODEL} at ${LOCAL_API_BASE} (${LOCAL_CONTEXT} ctx)"
echo "- profile 'fast': ${FAST_MODEL} at ${FAST_API_BASE} (${FAST_CONTEXT} ctx)"
echo "- web_search: disabled (llama.cpp does not support Codex web_search tool)"
echo ""
echo "Usage:"
echo "  1. Start servers: scripts/server_start_llamacpp.sh local"
echo "                    scripts/server_start_llamacpp.sh fast"
echo "  2. Run: codex -p local"
echo "  3. Or:  codex -p fast"
