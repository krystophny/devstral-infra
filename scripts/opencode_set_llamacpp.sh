#!/usr/bin/env bash
# Configure OpenCode for the local llama.cpp deployment.
#
# On macOS, registers the dual-instance profile:
#   * qwen-27b      (default, dense Qwen3.6 27B Q4)  -> http://127.0.0.1:8081/v1
#   * qwen-35b-a3b  (small_model, MoE)               -> http://127.0.0.1:8080/v1
# Both use the Qwen "precise coding + thinking" sampler (temp 0.6, top_p 0.95,
# top_k 20, min_p 0, presence 0, repeat_penalty 1.0) and 131072-token per-slot
# context to match the launcher's -c 262144 -np 2.
#
# On Linux/Windows, keeps the single-instance profile (35B-A3B on 8080).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
HOST="${LLAMACPP_HOST:-127.0.0.1}"
# Per-slot context: Mac dual-instance launcher runs -c 524288 -np 2 (262144
# per slot = the model's native n_ctx_train). Non-Mac single-instance keeps
# -c 262144 -np 2 (131072 per slot).
if [[ "${PLATFORM}" == "mac" ]]; then
  CONTEXT_SIZE_DEFAULT=262144
else
  CONTEXT_SIZE_DEFAULT=131072
fi
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-${CONTEXT_SIZE_DEFAULT}}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-16384}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.devstral-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

sampler_opts() {
  cat <<EOF
"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096
EOF
}

model_block() {
  local id="$1" name="$2"
  cat <<EOF
        "${id}": {
          "name": "${name}",
          "limit": {"context": ${CONTEXT_SIZE}, "output": ${OUTPUT_LIMIT}},
          "reasoning": true,
          "tool_call": true,
          "options": {$(sampler_opts)}
        }
EOF
}

provider_block_single() {
  local port="$1" id="$2" name="$3"
  cat <<EOF
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (Local)",
      "options": {"baseURL": "http://${HOST}:${port}/v1"},
      "models": {
$(model_block "${id}" "${name}")
      }
    }
  }
EOF
}

provider_block_dual_mac() {
  cat <<EOF
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp 27B (Local)",
      "options": {"baseURL": "http://${HOST}:8081/v1"},
      "models": {
$(model_block "qwen-27b" "Qwen3.6 27B Q4 + KV-Q8 (Local dense)")
      }
    },
    "llamacpp-moe": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp 35B-A3B (Local)",
      "options": {"baseURL": "http://${HOST}:8080/v1"},
      "models": {
$(model_block "qwen-35b-a3b" "Qwen3.6 35B A3B Q4 + KV-Q8 (Local MoE)")
      }
    }
  }
EOF
}

case "${PLATFORM}" in
  mac)
    DEFAULT_MODEL="llamacpp/qwen-27b"
    SMALL_MODEL="llamacpp-moe/qwen-35b-a3b"
    PROVIDER_BLOCK="$(provider_block_dual_mac)"
    DISABLED='"disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"]'
    ;;
  *)
    DEFAULT_MODEL="${OPENCODE_LOCAL_DEFAULT_MODEL:-llamacpp/qwen}"
    SMALL_MODEL="${OPENCODE_LOCAL_SMALL_MODEL:-llamacpp/qwen}"
    PROVIDER_BLOCK="$(provider_block_single 8080 qwen "Qwen3.6 35B A3B Q4 + KV-Q8 (Local)")"
    DISABLED='"disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"]'
    ;;
esac

cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${DEFAULT_MODEL}",
  "small_model": "${SMALL_MODEL}",
  "agent": {
    "title": {"disable": true}
  },
  "share": "disabled",
  "autoupdate": false,
  "permission": "allow",
  "tools": {
    "websearch": false
  },
  "experimental": {
    "openTelemetry": false
  },
  ${DISABLED},
${PROVIDER_BLOCK}
}
EOF

if [[ "${OPENCODE_SKIP_PRIVACY_ENV:-false}" != "true" ]]; then
  bash "${SCRIPT_DIR}/opencode_privacy.sh"
fi

echo "configured OpenCode:"
echo "- config: ${CONFIG_PATH}"
echo "- default model: ${DEFAULT_MODEL}"
echo "- small model:   ${SMALL_MODEL}"
case "${PLATFORM}" in
  mac)
    echo "- providers: llamacpp -> :8081 (qwen-27b), llamacpp-moe -> :8080 (qwen-35b-a3b)"
    ;;
  *)
    echo "- provider:  llamacpp -> :8080 (qwen)"
    ;;
esac
echo "- title:      disabled"
echo "- permission: allow"
