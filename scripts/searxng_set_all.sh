#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/codex_set_searxng.sh"
"${SCRIPT_DIR}/claude_set_searxng.sh"
"${SCRIPT_DIR}/opencode_set_searxng.sh"
