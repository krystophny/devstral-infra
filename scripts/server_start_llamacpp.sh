#!/usr/bin/env bash
# Start llama.cpp server with the validated local Qwen3.5 OpenCode profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

migrate_legacy_pid

SIBLING_LLAMA_SERVER="/Users/user/code/llama.cpp-dev/llama.cpp/build/bin/llama-server"
LLAMACPP_DIR="${HOME}/.local/llama.cpp"
if [[ -n "${LLAMACPP_SERVER_BIN:-}" ]]; then
  LLAMA_SERVER="${LLAMACPP_SERVER_BIN}"
elif [[ -x "${SIBLING_LLAMA_SERVER}" ]]; then
  LLAMA_SERVER="${SIBLING_LLAMA_SERVER}"
else
  LLAMA_SERVER="${LLAMACPP_DIR}/llama-server"
fi
LLAMA_SERVER_DIR="$(cd "$(dirname "${LLAMA_SERVER}")" && pwd)"
QWEN122B_Q8_CACHE_DIR="${HOME}/Library/Caches/llama.cpp/lmstudio-community_Qwen3.5-122B-A10B-GGUF"
QWEN122B_Q8_CACHE_PATH="${QWEN122B_Q8_CACHE_DIR}/Qwen3.5-122B-A10B-Q8_0-00001-of-00004.gguf"

# Check if llama.cpp is installed
if [[ ! -x "${LLAMA_SERVER}" ]]; then
  die "llama.cpp not installed. Run: scripts/setup_llamacpp.sh"
fi

export DYLD_LIBRARY_PATH="${LLAMA_SERVER_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"

PID_FILE="${RUN_DIR}/llamacpp.pid"
LOG_FILE="${RUN_DIR}/llamacpp.log"
PORT_FILE="${RUN_DIR}/llamacpp.port"
TMUX_FILE="${RUN_DIR}/llamacpp.tmux"
START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-900}"
TMUX_SESSION="${LLAMACPP_TMUX_SESSION:-devstral-llamacpp}"

# Check if already running
if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "already running (pid ${pid})"
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

# Model configuration.
usable_mb="$(detect_vram_mb)"
MODEL_PATH="${LLAMACPP_MODEL:-}"
HF_MODEL=""
if [[ -z "${MODEL_PATH}" ]]; then
  if [[ -n "${LLAMACPP_HF_MODEL:-}" ]]; then
    HF_MODEL="${LLAMACPP_HF_MODEL}"
  elif [[ -f "${QWEN122B_Q8_CACHE_PATH}" ]]; then
    MODEL_PATH="${QWEN122B_Q8_CACHE_PATH}"
  elif [[ "${usable_mb}" -ge 180000 ]]; then
    HF_MODEL="lmstudio-community/Qwen3.5-122B-A10B-GGUF:Q8_0"
  else
    die "Qwen3.5-122B-A10B Q8_0 requires a larger-memory profile or an explicit LLAMACPP_MODEL/LLAMACPP_HF_MODEL override"
  fi
fi

# Context and throughput configuration
CONTEXT_SIZE="${LLAMACPP_CONTEXT:-262144}"
CTX_CHECKPOINTS="${LLAMACPP_CTX_CHECKPOINTS:-64}"
CHECKPOINT_EVERY_N_TOKENS="${LLAMACPP_CHECKPOINT_EVERY_N_TOKENS:-4096}"
BATCH_SIZE="${LLAMACPP_BATCH:-2048}"
UBATCH_SIZE="${LLAMACPP_UBATCH:-512}"
if command -v nproc >/dev/null 2>&1; then
  cpu_count="$(nproc)"
else
  cpu_count="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
fi
CPU_THREADS="${LLAMACPP_THREADS:-${cpu_count}}"
ENABLE_THINKING="${LLAMACPP_ENABLE_THINKING:-true}"
SMOKE_TEST="${LLAMACPP_SMOKE_TEST:-true}"
SMOKE_TEST_PROMPT="${LLAMACPP_SMOKE_TEST_PROMPT:-Reply with exactly READY.}"
DRY_RUN="${LLAMACPP_DRY_RUN:-false}"
LAUNCHER="${LLAMACPP_LAUNCHER:-auto}"
# Use reasonable number of threads
CPU_THREADS=$(( CPU_THREADS > 24 ? 24 : CPU_THREADS ))

supports_checkpoint_interval="false"
supports_reasoning_toggle="false"
if [[ "${DRY_RUN}" == "true" ]]; then
  supports_checkpoint_interval="true"
  supports_reasoning_toggle="true"
else
  help_output="$("${LLAMA_SERVER}" --help 2>&1 || true)"
  if [[ "${help_output}" == *"--checkpoint-every-n-tokens"* ]]; then
    supports_checkpoint_interval="true"
  fi
  if [[ "${help_output}" == *"--reasoning [on|off|auto]"* ]]; then
    supports_reasoning_toggle="true"
  fi
fi

# Optional tensor offload rule. Leave empty for max speed on Apple Silicon.
MOE_OFFLOAD="${LLAMACPP_MOE_OFFLOAD:-}"

echo "Starting llama.cpp server..."
echo "- Binary: ${LLAMA_SERVER}"
version_output="$("${LLAMA_SERVER}" --version 2>&1 || true)"
if [[ -n "${version_output}" ]]; then
  while IFS= read -r line; do
    echo "- ${line}"
  done <<< "$(printf '%s\n' "${version_output}" | awk '/^version: / || /^built with /')"
fi
if [[ -n "${MODEL_PATH}" ]]; then
  echo "- Model: ${MODEL_PATH}"
