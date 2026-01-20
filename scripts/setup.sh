#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

ensure_python_venv
activate_venv

python -m pip install -U pip >/dev/null
python -m pip install -r "${REPO_ROOT}/requirements.txt"

mkdir -p "${HF_HOME_DIR}"

cat <<EOF
OK
- venv: ${VENV_DIR}
- HF cache: ${HF_HOME_DIR}

Next:
- Start server: scripts/server_start.sh
EOF
