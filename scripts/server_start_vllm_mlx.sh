#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

INSTANCE="${1:-${VLLM_MLX_INSTANCE:-local}}"
if [[ "${INSTANCE}" != "local" && "${INSTANCE}" != "fast" ]]; then
  die "unknown instance: ${INSTANCE} (expected: local, fast)"
fi

instance_var() {
  local varname="$1" default="$2"
  local upper_instance
  upper_instance="$(printf '%s' "${INSTANCE}" | tr '[:lower:]' '[:upper:]')"
  local specific="VLLM_MLX_${upper_instance}_${varname}"
  local generic="VLLM_MLX_${varname}"
  if [[ -n "${!specific:-}" ]]; then
    printf '%s' "${!specific}"
  elif [[ -n "${!generic:-}" ]]; then
    printf '%s' "${!generic}"
  else
    printf '%s' "${default}"
  fi
}

case "${INSTANCE}" in
  local)
    DEFAULT_PORT="8080"
    DEFAULT_MODEL_ALIAS="qwen3.5-35b-a3b"
    DEFAULT_SERVED_NAME="qwen"
    ;;
  fast)
    DEFAULT_PORT="8081"
    DEFAULT_MODEL_ALIAS="qwen3.5-9b"
    DEFAULT_SERVED_NAME="qwen"
    ;;
esac

HOST="${DEVSTRAL_HOST:-0.0.0.0}"
HEALTHCHECK_HOST="${DEVSTRAL_HEALTHCHECK_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-${DEFAULT_PORT}}"
MODEL_ALIAS="$(instance_var MODEL_ALIAS "${DEFAULT_MODEL_ALIAS}")"
SERVED_NAME="$(instance_var SERVED_MODEL_NAME "${DEFAULT_SERVED_NAME}")"
SMOKE_TEST="${VLLM_MLX_SMOKE_TEST:-true}"
SMOKE_TEST_PROMPT="${VLLM_MLX_SMOKE_TEST_PROMPT:-Reply with exactly READY.}"
START_TIMEOUT="${VLLM_MLX_START_TIMEOUT:-1800}"
DRY_RUN="${VLLM_MLX_DRY_RUN:-false}"

VLLM_MLX_REPO="${VLLM_MLX_REPO:-/Users/user/code/vllm-mlx}"
VLLM_MLX_PYTHON="${VLLM_MLX_PYTHON:-/Users/user/code/.venv/bin/python}"
REGISTRY="${SCRIPT_DIR}/vllm_mlx_models.py"

if [[ ! -f "${REGISTRY}" ]]; then
  die "missing model registry: ${REGISTRY}"
fi
if [[ ! -d "${VLLM_MLX_REPO}" ]]; then
  die "missing vllm-mlx repo: ${VLLM_MLX_REPO}"
fi
if [[ ! -x "${VLLM_MLX_PYTHON}" ]]; then
  die "missing python executable: ${VLLM_MLX_PYTHON}"
fi

ensure_cli_supports_served_model_name() {
  local help_output
  if ! help_output="$(
    PYTHONPATH="${VLLM_MLX_REPO}" \
    "${VLLM_MLX_PYTHON}" -m vllm_mlx.cli serve --help 2>&1
  )"; then
    die "failed to inspect vllm-mlx serve CLI at ${VLLM_MLX_REPO}: ${help_output}"
  fi
  if [[ "${help_output}" != *"--served-model-name"* ]]; then
    die "vllm-mlx checkout at ${VLLM_MLX_REPO} does not support --served-model-name. Update to upstream main or newer (waybarrios/vllm-mlx#125)."
  fi
}

ensure_cli_supports_served_model_name

repo_id="$(python3 "${REGISTRY}" resolve "${MODEL_ALIAS}" --field repo_id)"
default_max_tokens="$(python3 "${REGISTRY}" resolve "${MODEL_ALIAS}" --field default_max_tokens)"
tool_call_parser="$(python3 "${REGISTRY}" resolve "${MODEL_ALIAS}" --field tool_call_parser)"
reasoning_parser="$(python3 "${REGISTRY}" resolve "${MODEL_ALIAS}" --field reasoning_parser)"
MAX_TOKENS="$(instance_var MAX_TOKENS "${default_max_tokens:-32768}")"

