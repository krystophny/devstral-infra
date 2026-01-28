#!/usr/bin/env bash
# Block network access for Vibe, OpenCode, and optionally Ollama
# Only localhost connections will be allowed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Security hardening for AI coding tools (requires sudo)..."
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
    blocked=0

    # Block Vibe
    VIBE_BIN="$(find_binary vibe \
        /Applications/Vibe.app/Contents/MacOS/Vibe \
        "${HOME}/.vibe/bin/vibe" \
        "${HOME}/.local/bin/vibe" || true)"

    if [[ -n "${VIBE_BIN}" ]]; then
        echo "Blocking Vibe network access..."
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "${VIBE_BIN}" 2>/dev/null || true
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp "${VIBE_BIN}"
        echo "  blocked: ${VIBE_BIN}"
        blocked=$((blocked + 1))
    else
        echo "  Vibe not found (skipping)"
    fi

    # Block OpenCode
    OPENCODE_BIN="$(find_binary opencode \
        /Applications/OpenCode.app/Contents/MacOS/OpenCode \
        "${HOME}/.opencode/bin/opencode" \
        "${HOME}/.local/bin/opencode" \
        /opt/homebrew/bin/opencode \
        /usr/local/bin/opencode || true)"

    if [[ -n "${OPENCODE_BIN}" ]]; then
        echo "Blocking OpenCode network access..."
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "${OPENCODE_BIN}" 2>/dev/null || true
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp "${OPENCODE_BIN}"
        echo "  blocked: ${OPENCODE_BIN}"
        blocked=$((blocked + 1))
    else
        echo "  OpenCode not found (skipping)"
    fi

    # Block Ollama (optional - prevents model downloads and telemetry)
    OLLAMA_BIN="$(find_binary ollama \
        /Applications/Ollama.app/Contents/MacOS/Ollama \
        /opt/homebrew/bin/ollama \
        /usr/local/bin/ollama || true)"

    if [[ -n "${OLLAMA_BIN}" ]]; then
        echo "Blocking Ollama network access..."
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "${OLLAMA_BIN}" 2>/dev/null || true
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp "${OLLAMA_BIN}"
        echo "  blocked: ${OLLAMA_BIN}"
        blocked=$((blocked + 1))
        echo ""
        echo "WARNING: Ollama blocked - you cannot download new models!"
        echo "  Pull models BEFORE running this script:"
        echo "    ollama pull glm-4.7-flash"
        echo "    ollama pull devstral-small-2"
    else
        echo "  Ollama not found (skipping)"
    fi

    if [[ "${blocked}" -eq 0 ]]; then
        die "No binaries found to block. Install Vibe, OpenCode, or Ollama first."
    fi

    echo ""
    echo "OK - ${blocked} application(s) blocked"
    echo "Applications can now only connect to localhost (local server)."
    echo ""
    echo "To verify:"
    echo "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps"
    echo ""
    echo "To reverse:"
    echo "  scripts/security_unharden.sh"
    ;;

  linux|wsl)
    if ! have iptables; then
      die "iptables not found. Install it via your package manager."
    fi

    GROUP_NAME="devstral-isolated"
    MARKER="devstral-infra"

    echo "Creating isolated group and iptables rules..."

    if ! getent group "${GROUP_NAME}" >/dev/null; then
      sudo groupadd "${GROUP_NAME}"
      echo "Created group: ${GROUP_NAME}"
    fi

    sudo iptables -L OUTPUT -n --line-numbers 2>/dev/null | grep -q "${MARKER}" || {
      sudo iptables -A OUTPUT -m owner --gid-owner "${GROUP_NAME}" -o lo -j ACCEPT \
        -m comment --comment "${MARKER}"
      sudo iptables -A OUTPUT -m owner --gid-owner "${GROUP_NAME}" -j DROP \
        -m comment --comment "${MARKER}"
      echo "Added iptables OUTPUT rules for group ${GROUP_NAME}"
    }

    # Create wrappers for isolated execution
    mkdir -p "${HOME}/.local/bin"

    # Vibe wrapper
    cat > "${HOME}/.local/bin/vibe-isolated" <<'WRAPPER'
#!/usr/bin/env bash
exec sg devstral-isolated -c "vibe $*"
WRAPPER
    chmod +x "${HOME}/.local/bin/vibe-isolated"

    # OpenCode wrapper
    cat > "${HOME}/.local/bin/opencode-isolated" <<'WRAPPER'
#!/usr/bin/env bash
exec sg devstral-isolated -c "opencode $*"
WRAPPER
    chmod +x "${HOME}/.local/bin/opencode-isolated"

    # Ollama wrapper (note: blocks model downloads)
    cat > "${HOME}/.local/bin/ollama-isolated" <<'WRAPPER'
#!/usr/bin/env bash
exec sg devstral-isolated -c "ollama $*"
WRAPPER
    chmod +x "${HOME}/.local/bin/ollama-isolated"

    echo ""
    echo "OK - Network isolation configured"
    echo ""
    echo "To run tools in isolated mode:"
    echo "  ${HOME}/.local/bin/vibe-isolated"
    echo "  ${HOME}/.local/bin/opencode-isolated"
    echo "  ${HOME}/.local/bin/ollama-isolated  (warning: blocks model downloads)"
    echo ""
    echo "Or add yourself to the group and run directly:"
    echo "  sudo usermod -aG ${GROUP_NAME} \$USER"
    echo "  newgrp ${GROUP_NAME}"
    echo "  vibe"
    echo ""
    echo "To reverse:"
    echo "  scripts/security_unharden.sh"
    ;;
esac