else
  echo "- Model: ${HF_MODEL} (HuggingFace, will download if needed)"
fi
echo "- Context: ${CONTEXT_SIZE} tokens"
echo "- Context checkpoints: ${CTX_CHECKPOINTS}"
if [[ "${supports_checkpoint_interval}" == "true" ]]; then
  echo "- Checkpoint interval: ${CHECKPOINT_EVERY_N_TOKENS} tokens"
else
  echo "- Checkpoint interval: runtime default (installed llama.cpp build does not support explicit tuning)"
fi
echo "- Batch: ${BATCH_SIZE}"
echo "- Ubatch: ${UBATCH_SIZE}"
echo "- CPU threads: ${CPU_THREADS}"
echo "- Thinking: ${ENABLE_THINKING}"
echo "- Smoke test: ${SMOKE_TEST}"
if [[ -n "${MOE_OFFLOAD}" ]]; then
  echo "- tensor offload rule: ${MOE_OFFLOAD}"
fi

if [[ "${LAUNCHER}" == "auto" ]]; then
  if [[ "$(detect_platform)" == "mac" ]] && command -v tmux >/dev/null 2>&1; then
    LAUNCHER="tmux"
  else
    LAUNCHER="nohup"
  fi
fi
echo "- launcher: ${LAUNCHER}"

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
  --ctx-checkpoints "${CTX_CHECKPOINTS}"
  -b "${BATCH_SIZE}"
  -ub "${UBATCH_SIZE}"
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
  if [[ "${supports_reasoning_toggle}" == "true" ]]; then
    CMD+=(--reasoning off)
  else
    CMD+=(--chat-template-kwargs '{"enable_thinking": false}')
  fi
fi

if [[ "${supports_checkpoint_interval}" == "true" ]]; then
  CMD+=(--checkpoint-every-n-tokens "${CHECKPOINT_EVERY_N_TOKENS}")
fi

# Add extra flags if specified
if [[ -n "${LLAMACPP_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CMD+=(${LLAMACPP_EXTRA_FLAGS})
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'dry-run:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

# Start server in background
rm -f "${TMUX_FILE}"
if [[ "${LAUNCHER}" == "tmux" ]]; then
  if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
    tmux kill-session -t "${TMUX_SESSION}" >/dev/null 2>&1 || true
  fi

  printf -v cmd_string '%q ' "${CMD[@]}"
  cmd_string="${cmd_string}>$(printf '%q' "${LOG_FILE}") 2>&1"
  tmux new-session -d -s "${TMUX_SESSION}" "exec ${cmd_string}"
  pid="$(tmux list-panes -t "${TMUX_SESSION}" -F '#{pane_pid}' | head -1)"
  echo "${TMUX_SESSION}" > "${TMUX_FILE}"
else
  nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
  pid=$!
fi
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

# Wait for the model API to become ready. /health can succeed before inference is available.
echo "Waiting for llama.cpp model API to become ready..."
for (( i = 1; i <= START_TIMEOUT; i++ )); do
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "Failed to start. Check log: ${LOG_FILE}"
    tail -30 "${LOG_FILE}"
    exit 1
  fi
  if curl -fsS "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  if (( i % 10 == 0 )); then
    echo "Still waiting... (${i}s)"
  fi
  sleep 1
done

if ! curl -fsS "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
  echo "Server started but not responding yet. Check log: ${LOG_FILE}"
  echo "It may still be loading the model."
fi

if [[ "${SMOKE_TEST}" == "true" ]]; then
  echo "Running chat-completions smoke test..."

  model_id="$(
    python3 - "http://${HOST}:${PORT}/v1/models" <<'PY'
import json
import sys
from urllib.request import urlopen

with urlopen(sys.argv[1]) as response:
    data = json.load(response)

models = data.get("data") or []
if not models:
    raise SystemExit("no model ids returned by /v1/models")

model_id = models[0].get("id")
if not model_id:
    raise SystemExit("missing model id in /v1/models response")

print(model_id)
PY
  )"

  smoke_payload="$(
    python3 - "${model_id}" "${SMOKE_TEST_PROMPT}" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 256,
    "temperature": 0.0,
    "top_p": 1.0,
    "top_k": 1,
    "min_p": 0.0,
}))
PY
  )"

  smoke_response="$(
    curl -fsS \
      -H 'Content-Type: application/json' \
      "http://${HOST}:${PORT}/v1/chat/completions" \
      -d "${smoke_payload}"
  )"

  smoke_text="$(
    python3 - "${smoke_response}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
choice = (data.get("choices") or [{}])[0]
message = choice.get("message") or {}
content = message.get("content") or ""
reasoning = message.get("reasoning_content") or ""
print((content + "\n" + reasoning).strip())
PY
  )"

  if [[ "${smoke_text}" != *"READY"* ]]; then
    echo "Smoke test failed: expected READY in response"
    printf '%s\n' "${smoke_response}"
    bash "${SCRIPT_DIR}/server_stop_llamacpp.sh" >/dev/null 2>&1 || true
    exit 1
  fi

  echo "Smoke test passed"
fi

cat <<EOF
started llama.cpp (pid ${pid})
- url: http://${HOST}:${PORT}/v1
- log: ${LOG_FILE}
- context: ${CONTEXT_SIZE} tokens
- ctx checkpoints: ${CTX_CHECKPOINTS}
- checkpoint interval: $(if [[ "${supports_checkpoint_interval}" == "true" ]]; then printf '%s tokens' "${CHECKPOINT_EVERY_N_TOKENS}"; else printf '%s' 'runtime default'; fi)

Note: First request may be slow while model loads into memory.
EOF
