#!/usr/bin/env bash
# Install LM Studio CLI
# Reference: https://lmstudio.ai/docs/cli
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"

if [[ "${platform}" != "mac" ]]; then
    echo "Error: LM Studio is only supported on macOS for now"
    exit 1
fi

# Check if LM Studio app is installed
if [[ ! -d "/Applications/LM Studio.app" ]]; then
    echo "LM Studio app not found. Installing via brew..."
    if command -v brew &>/dev/null; then
        brew install --cask lm-studio
    else
        echo "Error: brew not found. Install LM Studio manually from https://lmstudio.ai"
        exit 1
    fi
fi

# Install CLI to PATH
if ! command -v lms &>/dev/null; then
    echo "Installing lms CLI to PATH..."
    npx lmstudio install-cli
fi

echo "LM Studio installed:"
lms --version
