#!/usr/bin/env bash
# Start oMLX for a local MLX benchmark model on Apple Silicon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8000}"
MODEL_PATH="${OMLX_MODEL_PATH:-}"
MODEL_ID="${OMLX_MODEL_ID:-qwen3.5-9b-4bit}"
MODEL_DIR="${OMLX_MODEL_DIR:-${HOME}/.omlx/models}"
CACHE_DIR="${OMLX_CACHE_DIR:-${HOME}/.omlx/cache}"
CACHE_MAX_SIZE="${OMLX_CACHE_MAX_SIZE:-120GB}"
MAX_NUM_SEQS="${OMLX_MAX_NUM_SEQS:-8}"
COMPLETION_BATCH_SIZE="${OMLX_COMPLETION_BATCH_SIZE:-32}"
MAX_MODEL_MEMORY="${OMLX_MAX_MODEL_MEMORY:-}"
MAX_PROCESS_MEMORY="${OMLX_MAX_PROCESS_MEMORY:-}"
HOT_CACHE_MAX_SIZE="${OMLX_HOT_CACHE_MAX_SIZE:-}"
INITIAL_CACHE_BLOCKS="${OMLX_INITIAL_CACHE_BLOCKS:-}"
DISABLE_CACHE="${OMLX_DISABLE_CACHE:-false}"
LOG_LEVEL="${OMLX_LOG_LEVEL:-info}"
MODEL_TYPE_OVERRIDE="${OMLX_MODEL_TYPE_OVERRIDE:-llm}"
START_TIMEOUT="${OMLX_START_TIMEOUT:-900}"
SMOKE_TEST="${OMLX_SMOKE_TEST:-true}"
SMOKE_TEST_PROMPT="${OMLX_SMOKE_TEST_PROMPT:-Reply with exactly READY.}"
DRY_RUN="${OMLX_DRY_RUN:-false}"

PID_FILE="${RUN_DIR}/omlx.pid"
LOG_FILE="${RUN_DIR}/omlx.log"
PORT_FILE="${RUN_DIR}/omlx.port"

OMLX_BIN="${OMLX_BIN:-}"
if [[ -z "${OMLX_BIN}" ]]; then
  if have omlx; then
    OMLX_BIN="$(command -v omlx)"
  elif [[ -x "/opt/homebrew/opt/omlx/bin/omlx" ]]; then
    OMLX_BIN="/opt/homebrew/opt/omlx/bin/omlx"
  fi
fi

if [[ -z "${OMLX_BIN}" || ! -x "${OMLX_BIN}" ]]; then
  die "omlx not found. Install with brew tap jundot/omlx https://github.com/jundot/omlx && brew install omlx"
fi

if [[ -z "${MODEL_PATH}" ]]; then
  MODEL_PATH="$(python3 "${SCRIPT_DIR}/benchmark_model_paths.py" resolve mlx-qwen3.5-9b-4bit 2>/dev/null || true)"
fi
if [[ -z "${MODEL_PATH}" || ! -d "${MODEL_PATH}" ]]; then
  die "missing MLX model path. Set OMLX_MODEL_PATH or BENCHMARK_MLX_MODEL."
fi

mkdir -p "${RUN_DIR}" "${MODEL_DIR}" "${CACHE_DIR}"
ln -sfn "${MODEL_PATH}" "${MODEL_DIR}/${MODEL_ID}"

CMD=(
  "${OMLX_BIN}"
  serve
  --host "${HOST}"
  --port "${PORT}"
  --log-level "${LOG_LEVEL}"
  --model-dir "${MODEL_DIR}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --completion-batch-size "${COMPLETION_BATCH_SIZE}"
  --paged-ssd-cache-dir "${CACHE_DIR}"
  --paged-ssd-cache-max-size "${CACHE_MAX_SIZE}"
)

if [[ -n "${MAX_MODEL_MEMORY}" ]]; then
  CMD+=(--max-model-memory "${MAX_MODEL_MEMORY}")
fi
if [[ -n "${MAX_PROCESS_MEMORY}" ]]; then
  CMD+=(--max-process-memory "${MAX_PROCESS_MEMORY}")
fi
if [[ -n "${HOT_CACHE_MAX_SIZE}" ]]; then
  CMD+=(--hot-cache-max-size "${HOT_CACHE_MAX_SIZE}")
fi
if [[ -n "${INITIAL_CACHE_BLOCKS}" ]]; then
  CMD+=(--initial-cache-blocks "${INITIAL_CACHE_BLOCKS}")
fi
if [[ "${DISABLE_CACHE}" == "true" ]]; then
  CMD+=(--no-cache)
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'dry-run:'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

OMLX_DEFAULT_MODEL_ID="${MODEL_ID}" OMLX_MODEL_TYPE_OVERRIDE="${MODEL_TYPE_OVERRIDE}" python3 - <<'PY'
import json
import os
from pathlib import Path

base = Path.home() / ".omlx"
base.mkdir(parents=True, exist_ok=True)
settings_file = base / "model_settings.json"
target = os.environ["OMLX_DEFAULT_MODEL_ID"]

data = {"version": 1, "models": {}}
if settings_file.exists():
    try:
        data = json.loads(settings_file.read_text())
    except Exception:
        data = {"version": 1, "models": {}}

models = data.setdefault("models", {})
for model_id, cfg in models.items():
    if isinstance(cfg, dict):
        cfg["is_default"] = model_id == target

cfg = models.setdefault(target, {})
if not isinstance(cfg, dict):
    cfg = {}
models[target] = cfg
cfg["is_default"] = True
override = os.environ.get("OMLX_MODEL_TYPE_OVERRIDE", "").strip()
if override:
    cfg["model_type_override"] = override
elif "model_type_override" in cfg:
    del cfg["model_type_override"]

settings_file.write_text(json.dumps(data, indent=2))
PY

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "oMLX already running (pid ${pid})"
    echo "- url: http://${HOST}:${PORT}/v1"
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  die "port ${PORT} already in use"
fi

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
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

for (( i = 1; i <= START_TIMEOUT; i++ )); do
  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    echo "oMLX failed to start. Check log: ${LOG_FILE}"
    tail -40 "${LOG_FILE}" || true
    exit 1
  fi
  if curl -fsS "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ "${SMOKE_TEST}" == "true" ]]; then
  payload="$(
    python3 - "${MODEL_ID}" "${SMOKE_TEST_PROMPT}" <<'PY'
import json
import sys

print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 16,
    "temperature": 0.0,
    "chat_template_kwargs": {"enable_thinking": False},
}))
PY
  )"
  response="$(
    curl -sS \
      -H 'Content-Type: application/json' \
      "http://${HOST}:${PORT}/v1/chat/completions" \
      -d "${payload}"
  )"
  if [[ "${response}" != *"READY"* ]]; then
    echo "Smoke test failed"
    printf '%s\n' "${response}"
    exit 1
  fi
fi

cat <<EOF
started oMLX (pid ${pid})
- model path: ${MODEL_PATH}
- model id: ${MODEL_ID}
- url: http://${HOST}:${PORT}/v1
- cache dir: ${CACHE_DIR}
- log: ${LOG_FILE}
EOF
