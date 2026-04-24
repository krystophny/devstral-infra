#!/usr/bin/env bash
# Start one llama-server instance. Defaults match the blessed Qwen3.6 profile:
#   Q8_0 KV cache, flash attention, 256K single-slot context,
#   partial MoE offload (--n-cpu-moe 35, -ub 1024) tuned for a 16 GB CUDA
#   GPU coexisting with whisper-server (~1 GB) + Qwen3-TTS (~4.4 GB at synth
#   peak) on Linux/Windows; Metal (no MoE split) on Mac; reasoning enabled.
#
# This script runs a single instance. For the Mac dual-instance deployment
# (35B-A3B on 8080 + 27B on 8081) use scripts/server_start_mac.sh, which calls
# this script twice with instance-specific ports, aliases, and file names and
# passes LLAMACPP_PARALLEL=2 so each Mac instance keeps two slots.
#
# Env overrides:
#   LLAMACPP_HOME         install dir (default ~/.local/llama.cpp)
#   LLAMACPP_SERVER_BIN   explicit llama-server binary
#   LLAMACPP_MODEL        explicit GGUF path (else resolved via llamacpp_models.py)
#   LLAMACPP_MODEL_ALIAS  alias from the model registry (default: blessed)
#   LLAMACPP_INSTANCE     name suffix for pid/port/log files (default: empty -> .run/llamacpp.*)
#   LLAMACPP_SERVED_ALIAS --alias served in /v1/models (default: qwen)
#   LLAMACPP_CONTEXT      total context size across slots (default 262144, full ctx for one slot)
#   LLAMACPP_PORT         listen port (default 8080)
#   LLAMACPP_HOST         bind host (default 0.0.0.0)
#   LLAMACPP_PARALLEL     concurrent slots (default 1; Mac orchestrator passes 2)
#   LLAMACPP_N_CPU_MOE    number of MoE expert layers to keep on CPU
#                         (default 35 on non-Mac -> 5/40 expert layers on GPU;
#                         empty on Mac)
#   LLAMACPP_CPU_MOE      legacy on/off; true forces --n-cpu-moe 99 (all on CPU);
#                         only takes effect when LLAMACPP_N_CPU_MOE is unset.
#   LLAMACPP_UBATCH       physical batch (default 1024 on non-Mac; empty on Mac)
#   LLAMACPP_BATCH        logical batch (default 2048)
#   LLAMACPP_THREADS      compute threads (default: physical_cores - 2, min 2; Mac: unset)
#   LLAMACPP_THREADS_HTTP HTTP listener threads (default: 4 on CPU-MoE hosts; Mac: unset)
#   LLAMACPP_DRY_RUN      true to print the command and exit
#   LLAMACPP_EXEC         true to exec llama-server in the foreground (for
#                         systemd/launchd ExecStart); skips nohup, pid files,
#                         ready polling, and the smoke test — the supervisor
#                         owns the PID and restart policy.
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
# -ub sizes the GPU compute buffer. On a 16 GB RTX 5060 Ti with --n-cpu-moe 30
# and c=262144, -ub 1024 lands at ~11.0 GB VRAM (prefill 647 t/s, decode 39.7
# t/s on Qwen3.6-35B-A3B Q4_K_M). Going to -ub 2048 pushes compute buffer up
# ~1.5 GB for +28% prefill with no decode gain — left as an override for
# lightly-loaded hosts.
UBATCH="${LLAMACPP_UBATCH:-1024}"
NGL="${LLAMACPP_NGL:-99}"

# One slot per instance by default. Halving the full 262144 context across two
# slots made opencode auto-compaction fire at ~79K conversation tokens instead
# of ~210K, which was the dominant annoyance; a single user rarely needs two
# concurrent decode streams on the local box anyway, and when compaction does
# trigger it runs in-line on the only slot — slower but always successful.
# The Mac dual-instance orchestrator passes LLAMACPP_PARALLEL=2 explicitly to
# keep each of its two models at two slots on the 256 GB unified-memory box.
PARALLEL="${LLAMACPP_PARALLEL:-1}"

