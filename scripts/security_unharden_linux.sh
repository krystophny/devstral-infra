#!/usr/bin/env bash
# Remove network hardening for opencode and qwen-code on Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

RULES_DIR="/etc/opensnitchd/rules"
HOSTS_MARKER="# devstral-infra security hardening"

echo "Removing security hardening for opencode + qwen-code..."
echo ""

# --- Remove OpenSnitch rules -------------------------------------------------

removed=0
for rule in devstral-allow-opencode-localhost devstral-deny-opencode-internet \
            devstral-allow-qwen-localhost devstral-deny-qwen-internet; do
    path="${RULES_DIR}/${rule}.json"
    if [[ -f "${path}" ]]; then
        sudo rm -f "${path}"
        echo "  removed: ${path}"
        removed=$((removed + 1))
    fi
done

if [[ "${removed}" -gt 0 ]] && systemctl is-active --quiet opensnitchd 2>/dev/null; then
    sudo systemctl reload opensnitchd 2>/dev/null || sudo systemctl restart opensnitchd
    echo "  reloaded opensnitchd"
fi

# --- Remove DNS blocks -------------------------------------------------------

if grep -q "${HOSTS_MARKER}" /etc/hosts 2>/dev/null; then
    sudo sed -i "/${HOSTS_MARKER}/,/${HOSTS_MARKER} end/d" /etc/hosts
    echo "  removed DNS blocks from /etc/hosts"
fi

echo ""
echo "Done. Network hardening removed."
