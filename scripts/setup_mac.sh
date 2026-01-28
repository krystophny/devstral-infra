#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "setup_mac.sh must run on macOS"

ensure_python_venv
activate_venv

python -m pip install -U pip >/dev/null

echo "installing vllm-metal..."
curl -sSL https://raw.githubusercontent.com/vllm-project/vllm-metal/main/install.sh | bash

mkdir -p "${HF_HOME_DIR}"

cat <<EOF
OK (macOS + vllm-metal)
- venv: ${VENV_DIR}
- HF cache: ${HF_HOME_DIR}
- GPU: Metal (Apple Silicon)

Next:
- Start server: scripts/server_start.sh
EOF
