#!/usr/bin/env bash
# Start llama.cpp server with the validated local Qwen3.5 OpenCode profile.
# Usage: server_start_llamacpp.sh [instance]
#   instance: "local" (default, port 8080, thinking on) or "fast" (port 8081, thinking off)
#   Also settable via LLAMACPP_INSTANCE env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

migrate_legacy_pid

# --- Instance resolution ---
INSTANCE="${1:-${LLAMACPP_INSTANCE:-local}}"
if [[ "${INSTANCE}" != "local" && "${INSTANCE}" != "fast" ]]; then
  die "unknown instance: ${INSTANCE} (expected: local, fast)"
fi

# Migrate old unsuffixed pid/port/log files to the "local" instance
for ext in pid port log; do
  old="${RUN_DIR}/llamacpp.${ext}"
  new="${RUN_DIR}/llamacpp-local.${ext}"
  if [[ -f "${old}" && ! -f "${new}" ]]; then
    mv "${old}" "${new}"
  fi
  rm -f "${old}"
done

# Helper: resolve an instance-specific env var with fallback to the generic one.
# Usage: instance_var VARNAME DEFAULT
#   Checks LLAMACPP_{UPPER_INSTANCE}_{VARNAME}, then LLAMACPP_{VARNAME}, then DEFAULT.
instance_var() {
  local varname="$1" default="$2"
  local upper_instance
  upper_instance="$(printf '%s' "${INSTANCE}" | tr '[:lower:]' '[:upper:]')"
  local specific="LLAMACPP_${upper_instance}_${varname}"
  local generic="LLAMACPP_${varname}"
  if [[ -n "${!specific:-}" ]]; then
    printf '%s' "${!specific}"
  elif [[ -n "${!generic:-}" ]]; then
    printf '%s' "${!generic}"
  else
    printf '%s' "${default}"
  fi
}

# --- Instance defaults ---
case "${INSTANCE}" in
  local)
    DEFAULT_PORT="8080"
    DEFAULT_MODEL_ALIAS="qwen3.5-35b-a3b"
    DEFAULT_CONTEXT="131072"
    DEFAULT_THINKING="true"
    ;;
  fast)
    DEFAULT_PORT="8081"
    DEFAULT_MODEL_ALIAS="qwen3.5-9b"
    DEFAULT_CONTEXT="131072"
    DEFAULT_THINKING="false"
    ;;
esac

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
MODELS_SCRIPT="${SCRIPT_DIR}/llamacpp_models.py"

# Check if llama.cpp is installed
if [[ ! -x "${LLAMA_SERVER}" ]]; then
  die "llama.cpp not installed. Run: scripts/setup_llamacpp.sh"
fi

export DYLD_LIBRARY_PATH="${LLAMA_SERVER_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"

HOST="${DEVSTRAL_HOST:-0.0.0.0}"
PORT="${DEVSTRAL_PORT:-${DEFAULT_PORT}}"

PID_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.pid"
LOG_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.log"
PORT_FILE="${RUN_DIR}/llamacpp-${INSTANCE}.port"
START_TIMEOUT="${LLAMACPP_START_TIMEOUT:-900}"

