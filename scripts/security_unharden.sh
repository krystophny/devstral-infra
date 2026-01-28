#!/usr/bin/env bash
# Remove network blocking for Vibe, OpenCode, and Ollama
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Removing security hardening (requires sudo)..."
echo ""

find_binary() {
    local name="$1"
    shift
    local paths=("$@")

    for p in "${paths[@]}"; do
        if [[ -x "${p}" ]]; then
            echo "${p}"
            return 0
        fi
    done

    local cmd_path
    cmd_path="$(command -v "${name}" 2>/dev/null || true)"
    if [[ -x "${cmd_path}" ]]; then
        echo "${cmd_path}"
        return 0
    fi

    return 1
}

case "${platform}" in
  mac)
    unblocked=0

    # Unblock Vibe
    VIBE_BIN="$(find_binary vibe \
        /Applications/Vibe.app/Contents/MacOS/Vibe \
        "${HOME}/.vibe/bin/vibe" \
        "${HOME}/.local/bin/vibe" || true)"

    if [[ -n "${VIBE_BIN}" ]]; then
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "${VIBE_BIN}" 2>/dev/null || true
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "${VIBE_BIN}" 2>/dev/null || true
        echo "  unblocked: ${VIBE_BIN}"
        unblocked=$((unblocked + 1))
    fi

    # Unblock OpenCode
    OPENCODE_BIN="$(find_binary opencode \
        /Applications/OpenCode.app/Contents/MacOS/OpenCode \
        "${HOME}/.opencode/bin/opencode" \
        "${HOME}/.local/bin/opencode" \
        /opt/homebrew/bin/opencode \
        /usr/local/bin/opencode || true)"

    if [[ -n "${OPENCODE_BIN}" ]]; then
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "${OPENCODE_BIN}" 2>/dev/null || true
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "${OPENCODE_BIN}" 2>/dev/null || true
        echo "  unblocked: ${OPENCODE_BIN}"
        unblocked=$((unblocked + 1))
    fi

    # Unblock Ollama
    OLLAMA_BIN="$(find_binary ollama \
        /Applications/Ollama.app/Contents/MacOS/Ollama \
        /opt/homebrew/bin/ollama \
        /usr/local/bin/ollama || true)"

    if [[ -n "${OLLAMA_BIN}" ]]; then
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "${OLLAMA_BIN}" 2>/dev/null || true
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "${OLLAMA_BIN}" 2>/dev/null || true
        echo "  unblocked: ${OLLAMA_BIN}"
        unblocked=$((unblocked + 1))
    fi

    if [[ "${unblocked}" -eq 0 ]]; then
        echo "No blocked applications found"
    else
        echo ""
        echo "OK - ${unblocked} application(s) unblocked"
    fi
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

    # Remove wrapper scripts
    rm -f "${HOME}/.local/bin/vibe-isolated"
    rm -f "${HOME}/.local/bin/opencode-isolated"
    rm -f "${HOME}/.local/bin/ollama-isolated"

    echo "OK - Network isolation removed"
    echo ""
    echo "Note: The devstral-isolated group was not removed."
    echo "To remove it: sudo groupdel devstral-isolated"
    ;;
esac
