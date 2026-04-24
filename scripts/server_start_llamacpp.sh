#!/usr/bin/env bash
# Start one llama-server instance. Defaults match the blessed Qwen3.6 profile:
#   Q8_0 KV cache, flash attention, 128K per-slot context across 2 parallel slots,
#   --cpu-moe on Linux/Windows, Metal (no --cpu-moe) on Mac, reasoning enabled.
#
# This script runs a single instance. For the Mac dual-instance deployment
# (35B-A3B on 8080 + 27B on 8081) use scripts/server_start_mac.sh, which calls
# this script twice with instance-specific ports, aliases, and file names.
#
# Env overrides:
#   LLAMACPP_HOME         install dir (default ~/.local/llama.cpp)
#   LLAMACPP_SERVER_BIN   explicit llama-server binary
#   LLAMACPP_MODEL        explicit GGUF path (else resolved via llamacpp_models.py)
#   LLAMACPP_MODEL_ALIAS  alias from the model registry (default: blessed)
#   LLAMACPP_INSTANCE     name suffix for pid/port/log files (default: empty -> .run/llamacpp.*)
#   LLAMACPP_SERVED_ALIAS --alias served in /v1/models (default: qwen)
#   LLAMACPP_CONTEXT      total context size across slots (default 262144, i.e. 128K x 2 slots)
#   LLAMACPP_PORT         listen port (default 8080)
#   LLAMACPP_HOST         bind host (default 0.0.0.0)
#   LLAMACPP_PARALLEL     concurrent slots (default 2)
#   LLAMACPP_CPU_MOE      force on/off (default: on for non-Mac)
#   LLAMACPP_DRY_RUN      true to print the command and exit
#   LLAMACPP_SMOKE_TEST   false to skip the post-start /v1/chat/completions probe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

PLATFORM="$(detect_platform)"
MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"

# --- Binary resolution ---
SERVER_EXE="llama-server"
[[ "${PLATFORM}" == "windows" ]] && SERVER_EXE="llama-server.exe"
if [[ -n "${LLAMACPP_SERVER_BIN:-}" ]]; then
  LLAMA_SERVER="${LLAMACPP_SERVER_BIN}"
elif [[ -x "${LLAMACPP_HOME}/${SERVER_EXE}" ]]; then
  LLAMA_SERVER="${LLAMACPP_HOME}/${SERVER_EXE}"
elif have "${SERVER_EXE}"; then
  LLAMA_SERVER="$(command -v "${SERVER_EXE}")"
else
  die "llama-server not installed. Run: scripts/setup_llamacpp.sh"
fi
[[ -x "${LLAMA_SERVER}" ]] || die "not executable: ${LLAMA_SERVER}"

LLAMA_SERVER_DIR="$(cd "$(dirname "${LLAMA_SERVER}")" && pwd)"
export LD_LIBRARY_PATH="${LLAMA_SERVER_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export DYLD_LIBRARY_PATH="${LLAMA_SERVER_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

# --- Model resolution ---
DEFAULT_ALIAS="$(python3 "${MODELS_SCRIPT}" default-alias)"
MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-${DEFAULT_ALIAS}}"
MODEL_PATH="${LLAMACPP_MODEL:-}"
if [[ -z "${MODEL_PATH}" ]]; then
  if resolved="$(python3 "${MODELS_SCRIPT}" resolve "${MODEL_ALIAS}" 2>/dev/null)" && [[ -n "${resolved}" && -f "${resolved}" ]]; then
    MODEL_PATH="${resolved}"
  fi
fi
[[ -n "${MODEL_PATH}" ]] || die "model not found. Run: scripts/llamacpp_models.py prefetch"
[[ -f "${MODEL_PATH}" || "${LLAMACPP_DRY_RUN:-false}" == "true" ]] || die "model file missing: ${MODEL_PATH}"

# --- Runtime parameters ---
HOST="${LLAMACPP_HOST:-0.0.0.0}"
PORT="${LLAMACPP_PORT:-8080}"
CONTEXT="${LLAMACPP_CONTEXT:-262144}"
BATCH="${LLAMACPP_BATCH:-2048}"
UBATCH="${LLAMACPP_UBATCH:-512}"
NGL="${LLAMACPP_NGL:-99}"

# Two concurrent slots per instance: on CPU-MoE hosts it lets the harness fan
# out a main request plus one subagent without duplicating weights; on Mac
# the dual-instance deployment gives each model its own pair of slots.
PARALLEL="${LLAMACPP_PARALLEL:-2}"

