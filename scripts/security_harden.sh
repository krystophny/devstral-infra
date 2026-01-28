#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

echo "Security hardening for Vibe (requires sudo)..."
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
      die "Vibe binary not found. Install Vibe first: scripts/vibe_install.sh"
    fi

    echo "Blocking Vibe network access via macOS firewall..."
    echo "(This requires sudo access)"
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "${VIBE_BIN}"
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp "${VIBE_BIN}"

    echo ""
    echo "OK - Vibe network access blocked"
    echo "Vibe can now only connect to localhost (local server)."
    echo ""
    echo "To verify:"
    echo "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps | grep -i vibe"
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

    WRAPPER_PATH="${HOME}/.local/bin/vibe-isolated"
    mkdir -p "$(dirname "${WRAPPER_PATH}")"
    cat > "${WRAPPER_PATH}" <<'WRAPPER'
#!/usr/bin/env bash
exec sg devstral-isolated -c "vibe $*"
WRAPPER
    chmod +x "${WRAPPER_PATH}"

    echo ""
    echo "OK - Network isolation configured"
    echo ""
    echo "To run Vibe in isolated mode:"
    echo "  ${WRAPPER_PATH}"
    echo ""
    echo "Or add yourself to the group and run vibe directly:"
    echo "  sudo usermod -aG ${GROUP_NAME} \$USER"
    echo "  newgrp ${GROUP_NAME}"
    echo "  vibe"
    echo ""
    echo "To reverse:"
    echo "  scripts/security_unharden.sh"
    ;;
esac
