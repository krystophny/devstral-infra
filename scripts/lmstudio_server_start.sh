#!/usr/bin/env bash
# Start LM Studio API server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
LMSTUDIO_HOST="${LMSTUDIO_HOST:-127.0.0.1}"

# Check if lms is available
if ! command -v lms &>/dev/null; then
    echo "Error: lms CLI not found. Run scripts/lmstudio_install.sh first."
    exit 1
fi

# Check if server is already running
if curl -s "http://${LMSTUDIO_HOST}:${LMSTUDIO_PORT}/v1/models" &>/dev/null; then
    echo "LM Studio server already running on port ${LMSTUDIO_PORT}"
    exit 0
fi

echo "Starting LM Studio API server on ${LMSTUDIO_HOST}:${LMSTUDIO_PORT}..."

# Start server in background
lms server start --port "${LMSTUDIO_PORT}" &

# Wait for server to be ready
echo "Waiting for server to be ready..."
for i in {1..30}; do
    if curl -s "http://${LMSTUDIO_HOST}:${LMSTUDIO_PORT}/v1/models" &>/dev/null; then
        echo ""
        echo "LM Studio server is ready!"
        echo "API endpoint: http://${LMSTUDIO_HOST}:${LMSTUDIO_PORT}/v1"
        echo ""
        echo "To load a model: lms load <model-path>"
        echo "To list models: lms ls"
        echo "To stop: scripts/lmstudio_server_stop.sh"
        exit 0
    fi
    sleep 1
    echo -n "."
done

echo ""
echo "Warning: Server may still be starting. Check with: curl http://${LMSTUDIO_HOST}:${LMSTUDIO_PORT}/v1/models"
