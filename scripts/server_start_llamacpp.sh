#!/usr/bin/env bash
# Start llama.cpp server optimized for fast local coding-agent workloads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

migrate_legacy_pid

LLAMACPP_DIR="${HOME}/.local/llama.cpp"
LLAMA_SERVER="${LLAMACPP_DIR}/llama-server"

# Check if llama.cpp is installed
if [[ ! -x "${LLAMA_SERVER}" ]]; then
  die "llama.cpp not installed. Run: scripts/setup_llamacpp.sh"
fi

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"

PID_FILE="${RUN_DIR}/llamacpp.pid"
LOG_FILE="${RUN_DIR}/llamacpp.log"
PORT_FILE="${RUN_DIR}/llamacpp.port"

# Check if already running
if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "already running (pid ${pid})"
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

# Model configuration
# Use HuggingFace model ID (llama.cpp will download/cache automatically).
HF_MODEL="${LLAMACPP_HF_MODEL:-unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL}"

# Or use local GGUF file if specified
MODEL_PATH="${LLAMACPP_MODEL:-}"

# Context and threading configuration
CONTEXT_SIZE="${LLAMACPP_CONTEXT:-131072}"  # 128k default
if command -v nproc >/dev/null 2>&1; then
  cpu_count="$(nproc)"
else
  cpu_count="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
fi
CPU_THREADS="${LLAMACPP_THREADS:-${cpu_count}}"
ENABLE_THINKING="${LLAMACPP_ENABLE_THINKING:-true}"
# Use reasonable number of threads
CPU_THREADS=$(( CPU_THREADS > 24 ? 24 : CPU_THREADS ))

# Optional tensor offload rule. Leave empty for max speed on Apple Silicon.
MOE_OFFLOAD="${LLAMACPP_MOE_OFFLOAD:-}"

echo "Starting llama.cpp server..."
if [[ -n "${MODEL_PATH}" ]]; then
  echo "- Model: ${MODEL_PATH}"
else
  echo "- Model: ${HF_MODEL} (HuggingFace, will download if needed)"
fi
echo "- Context: ${CONTEXT_SIZE} tokens"
echo "- CPU threads: ${CPU_THREADS}"
if [[ -n "${MOE_OFFLOAD}" ]]; then
  echo "- tensor offload rule: ${MOE_OFFLOAD}"
fi

# Build command
CMD=(
  "${LLAMA_SERVER}"
)

if [[ -n "${MODEL_PATH}" ]]; then
  CMD+=(-m "${MODEL_PATH}")
else
  CMD+=(-hf "${HF_MODEL}")
fi

CMD+=(
  -c "${CONTEXT_SIZE}"
  -ngl 99                    # Offload all possible layers to GPU
  -fa on                     # Flash attention
  -np 1                      # Single prediction slot for stable agent behavior
  -t "${CPU_THREADS}"        # CPU threads
  --host "${HOST}"
  --port "${PORT}"
  --jinja                    # Enable Jinja templating
)

if [[ -n "${MOE_OFFLOAD}" ]]; then
  CMD+=(-ot "${MOE_OFFLOAD}")
fi

if [[ "${ENABLE_THINKING}" == "false" ]]; then
  CMD+=(--chat-template-kwargs '{"enable_thinking": false}')
fi

# Add extra flags if specified
if [[ -n "${LLAMACPP_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CMD+=(${LLAMACPP_EXTRA_FLAGS})
fi

# Start server in background
nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &

pid=$!
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

# Wait for server to start (may take a while if downloading model)
echo "Waiting for server to start (may download model on first run)..."
for i in {1..120}; do
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "Failed to start. Check log: ${LOG_FILE}"
    tail -30 "${LOG_FILE}"
    exit 1
  fi
  if curl -s "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
    break
  fi
  if (( i % 10 == 0 )); then
    echo "Still waiting... (${i}s)"
  fi
  sleep 1
done

if ! curl -s "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
  echo "Server started but not responding yet. Check log: ${LOG_FILE}"
  echo "It may still be loading the model."
fi

cat <<EOF
started llama.cpp (pid ${pid})
- url: http://${HOST}:${PORT}/v1
- log: ${LOG_FILE}
- context: ${CONTEXT_SIZE} tokens (128k)

Note: First request may be slow while model loads into memory.
EOF
