#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_OUTPUT="/tmp/devstral-infra-benchmarks/local-stacks-$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT}}"

PYTHON_BIN="${BENCHMARK_PYTHON:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
  if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
    PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
  else
    PYTHON_BIN="python3"
  fi
fi

"${PYTHON_BIN}" "${SCRIPT_DIR}/benchmark_local_stacks.py" \
  --output-dir "${OUTPUT_DIR}" \
  "$@"

printf 'benchmark reports written to %s\n' "${OUTPUT_DIR}"
