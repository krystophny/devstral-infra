#!/usr/bin/env bash
# Configure OpenCode for the local llama.cpp deployment.
#
# On macOS, registers the dual-instance profile:
#   * qwen-27b      (default, dense Qwen3.6 27B Q4)  -> http://127.0.0.1:8081/v1
#   * qwen-35b-a3b  (small_model, MoE)               -> http://127.0.0.1:8080/v1
# Both use the Qwen "precise coding + thinking" sampler (temp 0.6, top_p 0.95,
# top_k 20, min_p 0, presence 0, repeat_penalty 1.0) and 262144-token per-slot
# context (Mac runs -c 524288 -np 2).
#
# On Linux/Windows, keeps the single-instance profile (35B-A3B on 8080) with
# the full 262144-token context on a single slot (-c 262144 -np 1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
HOST="${LLAMACPP_HOST:-127.0.0.1}"
# Per-slot context = model's native n_ctx_train (262144) on every platform.
# Mac dual-instance runs -c 524288 -np 2 (two slots per instance). Linux/Windows
# run -c 262144 -np 1 so the single client gets the full window; opencode auto-
# compaction otherwise fires at ~79K with two slots (overflow buffer eats
# ~52K of a 131K per-slot context). Single-instance MacBooks with ~32 GB use
# 131072 (128K) to keep KV cache within available unified memory.
CONTEXT_SIZE_DEFAULT=262144
if [[ "$(detect_platform)" == "mac" ]]; then
  ram_gb="$(detect_total_ram_gb)"
  [[ "${ram_gb}" -lt 64 ]] && CONTEXT_SIZE_DEFAULT=131072
fi
CONTEXT_SIZE="${OPENCODE_LOCAL_CONTEXT:-${CONTEXT_SIZE_DEFAULT}}"
OUTPUT_LIMIT="${OPENCODE_LOCAL_OUTPUT:-16384}"
THINKING_BUDGET="${OPENCODE_LOCAL_THINKING_BUDGET:-$(default_reasoning_budget)}"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_PATH="${OPENCODE_CONFIG_PATH:-${CONFIG_DIR}/opencode.json}"
mkdir -p "$(dirname "${CONFIG_PATH}")"

BACKUP_PATH="${CONFIG_PATH}.slopcode-infra.bak"
if [[ -f "${CONFIG_PATH}" && ! -f "${BACKUP_PATH}" ]]; then
  cp "${CONFIG_PATH}" "${BACKUP_PATH}"
  echo "backup: ${BACKUP_PATH}"
fi

sampler_opts() {
  cat <<EOF
"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": ${THINKING_BUDGET}
EOF
}

model_block() {
  local id="$1" name="$2"
  cat <<EOF
        "${id}": {
          "name": "${name}",
          "limit": {"context": ${CONTEXT_SIZE}, "output": ${OUTPUT_LIMIT}},
          "reasoning": true,
          "attachment": true,
          "tool_call": true,
          "modalities": {"input": ["text", "image"], "output": ["text"]},
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

# Mac dual-instance requires >= 64 GB unified memory. On smaller MacBooks the
# 27B dense model and its KV cache don't fit alongside the 35B-A3B, so fall
# back to single-instance (same config as Linux/Windows). Override with
# OPENCODE_MAC_SINGLE=force|no if auto-detection is wrong.
MAC_SINGLE=false
if [[ "${PLATFORM}" == "mac" ]]; then
  case "${OPENCODE_MAC_SINGLE:-}" in
    force|true|1) MAC_SINGLE=true ;;
    no|false|0)   MAC_SINGLE=false ;;
    *)
      ram_gb="$(detect_total_ram_gb)"
      [[ "${ram_gb}" -lt 64 ]] && MAC_SINGLE=true
      ;;
  esac
fi

case "${PLATFORM}" in
  mac)
    if [[ "${MAC_SINGLE}" == "true" ]]; then
      DEFAULT_MODEL="${OPENCODE_LOCAL_DEFAULT_MODEL:-llamacpp/qwen}"
      SMALL_MODEL="${OPENCODE_LOCAL_SMALL_MODEL:-llamacpp/qwen}"
      PROVIDER_BLOCK="$(provider_block_single 8080 qwen "Qwen3.6 35B A3B Q4 + KV-Q8 (Local)")"
    else
      DEFAULT_MODEL="llamacpp/qwen-27b"
      SMALL_MODEL="llamacpp-moe/qwen-35b-a3b"
      PROVIDER_BLOCK="$(provider_block_dual_mac)"
    fi
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
    if [[ "${MAC_SINGLE}" == "true" ]]; then
      echo "- provider:  llamacpp -> :8080 (qwen) [single-instance, ${ram_gb} GB RAM]"
    else
      echo "- providers: llamacpp -> :8081 (qwen-27b), llamacpp-moe -> :8080 (qwen-35b-a3b)"
    fi
    ;;
  *)
    echo "- provider:  llamacpp -> :8080 (qwen)"
    ;;
esac
echo "- title:      disabled"
echo "- permission: allow"
echo "- thinking budget: ${THINKING_BUDGET}"
