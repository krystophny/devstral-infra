#!/usr/bin/env bash
# Stop the Mac dual-instance deployment started by server_start_mac.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

[[ "$(detect_platform)" == "mac" ]] || die "server_stop_mac.sh is macOS only"

for instance in 35b-a3b 27b; do
  LLAMACPP_INSTANCE="${instance}" bash "${SCRIPT_DIR}/server_stop_llamacpp.sh"
done
