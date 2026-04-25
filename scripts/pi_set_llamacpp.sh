#!/usr/bin/env bash
# Configure Pi Coding Agent to use the local llama.cpp OpenAI-compatible API.
#
# On macOS dual-instance hosts (>= 64 GB unified memory):
#   * llamacpp     -> 127.0.0.1:8081 (qwen-27b, dense, default, image input)
#   * llamacpp-moe -> 127.0.0.1:8080 (qwen-35b-a3b, MoE, image input)
# On Linux/Windows and small Macs:
#   * llamacpp     -> 127.0.0.1:8080 (qwen, MoE, image input)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
HOST="${LLAMACPP_HOST:-127.0.0.1}"
CONTEXT_SIZE_DEFAULT=262144
if [[ "${PLATFORM}" == "mac" ]]; then
  ram_gb="$(detect_total_ram_gb)"
  [[ "${ram_gb}" -lt 64 ]] && CONTEXT_SIZE_DEFAULT=131072
fi
CONTEXT_SIZE="${PI_LOCAL_CONTEXT:-${CONTEXT_SIZE_DEFAULT}}"
OUTPUT_LIMIT="${PI_LOCAL_OUTPUT:-16384}"
THINKING_LEVEL="${PI_LOCAL_THINKING_LEVEL:-high}"

MAC_SINGLE=false
if [[ "${PLATFORM}" == "mac" ]]; then
  case "${PI_MAC_SINGLE:-${OPENCODE_MAC_SINGLE:-}}" in
    force|true|1) MAC_SINGLE=true ;;
    no|false|0)   MAC_SINGLE=false ;;
    *)
      [[ "${ram_gb:-0}" -lt 64 ]] && MAC_SINGLE=true
      ;;
  esac
fi

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
SETTINGS_PATH="${CONFIG_DIR}/settings.json"
MODELS_PATH="${CONFIG_DIR}/models.json"
mkdir -p "${CONFIG_DIR}"

LAYOUT="single"
if [[ "${PLATFORM}" == "mac" && "${MAC_SINGLE}" != "true" ]]; then
  LAYOUT="dual"
fi

python3 - "${SETTINGS_PATH}" "${MODELS_PATH}" "${HOST}" "${CONTEXT_SIZE}" "${OUTPUT_LIMIT}" "${THINKING_LEVEL}" "${LAYOUT}" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
models_path = pathlib.Path(sys.argv[2])
host = sys.argv[3]
context = int(sys.argv[4])
output = int(sys.argv[5])
thinking = sys.argv[6]
layout = sys.argv[7]

def read_json(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        backup = path.with_suffix(path.suffix + ".devstral-infra.bak")
        backup.write_text(path.read_text())
        return {}

compat = {
    "supportsDeveloperRole": False,
    "supportsReasoningEffort": False,
    "supportsUsageInStreaming": False,
    "maxTokensField": "max_tokens",
}
zero_cost = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}

def model_entry(model_id, name, image):
    return {
        "id": model_id,
        "name": name,
        "reasoning": True,
        "input": ["text", "image"] if image else ["text"],
        "contextWindow": context,
        "maxTokens": output,
        "cost": zero_cost,
    }

settings = read_json(settings_path)
models = read_json(models_path)
providers = models.setdefault("providers", {})

if layout == "dual":
    providers["llamacpp"] = {
        "baseUrl": f"http://{host}:8081/v1",
        "api": "openai-completions",
        "apiKey": "llamacpp",
        "compat": compat,
        "models": [model_entry("qwen-27b", "Qwen3.6 27B Q4 + KV-Q8 (Local dense, image)", image=True)],
    }
    providers["llamacpp-moe"] = {
        "baseUrl": f"http://{host}:8080/v1",
        "api": "openai-completions",
        "apiKey": "llamacpp",
        "compat": compat,
        "models": [model_entry("qwen-35b-a3b", "Qwen3.6 35B A3B Q4 + KV-Q8 (Local MoE, image)", image=True)],
    }
    settings.update({
        "defaultProvider": "llamacpp",
        "defaultModel": "qwen-27b",
        "defaultThinkingLevel": thinking,
        "enabledModels": ["llamacpp/qwen-27b", "llamacpp-moe/qwen-35b-a3b"],
        "enableInstallTelemetry": False,
    })
else:
    providers["llamacpp"] = {
        "baseUrl": f"http://{host}:8080/v1",
        "api": "openai-completions",
        "apiKey": "llamacpp",
        "compat": compat,
        "models": [model_entry("qwen", "Qwen3.6 35B A3B Q4 + KV-Q8 (Local llama.cpp)", image=True)],
    }
    settings.update({
        "defaultProvider": "llamacpp",
        "defaultModel": "qwen",
        "defaultThinkingLevel": thinking,
        "enabledModels": ["llamacpp/qwen"],
        "enableInstallTelemetry": False,
    })

settings_path.write_text(json.dumps(settings, indent=2) + "\n")
models_path.write_text(json.dumps(models, indent=2) + "\n")
PY

if [[ "${PI_SKIP_PRIVACY_ENV:-false}" != "true" ]]; then
  bash "${SCRIPT_DIR}/pi_privacy.sh"
fi

echo "configured Pi:"
echo "- settings: ${SETTINGS_PATH}"
echo "- models:   ${MODELS_PATH}"
if [[ "${LAYOUT}" == "dual" ]]; then
  echo "- providers: llamacpp -> :8081 (qwen-27b, default), llamacpp-moe -> :8080 (qwen-35b-a3b, image)"
else
  echo "- provider: llamacpp -> :8080 (qwen, image)"
fi
echo "- context:  ${CONTEXT_SIZE}"
echo "- output:   ${OUTPUT_LIMIT}"
echo "- thinking: ${THINKING_LEVEL}"