# Partial MoE offload: on a 16 GB CUDA GPU coexisting with whisper-server
# (~0.9 GB resident) and Qwen3-TTS (~4.4 GB at synth peak), --n-cpu-moe 35
# puts expert layers 0..34 on CPU and 35..39 on GPU. At c=262144 -ub 1024
# llama holds ~8.7 GB VRAM; with whisper + TTS at synth peak the full stack
# lands at ~14.6 GB / 16 GB, leaving ~1.3 GB headroom. Bench on RTX 5060 Ti
# (Qwen3.6-35B-A3B Q4_K_M) measured 1.9x prefill and 1.12x decode vs the old
# all-CPU-moe baseline — slightly slower than the earlier --n-cpu-moe 30
# default but leaves room for TTS to load without OOM. See commit history.
# Mac keeps everything in unified memory; no split. Setting LLAMACPP_CPU_MOE=
# true forces the old all-CPU-moe path (--n-cpu-moe 99) for emergencies.
N_CPU_MOE_DEFAULT=""
[[ "${PLATFORM}" != "mac" ]] && N_CPU_MOE_DEFAULT="35"
N_CPU_MOE="${LLAMACPP_N_CPU_MOE:-${N_CPU_MOE_DEFAULT}}"
if [[ -z "${LLAMACPP_N_CPU_MOE:-}" && "${LLAMACPP_CPU_MOE:-false}" == "true" ]]; then
  N_CPU_MOE="99"
fi

# Thread caps: only pin on non-Mac. On Mac the experts live in unified memory
# and Metal manages its own scheduler; no stalls have been observed, so
# leave llama.cpp's defaults in place. On Linux/Windows the CPU-resident
# expert layers peg every core for memory-bandwidth-bound decode, which
# starves unrelated userspace (Claude Code, opencode, DE) long enough for
# remote idle timeouts to send RSTs. Reserving 2 physical cores eliminates
# the host-side stall.
THREADS=""
THREADS_HTTP=""
if [[ "${PLATFORM}" != "mac" ]]; then
  THREADS="${LLAMACPP_THREADS:-$(default_compute_threads)}"
  THREADS_HTTP="${LLAMACPP_THREADS_HTTP:-4}"
fi

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
if [[ -n "${N_CPU_MOE}" && "${N_CPU_MOE}" != "0" ]]; then
  CMD+=(--n-cpu-moe "${N_CPU_MOE}")
fi
if [[ -n "${THREADS}" ]]; then
  CMD+=(--threads "${THREADS}" --threads-http "${THREADS_HTTP}")
fi

echo "starting llama.cpp server"
echo "- binary:  ${LLAMA_SERVER}"
"${LLAMA_SERVER}" --version 2>&1 | awk '/^version: / || /^built with /{print "- " $0}' || true
echo "- model:   ${MODEL_PATH}"
echo "- alias:   ${MODEL_ALIAS} (served as ${SERVED_ALIAS})"
echo "- bind:    ${HOST}:${PORT}"
echo "- context: ${CONTEXT}"
echo "- slots:   ${PARALLEL}"
echo "- batch:   b=${BATCH} ub=${UBATCH}"
echo "- KV:      q8_0 / q8_0"
if [[ -n "${N_CPU_MOE}" && "${N_CPU_MOE}" != "0" ]]; then
  echo "- n-cpu-moe: ${N_CPU_MOE} (first N expert layers on CPU; rest on GPU)"
else
  echo "- n-cpu-moe: off (all experts on GPU / unified memory)"
fi
if [[ -n "${THREADS}" ]]; then
  echo "- threads: ${THREADS} compute / ${THREADS_HTTP} http"
fi
[[ -n "${INSTANCE}" ]] && echo "- instance: ${INSTANCE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

# Foreground mode for systemd/launchd ExecStart: replace the shell with
# llama-server so the supervisor tracks the real process, captures stdout/
# stderr through its own logging, and applies Restart=on-failure directly.
if [[ "${LLAMACPP_EXEC:-false}" == "true" ]]; then
  exec "${CMD[@]}"
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
