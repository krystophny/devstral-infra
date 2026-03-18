#!/usr/bin/env bash
# Block internet access for opencode and qwen-code on Linux.
# Uses OpenSnitch (per-executable firewall) + /etc/hosts DNS blocking.
#
# Child processes (git, curl, make, etc.) spawned by these tools retain
# full network access because OpenSnitch matches on executable path,
# not on the process tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

RULES_DIR="/etc/opensnitchd/rules"
HOSTS_MARKER="# devstral-infra security hardening"

# --- Install OpenSnitch if missing -------------------------------------------

install_opensnitch() {
    if have opensnitchd; then
        echo "OpenSnitch already installed"
        return 0
    fi

    echo "Installing OpenSnitch..."
    if have pacman; then
        sudo pacman -S --needed --noconfirm opensnitch
    elif have apt-get; then
        sudo apt-get install -y opensnitch
    elif have dnf; then
        sudo dnf install -y opensnitch
    else
        die "Cannot auto-install OpenSnitch. Install it manually."
    fi
}

# --- OpenSnitch rules --------------------------------------------------------

write_rule() {
    local name="$1"
    local json="$2"
    local path="${RULES_DIR}/${name}.json"

    sudo mkdir -p "${RULES_DIR}"
    echo "${json}" | sudo tee "${path}" > /dev/null
    echo "  rule: ${path}"
}

allow_localhost_rule() {
    local name="$1"
    local operand="$2"
    local data="$3"

    cat <<EOF
{
  "name": "${name}",
  "enabled": true,
  "precedence": true,
  "action": "allow",
  "duration": "always",
  "operator": {
    "type": "list",
    "operand": "list",
    "list": [
      {"type": "simple", "operand": "${operand}", "data": "${data}"},
      {"type": "network", "operand": "dest.ip", "data": "127.0.0.0/8"}
    ]
  }
}
EOF
}

deny_internet_rule() {
    local name="$1"
    local operand="$2"
    local data="$3"

    cat <<EOF
{
  "name": "${name}",
  "enabled": true,
  "precedence": false,
  "action": "deny",
  "duration": "always",
  "operator": {
    "type": "simple",
    "operand": "${operand}",
    "data": "${data}"
  }
}
EOF
}

setup_opensnitch_rules() {
    echo "Configuring OpenSnitch rules..."

    # opencode: Go binary, match by path
    OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
    if [[ -n "${OPENCODE_BIN}" ]]; then
        OPENCODE_BIN="$(readlink -f "${OPENCODE_BIN}")"
        write_rule "devstral-allow-opencode-localhost" \
            "$(allow_localhost_rule "devstral-allow-opencode-localhost" "process.path" "${OPENCODE_BIN}")"
        write_rule "devstral-deny-opencode-internet" \
            "$(deny_internet_rule "devstral-deny-opencode-internet" "process.path" "${OPENCODE_BIN}")"
        echo "  opencode blocked: ${OPENCODE_BIN}"
    else
        warn "opencode binary not found, skipping OpenSnitch rule"
    fi

    # qwen-code: Node.js script, match by command line
    QWEN_BIN="$(command -v qwen 2>/dev/null || command -v qwen-code 2>/dev/null || true)"
    if [[ -n "${QWEN_BIN}" ]]; then
        # qwen runs as /usr/bin/node /usr/bin/qwen, so we match the node
        # process whose command contains the qwen entrypoint path
        QWEN_BIN="$(readlink -f "${QWEN_BIN}")"
        local qwen_deny
        qwen_deny="$(cat <<EOF
{
  "name": "devstral-deny-qwen-internet",
  "enabled": true,
  "precedence": false,
  "action": "deny",
  "duration": "always",
  "operator": {
    "type": "list",
    "operand": "list",
    "list": [
      {"type": "simple", "operand": "process.path", "data": "$(command -v node)"},
      {"type": "regexp", "operand": "process.command", "data": ".*${QWEN_BIN}.*"}
    ]
  }
}
EOF
)"
        local qwen_allow
        qwen_allow="$(cat <<EOF
{
  "name": "devstral-allow-qwen-localhost",
  "enabled": true,
  "precedence": true,
  "action": "allow",
  "duration": "always",
  "operator": {
    "type": "list",
    "operand": "list",
    "list": [
      {"type": "simple", "operand": "process.path", "data": "$(command -v node)"},
      {"type": "regexp", "operand": "process.command", "data": ".*${QWEN_BIN}.*"},
      {"type": "network", "operand": "dest.ip", "data": "127.0.0.0/8"}
    ]
  }
}
EOF
)"
        write_rule "devstral-allow-qwen-localhost" "${qwen_allow}"
        write_rule "devstral-deny-qwen-internet" "${qwen_deny}"
        echo "  qwen-code blocked: node ${QWEN_BIN}"
    else
        warn "qwen/qwen-code binary not found, skipping OpenSnitch rule"
    fi
}

# --- DNS blocking (defense in depth) ----------------------------------------

BLOCKED_DOMAINS=(
    # qwen-code telemetry and cloud API
    play.googleapis.com
    dashscope.aliyuncs.com
    coding.dashscope.aliyuncs.com
    qwen.ai
    # opencode phone-home
    models.dev
    opencode.ai
)

add_hosts_entries() {
    if grep -q "${HOSTS_MARKER}" /etc/hosts 2>/dev/null; then
        echo "DNS blocking already in /etc/hosts (skipping)"
        return 0
    fi

    echo "Adding DNS blocks to /etc/hosts..."
    {
        echo ""
        echo "${HOSTS_MARKER}"
        for domain in "${BLOCKED_DOMAINS[@]}"; do
            echo "127.0.0.1 ${domain}"
        done
        echo "${HOSTS_MARKER} end"
    } | sudo tee -a /etc/hosts > /dev/null

    for domain in "${BLOCKED_DOMAINS[@]}"; do
        echo "  blocked: ${domain}"
    done
}

# --- Main --------------------------------------------------------------------

echo "Security hardening for opencode + qwen-code (Linux)"
echo ""

install_opensnitch

# Enable and start opensnitchd
if ! systemctl is-active --quiet opensnitchd; then
    sudo systemctl enable --now opensnitchd
    echo "Started opensnitchd"
fi

setup_opensnitch_rules

# Reload OpenSnitch to pick up new rules
sudo systemctl reload opensnitchd 2>/dev/null || sudo systemctl restart opensnitchd
echo ""

add_hosts_entries

echo ""
echo "Done. Network hardening active:"
echo "  - OpenSnitch blocks opencode/qwen-code internet access"
echo "  - Localhost (127.0.0.0/8) connections allowed for local LLM"
echo "  - Shell commands spawned by these tools retain full network access"
echo "  - DNS blocking for known phone-home domains"
echo ""
echo "To reverse: scripts/security_unharden_linux.sh"
