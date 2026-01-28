#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Removing security hardening (requires sudo)..."
echo ""

case "${platform}" in
  mac)
    VIBE_BIN=""
    for p in /Applications/Vibe.app/Contents/MacOS/Vibe \
             "${HOME}/.vibe/bin/vibe" \
             "$(command -v vibe 2>/dev/null || true)"; do
      if [[ -x "${p}" ]]; then
        VIBE_BIN="${p}"
        break
      fi
    done

    if [[ -z "${VIBE_BIN}" ]]; then
      echo "Vibe binary not found; nothing to unharden."
      exit 0
    fi

    echo "Unblocking Vibe network access..."
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "${VIBE_BIN}" 2>/dev/null || true
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "${VIBE_BIN}" 2>/dev/null || true

    echo "OK - Vibe network access restored"
    ;;

  linux|wsl)
    if ! have iptables; then
      echo "iptables not found; nothing to unharden."
      exit 0
    fi

    MARKER="devstral-infra"

    echo "Removing iptables rules..."
    while true; do
      LINE_NUM="$(sudo iptables -L OUTPUT -n --line-numbers 2>/dev/null \
        | grep "${MARKER}" | head -1 | awk '{print $1}')"
      if [[ -z "${LINE_NUM}" ]]; then
        break
      fi
      sudo iptables -D OUTPUT "${LINE_NUM}"
    done

    WRAPPER_PATH="${HOME}/.local/bin/vibe-isolated"
    rm -f "${WRAPPER_PATH}"

    echo "OK - Network isolation removed"
    echo ""
    echo "Note: The devstral-isolated group was not removed."
    echo "To remove it: sudo groupdel devstral-isolated"
    ;;
esac
