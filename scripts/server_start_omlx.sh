#!/usr/bin/env bash
# Start oMLX server with SSD KV cache + continuous batching for Apple Silicon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8000}"

MODEL_DIR="${OMLX_MODEL_DIR:-${HOME}/.omlx/models-fast}"
CACHE_DIR="${OMLX_CACHE_DIR:-${HOME}/.omlx/cache}"
CACHE_MAX_SIZE="${OMLX_CACHE_MAX_SIZE:-120GB}"
MAX_NUM_SEQS="${OMLX_MAX_NUM_SEQS:-8}"
PREFILL_BATCH_SIZE="${OMLX_PREFILL_BATCH_SIZE:-8}"
COMPLETION_BATCH_SIZE="${OMLX_COMPLETION_BATCH_SIZE:-32}"
DEFAULT_MODEL_ID="${OMLX_DEFAULT_MODEL_ID:-Devstral-2-123B-Instruct-2512-4bit}"

PID_FILE="${RUN_DIR}/omlx.pid"
LOG_FILE="${RUN_DIR}/omlx.log"
PORT_FILE="${RUN_DIR}/omlx.port"

if ! have omlx; then
  die "omlx not found. Install with: uv tool install --from git+https://github.com/jundot/omlx.git omlx"
fi

mkdir -p "${RUN_DIR}" "${MODEL_DIR}" "${CACHE_DIR}"

# Seed model directory from existing local MLX models.
for src in \
  "${HOME}/.lmstudio/models/mlx-community/Devstral-2-123B-Instruct-2512-4bit" \
  "${HOME}/.lmstudio/models/lmstudio-community/Devstral-Small-2507-MLX-8bit" \
  "${HOME}/.lmstudio/models/lmstudio-community/gpt-oss-20b-mlx-8bit"; do
  if [[ -d "${src}" ]]; then
    ln -sfn "${src}" "${MODEL_DIR}/$(basename "${src}")"
  fi
done

# Persist default model selection for oMLX.
if [[ -n "${DEFAULT_MODEL_ID}" ]]; then
  OMLX_DEFAULT_MODEL_ID="${DEFAULT_MODEL_ID}" python - <<'PY'
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
        cfg["is_default"] = (model_id == target)

target_cfg = models.setdefault(target, {})
if not isinstance(target_cfg, dict):
    target_cfg = {}
models[target] = target_cfg
target_cfg["is_default"] = True

settings_file.write_text(json.dumps(data, indent=2))
PY
fi

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

nohup omlx serve \
  --host "${HOST}" \
  --port "${PORT}" \
  --model-dir "${MODEL_DIR}" \
  --max-num-seqs "${MAX_NUM_SEQS}" \
  --prefill-batch-size "${PREFILL_BATCH_SIZE}" \
  --completion-batch-size "${COMPLETION_BATCH_SIZE}" \
  --paged-ssd-cache-dir "${CACHE_DIR}" \
  --paged-ssd-cache-max-size "${CACHE_MAX_SIZE}" \
  >"${LOG_FILE}" 2>&1 &

pid="$!"
echo "${pid}" > "${PID_FILE}"
echo "${PORT}" > "${PORT_FILE}"

ready=0
for _ in {1..60}; do
  if curl -s "http://${HOST}:${PORT}/v1/models" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    echo "oMLX failed to start. Log: ${LOG_FILE}"
    tail -40 "${LOG_FILE}" || true
    exit 1
  fi
  sleep 1
done

if [[ "${ready}" == "1" ]]; then
  cat <<EOF
started oMLX (pid ${pid})
- url: http://${HOST}:${PORT}/v1
- model_dir: ${MODEL_DIR}
- cache_dir: ${CACHE_DIR}
- default_model: ${DEFAULT_MODEL_ID}
- max_num_seqs: ${MAX_NUM_SEQS}
- prefill_batch_size: ${PREFILL_BATCH_SIZE}
- completion_batch_size: ${COMPLETION_BATCH_SIZE}
- log: ${LOG_FILE}
EOF
else
  echo "oMLX started but is not ready yet. Check: ${LOG_FILE}"
fi