# Model configuration.
usable_mb="$(detect_vram_mb)"
MODEL_PATH="${LLAMACPP_MODEL:-}"
HF_MODEL=""
MODEL_ALIAS="$(instance_var MODEL_ALIAS "${DEFAULT_MODEL_ALIAS}")"
if [[ -z "${MODEL_PATH}" ]]; then
  if [[ -n "${LLAMACPP_HF_MODEL:-}" ]]; then
    HF_MODEL="${LLAMACPP_HF_MODEL}"
  else
    if [[ -x "${MODELS_SCRIPT}" || -f "${MODELS_SCRIPT}" ]]; then
      resolved_path="$(python3 "${MODELS_SCRIPT}" resolve "${MODEL_ALIAS}" 2>/dev/null || true)"
      if [[ -n "${resolved_path}" && -f "${resolved_path}" ]]; then
        MODEL_PATH="${resolved_path}"
      fi
    fi
    if [[ -z "${MODEL_PATH}" ]]; then
      case "${MODEL_ALIAS}" in
        qwen3.5-0.8b) HF_MODEL="lmstudio-community/Qwen3.5-0.8B-GGUF:Q8_0" ;;
        qwen3.5-2b) HF_MODEL="lmstudio-community/Qwen3.5-2B-GGUF:Q8_0" ;;
        qwen3.5-4b) HF_MODEL="lmstudio-community/Qwen3.5-4B-GGUF:Q8_0" ;;
        qwen3.5-9b) HF_MODEL="lmstudio-community/Qwen3.5-9B-GGUF:Q8_0" ;;
        qwen3.5-27b) HF_MODEL="lmstudio-community/Qwen3.5-27B-GGUF:Q8_0" ;;
        qwen3.5-35b-a3b) HF_MODEL="lmstudio-community/Qwen3.5-35B-A3B-GGUF:Q8_0" ;;
        qwen3.5-122b-a10b) HF_MODEL="lmstudio-community/Qwen3.5-122B-A10B-GGUF:Q8_0" ;;
        gpt-oss-20b) HF_MODEL="ggml-org/gpt-oss-20b-GGUF" ;;
        gpt-oss-120b) HF_MODEL="ggml-org/gpt-oss-120b-GGUF" ;;
        nemotron-120b-a12b) HF_MODEL="lmstudio-community/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF:Q8_0" ;;
        qwen3-coder-next) HF_MODEL="lmstudio-community/Qwen3-Coder-Next-GGUF:Q8_0" ;;
        qwen3-coder-30b-a3b) HF_MODEL="lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q8_0" ;;
        devstral-small-2-24b) HF_MODEL="lmstudio-community/Devstral-Small-2-24B-Instruct-2512-GGUF:Q8_0" ;;
        devstral-2-123b) HF_MODEL="lmstudio-community/Devstral-2-123B-Instruct-2512-GGUF:Q8_0" ;;
        *)
          if [[ "${usable_mb}" -ge 180000 ]]; then
            HF_MODEL="lmstudio-community/Qwen3.5-122B-A10B-GGUF:Q8_0"
          else
            HF_MODEL="lmstudio-community/Qwen3.5-35B-A3B-GGUF:Q8_0"
          fi
          ;;
      esac
    fi
  fi
fi