CPU_MOE_DEFAULT="false"
[[ "${PLATFORM}" != "mac" ]] && CPU_MOE_DEFAULT="true"
CPU_MOE="${LLAMACPP_CPU_MOE:-${CPU_MOE_DEFAULT}}"

SERVED_ALIAS="${LLAMACPP_SERVED_ALIAS:-qwen}"
INSTANCE="${LLAMACPP_INSTANCE:-}"
if [[ -n "${INSTANCE}" ]]; then
  PID_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.pid"
  PORT_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.port"
  LOG_FILE="${LOG_DIR}/llamacpp-${INSTANCE}.log"
else
  PID_FILE="${RUN_DIR}/llamacpp.pid"
  PORT_FILE="${RUN_DIR}/llamacpp.port"
  LOG_FILE="${LOG_DIR}/llamacpp.log"
fi

DRY_RUN="${LLAMACPP_DRY_RUN:-false}"
SMOKE_TEST="${LLAMACPP_SMOKE_TEST:-true}"
START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-900}"

stop_llamacpp_port_occupants "${PORT}" "llama.cpp server"

SAMPLER_ARGS=()
case "${MODEL_ALIAS}" in
  minimax-*)
    SAMPLER_ARGS+=(
      --temp 1.0
      --top-p 0.95
      --top-k 40
      --reasoning on
    )
    ;;
  *)
    SAMPLER_ARGS+=(
      --temp 0.6
      --top-p 0.95
      --top-k 20
      --min-p 0
      --presence-penalty 0.0
      --repeat-penalty 1.0
      --reasoning-format deepseek
      --no-context-shift
      --reasoning on
    )
    ;;
esac

CMD=(
  "${LLAMA_SERVER}"
  -m "${MODEL_PATH}"
  -c "${CONTEXT}"
  -b "${BATCH}"
  -ub "${UBATCH}"
  -ngl "${NGL}"
  -fa on
  --cache-type-k q8_0
  --cache-type-v q8_0
  --host "${HOST}"
  --port "${PORT}"
  --alias "${SERVED_ALIAS}"
  --jinja
  -np "${PARALLEL}"
)
CMD+=("${SAMPLER_ARGS[@]}")
if [[ "${CPU_MOE}" == "true" ]]; then
  CMD+=(--cpu-moe)
fi

echo "starting llama.cpp server"
echo "- binary:  ${LLAMA_SERVER}"
"${LLAMA_SERVER}" --version 2>&1 | awk '/^version: / || /^built with /{print "- " $0}' || true
echo "- model:   ${MODEL_PATH}"
echo "- alias:   ${MODEL_ALIAS} (served as ${SERVED_ALIAS})"
echo "- bind:    ${HOST}:${PORT}"
echo "- context: ${CONTEXT}"
echo "- slots:   ${PARALLEL}"
echo "- KV:      q8_0 / q8_0"
echo "- cpu-moe: ${CPU_MOE}"
[[ -n "${INSTANCE}" ]] && echo "- instance: ${INSTANCE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!
echo "${SERVER_PID}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"
echo "- pid:     ${SERVER_PID}"
echo "- log:     ${LOG_FILE}"

probe_host="${HOST}"
[[ "${probe_host}" == "0.0.0.0" ]] && probe_host="127.0.0.1"

echo "waiting for /v1/models (timeout ${START_TIMEOUT}s)..."
deadline=$(( $(date +%s) + START_TIMEOUT ))
while : ; do
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    tail -n 40 "${LOG_FILE}" >&2 || true
    die "llama-server exited before becoming ready"
  fi
  if curl -fsS "http://${probe_host}:${PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  [[ $(date +%s) -ge ${deadline} ]] && die "timed out waiting for llama-server"
  sleep 2
done
echo "server is ready on http://${probe_host}:${PORT}/v1"

if [[ "${SMOKE_TEST}" == "true" ]]; then
  echo "running chat smoke test..."
  resp="$(curl -fsS "http://${probe_host}:${PORT}/v1/chat/completions" \
    -H "content-type: application/json" \
    -d "{\"model\":\"${SERVED_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly READY.\"}],\"max_tokens\":16}")"
  if [[ "${resp}" == *'"content"'* ]]; then
    echo "smoke test OK"
  else
    echo "${resp}" >&2
    die "smoke test did not return a chat completion"
  fi
fi
