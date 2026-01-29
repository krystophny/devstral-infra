#!/usr/bin/env bash
# Stop LM Studio API server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

echo "Stopping LM Studio server..."

# Try graceful stop first
if command -v lms &>/dev/null; then
    lms server stop 2>/dev/null || true
fi

# Kill any remaining processes
pkill -f "lm-studio" 2>/dev/null || true
pkill -f "LM-Studio" 2>/dev/null || true
pkill -f "lms server" 2>/dev/null || true

echo "LM Studio server stopped."
