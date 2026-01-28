#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

case "${platform}" in
  mac)  exec "${SCRIPT_DIR}/setup_mac.sh" ;;
  wsl)  exec "${SCRIPT_DIR}/setup_wsl.sh" ;;
  linux) exec "${SCRIPT_DIR}/setup_linux.sh" ;;
esac
