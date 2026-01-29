#!/usr/bin/env bash
# Download recommended models for LM Studio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

# Check if lms is available
if ! command -v lms &>/dev/null; then
    echo "Error: lms CLI not found. Run scripts/lmstudio_install.sh first."
    exit 1
fi

# Models to download with recommended quantizations
# Format: repo@quantization or just repo for default
declare -A MODELS=(
    ["glm-4.7-flash"]="THUDM/glm-4-9b-chat-hf-GGUF@Q4_K_M"
    ["devstral-small-2"]="mistralai/Devstral-Small-2-24B-Instruct-GGUF@Q4_K_M"
    ["gpt-oss-20b"]="ggml-org/gpt-oss-20b-GGUF@Q4_K_M"
    ["gpt-oss-120b"]="ggml-org/gpt-oss-120b-GGUF@Q4_K_M"
    ["qwen3-30b-coder"]="Qwen/Qwen3-Coder-30B-Instruct-GGUF@Q4_K_M"
)

echo "LM Studio Model Downloader"
echo "=========================="
echo ""
echo "Available models:"
for name in "${!MODELS[@]}"; do
    echo "  - ${name}: ${MODELS[$name]}"
done
echo ""

# Parse arguments
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <model-name|all>"
    echo ""
    echo "Examples:"
    echo "  $0 glm-4.7-flash      # Download GLM-4.7-Flash (MLA support!)"
    echo "  $0 devstral-small-2   # Download Devstral Small 2"
    echo "  $0 gpt-oss-20b        # Download GPT-OSS 20B"
    echo "  $0 gpt-oss-120b       # Download GPT-OSS 120B (~70GB)"
    echo "  $0 qwen3-30b-coder    # Download Qwen3 Coder 30B"
    echo "  $0 all                # Download all models"
    exit 0
fi

download_model() {
    local name="$1"
    local spec="${MODELS[$name]}"
    
    if [[ -z "${spec}" ]]; then
        echo "Error: Unknown model '${name}'"
        echo "Available: ${!MODELS[*]}"
        return 1
    fi
    
    echo ""
    echo "Downloading ${name} (${spec})..."
    echo "This may take a while depending on model size..."
    echo ""
    
    # lms get handles the download
    lms get "${spec}" --yes
    
    echo ""
    echo "Downloaded: ${name}"
}

if [[ "$1" == "all" ]]; then
    echo "Downloading ALL models. This will use significant disk space!"
    echo ""
    for name in "${!MODELS[@]}"; do
        download_model "${name}" || true
    done
    echo ""
    echo "All downloads complete!"
else
    for model in "$@"; do
        download_model "${model}"
    done
fi

echo ""
echo "Models are stored in: ~/.lmstudio/models/"
echo ""
echo "To list downloaded models: lms ls"
echo "To load a model: lms load <model-path>"
echo "To start server: lms server start"