PID_FILE="${RUN_DIR}/vllm-mlx-${INSTANCE}.pid"
LOG_FILE="${RUN_DIR}/vllm-mlx-${INSTANCE}.log"
PORT_FILE="${RUN_DIR}/vllm-mlx-${INSTANCE}.port"

if [[ "${DRY_RUN}" != "true" && -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "already running (pid ${pid})"
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  orphan_pids="$(lsof -ti ":${PORT}" 2>/dev/null || true)"
  if [[ -n "${orphan_pids}" ]]; then
    echo "WARNING: port ${PORT} occupied by orphan process(es), killing..."
    echo "${orphan_pids}" | xargs kill -9 2>/dev/null || true
    sleep 2
  fi
fi

CMD=(
  "${VLLM_MLX_PYTHON}"
  -m
  vllm_mlx.cli
  serve
  "${repo_id}"
  --served-model-name
  "${SERVED_NAME}"
  --host
  "${HOST}"
  --port
  "${PORT}"
  --max-tokens
  "${MAX_TOKENS}"
  --continuous-batching
  --enable-auto-tool-choice
)

if [[ -n "${tool_call_parser}" ]]; then
  CMD+=(--tool-call-parser "${tool_call_parser}")
fi
if [[ -n "${reasoning_parser}" ]]; then
  CMD+=(--reasoning-parser "${reasoning_parser}")
fi
if [[ -n "${VLLM_MLX_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CMD+=(${VLLM_MLX_EXTRA_FLAGS})
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'dry-run:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

LAUNCHD_LABEL="com.devstral.vllm-mlx-${INSTANCE}"
platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
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
    <key>PYTHONPATH</key>
    <string>${VLLM_MLX_REPO}</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>${VLLM_MLX_REPO}</string>
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
  else
    pid="$(
      PYTHONPATH="${VLLM_MLX_REPO}" \
      "${VLLM_MLX_PYTHON}" - "${LOG_FILE}" "${CMD[@]}" <<'PY'
import os
import subprocess
import sys

log_path = sys.argv[1]
cmd = sys.argv[2:]
env = os.environ.copy()

with open(log_path, "ab", buffering=0) as log_file:
    proc = subprocess.Popen(
        cmd,
        env=env,
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
      die "failed to launch detached vllm-mlx background process"
    fi
  fi
else
  die "server_start_vllm_mlx.sh currently supports macOS only"
fi

echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

echo "Waiting for vllm-mlx model API to become ready..."
for (( i = 1; i <= START_TIMEOUT; i++ )); do
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "Failed to start. Check log: ${LOG_FILE}"
    tail -30 "${LOG_FILE}" || true
    exit 1
  fi
  if curl -fsS "http://${HEALTHCHECK_HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ "${SMOKE_TEST}" == "true" ]]; then
  payload="$(
    python3 - "${SERVED_NAME}" "${SMOKE_TEST_PROMPT}" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 32,
    "temperature": 0.0,
}))
PY
  )"
  response="$(
    curl -sS \
      -H 'Content-Type: application/json' \
      "http://${HEALTHCHECK_HOST}:${PORT}/v1/chat/completions" \
      -d "${payload}"
  )"
  if [[ "${response}" != *"READY"* ]]; then
    echo "Smoke test failed"
    printf '%s\n' "${response}"
    exit 1
  fi
fi

cat <<EOF
started vllm-mlx [${INSTANCE}] (pid ${pid})
- model alias: ${MODEL_ALIAS}
- repo: ${repo_id}
- served model name: ${SERVED_NAME}
- tool parser: ${tool_call_parser:-auto}
- reasoning parser: ${reasoning_parser:-none}
- bind host: ${HOST}
- local url: http://${HEALTHCHECK_HOST}:${PORT}/v1
- log: ${LOG_FILE}
EOF