# Context and throughput configuration
CONTEXT_SIZE="$(instance_var CONTEXT "${DEFAULT_CONTEXT}")"
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
ENABLE_THINKING="${LLAMACPP_ENABLE_THINKING:-${DEFAULT_THINKING}}"
SMOKE_TEST="${LLAMACPP_SMOKE_TEST:-true}"
SMOKE_TEST_PROMPT="${LLAMACPP_SMOKE_TEST_PROMPT:-Reply with exactly READY.}"
DRY_RUN="${LLAMACPP_DRY_RUN:-false}"
# Check if already running
if [[ "${DRY_RUN}" != "true" && -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "already running (pid ${pid})"
    exit 0
  fi
  rm -f "${PID_FILE}"
fi
# Safety: ensure port is free (kill orphans from stale PID files or crashed launchd)
if [[ "${DRY_RUN}" != "true" ]]; then
  orphan_pids="$(lsof -ti ":${PORT}" 2>/dev/null || true)"
  if [[ -n "${orphan_pids}" ]]; then
    echo "WARNING: port ${PORT} occupied by orphan process(es), killing..."
    echo "${orphan_pids}" | xargs kill -9 2>/dev/null || true
    sleep 2
  fi
fi
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

echo "Starting llama.cpp server (instance: ${INSTANCE})..."
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
echo "- Model alias: ${MODEL_ALIAS}"
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
  --alias qwen               # Stable model name for API clients
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

# Start server via native service manager
LAUNCHD_LABEL="com.devstral.llamacpp-${INSTANCE}"
SYSTEMD_UNIT="devstral-llamacpp-${INSTANCE}"
platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
  # macOS: launchd user agent
  PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true

  mkdir -p "${HOME}/Library/LaunchAgents"
  local_args_xml=""
  for arg in "${CMD[@]}"; do
    arg="${arg//&/&amp;}"
    arg="${arg//</&lt;}"
    arg="${arg//>/&gt;}"
    local_args_xml+="      <string>${arg}</string>
"
  done

  cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${local_args_xml}  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key>
    <string>${DYLD_LIBRARY_PATH:-}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
  <key>KeepAlive</key>
  <false/>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

  if launchctl load "${PLIST_PATH}" 2>/dev/null; then
    sleep 1
    pid="$(launchctl list "${LAUNCHD_LABEL}" 2>/dev/null | awk '{print $1}')"
    if [[ -z "${pid}" || "${pid}" == "-" ]]; then
      die "launchd failed to start ${LAUNCHD_LABEL}. Check: ${LOG_FILE}"
    fi
    echo "- managed by: launchd (${LAUNCHD_LABEL})"
  else
    # launchctl load fails from SSH sessions (macOS security restriction).
    # Fall back to a detached child process started in a new session.
    pid="$(
      python3 - "${LOG_FILE}" "${CMD[@]}" <<'PY'
import subprocess
import sys

log_path = sys.argv[1]
cmd = sys.argv[2:]

with open(log_path, "ab", buffering=0) as log_file:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
    print(proc.pid)
PY
    )"
    if [[ -z "${pid}" ]]; then
      die "failed to launch detached llama.cpp background process"
    fi
    echo "- managed by: background process (launchd plist installed for future use)"
  fi

else
  # Linux/WSL: systemd user unit
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl not found. systemd is required on Linux."
  fi

  UNIT_DIR="${HOME}/.config/systemd/user"
  UNIT_PATH="${UNIT_DIR}/${SYSTEMD_UNIT}.service"
  mkdir -p "${UNIT_DIR}"

  printf -v exec_start_line '%q ' "${CMD[@]}"

  cat > "${UNIT_PATH}" <<UNIT
[Unit]
Description=llama.cpp inference server (devstral-infra)

[Service]
Type=simple
ExecStart=${exec_start_line}
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=LD_LIBRARY_PATH=${LLAMA_SERVER_DIR}

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload
  systemctl --user stop "${SYSTEMD_UNIT}" 2>/dev/null || true
  systemctl --user start "${SYSTEMD_UNIT}"
  pid="$(systemctl --user show -p MainPID --value "${SYSTEMD_UNIT}")"
  if [[ -z "${pid}" || "${pid}" == "0" ]]; then
    die "systemd failed to start ${SYSTEMD_UNIT}. Check: journalctl --user -u ${SYSTEMD_UNIT}"
  fi
  echo "- managed by: systemd --user (${SYSTEMD_UNIT})"
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

  model_id=""
  for (( i = 1; i <= START_TIMEOUT; i++ )); do
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
    )" 2>/dev/null && break || true
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "Model-id probe failed because llama.cpp exited. Check log: ${LOG_FILE}"
      tail -30 "${LOG_FILE}"
      exit 1
    fi
    if (( i % 10 == 0 )); then
      echo "Still waiting for /v1/models to stabilize... (${i}s)"
    fi
    sleep 1
  done

  if [[ -z "${model_id}" ]]; then
    echo "Smoke test failed: could not obtain model id from /v1/models"
    bash "${SCRIPT_DIR}/server_stop_llamacpp.sh" "${INSTANCE}" >/dev/null 2>&1 || true
    exit 1
  fi

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

  smoke_response=""
  smoke_error=""
  smoke_ready="false"
  for (( i = 1; i <= START_TIMEOUT; i++ )); do
    smoke_response="$(
      curl -sS \
        -H 'Content-Type: application/json' \
        "http://${HOST}:${PORT}/v1/chat/completions" \
        -d "${smoke_payload}" \
        2>&1
    )"
    smoke_rc=$?
    if [[ ${smoke_rc} -eq 0 ]]; then
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
      if [[ "${smoke_text}" == *"READY"* ]]; then
        smoke_ready="true"
        break
      fi
      smoke_error="unexpected smoke response: ${smoke_response}"
    else
      smoke_error="${smoke_response}"
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "Smoke test failed because llama.cpp exited. Check log: ${LOG_FILE}"
      tail -30 "${LOG_FILE}"
      exit 1
    fi
    if (( i % 10 == 0 )); then
      echo "Still waiting for inference readiness... (${i}s)"
    fi
    sleep 1
  done

  if [[ "${smoke_ready}" != "true" ]]; then
    echo "Smoke test failed: expected READY in response"
    printf '%s\n' "${smoke_error}"
    bash "${SCRIPT_DIR}/server_stop_llamacpp.sh" "${INSTANCE}" >/dev/null 2>&1 || true
    exit 1
  fi

  echo "Smoke test passed"
fi

cat <<EOF
started llama.cpp [${INSTANCE}] (pid ${pid})
- url: http://${HOST}:${PORT}/v1
- log: ${LOG_FILE}
- context: ${CONTEXT_SIZE} tokens
- ctx checkpoints: ${CTX_CHECKPOINTS}
- checkpoint interval: $(if [[ "${supports_checkpoint_interval}" == "true" ]]; then printf '%s tokens' "${CHECKPOINT_EVERY_N_TOKENS}"; else printf '%s' 'runtime default'; fi)
- thinking: ${ENABLE_THINKING}

Note: First request may be slow while model loads into memory.
EOF
