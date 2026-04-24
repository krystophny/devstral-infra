#!/usr/bin/env bash
# Start the Mac dual-instance llama.cpp deployment:
#   * 35B-A3B Q4 (MoE)  served as qwen-35b-a3b on port 8080
#   * 27B Q4 (dense)    served as qwen-27b      on port 8081
# Each instance uses -c 262144 -np 2 (128K per slot), Q8_0 KV cache, FA on,
# Metal (no --cpu-moe), and the blessed Qwen "precise coding + thinking"
# sampler. This is the macOS equivalent of server_start_llamacpp.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "server_start_mac.sh is macOS only; use server_start_llamacpp.sh elsewhere"

start_one() {
  local instance="$1" port="$2" alias="$3" model_alias="$4"
  LLAMACPP_INSTANCE="${instance}" \
  LLAMACPP_PORT="${port}" \
  LLAMACPP_SERVED_ALIAS="${alias}" \
  LLAMACPP_MODEL_ALIAS="${model_alias}" \
  LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-262144}" \
  LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-2}" \
  bash "${SCRIPT_DIR}/server_start_llamacpp.sh"
}

start_one 35b-a3b 8080 qwen-35b-a3b qwen3.6-35b-a3b-q4
start_one 27b     8081 qwen-27b     qwen3.6-27b-q4

echo "both llama.cpp instances up:"
echo "  qwen-35b-a3b -> http://127.0.0.1:8080/v1"
echo "  qwen-27b     -> http://127.0.0.1:8081/v1"
