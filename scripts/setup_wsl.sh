#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "wsl" ]] || die "setup_wsl.sh must run inside WSL"

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  die "not running inside WSL"
fi

echo "WSL detected, installing system dependencies..."
if have apt-get; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq python3-venv python3-pip curl >/dev/null
fi

exec "${SCRIPT_DIR}/setup_linux.sh"
