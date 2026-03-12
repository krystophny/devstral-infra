#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_OUTPUT="${REPO_ROOT}/../llama.cpp-dev/issues/20428/benchmarks/qwen35-family-$(date +%Y%m%d-%H%M%S)"

OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT}}"

python3 "${SCRIPT_DIR}/benchmark_qwen35_family.py" \
  --output-dir "${OUTPUT_DIR}" \
  "$@"

printf 'benchmark reports written to %s\n' "${OUTPUT_DIR}"
