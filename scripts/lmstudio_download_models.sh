#!/usr/bin/env bash
# Download recommended models for LM Studio via HuggingFace
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

MODELS_DIR="${HOME}/.lmstudio/models"
mkdir -p "${MODELS_DIR}"

# Models with direct HuggingFace download URLs
# Format: name|org/repo|filename|size_description
MODELS=(
    "glm-4.7-flash|unsloth/GLM-4.7-Flash-GGUF|GLM-4.7-Flash-Q4_K_M.gguf|18GB MoE with MLA"
    "devstral-small-2|unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF|Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf|15GB dense"
    "gpt-oss-20b|ggml-org/gpt-oss-20b-GGUF|gpt-oss-20b-Q4_K_M.gguf|12GB MoE"
    "gpt-oss-120b|ggml-org/gpt-oss-120b-GGUF|gpt-oss-120b-Q4_K_M.gguf|70GB MoE"
    "qwen3-30b-coder|unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF|Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf|18GB"
)

echo "LM Studio Model Downloader (Direct HuggingFace)"
echo "================================================"
echo ""
echo "Available models:"
for model_spec in "${MODELS[@]}"; do
    IFS='|' read -r name repo filename size <<< "${model_spec}"
    echo "  - ${name}: ${size}"
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
    local target_name="$1"
    local found=0

    for model_spec in "${MODELS[@]}"; do
        IFS='|' read -r name repo filename size <<< "${model_spec}"

        if [[ "${name}" == "${target_name}" ]]; then
            found=1
            local model_dir="${MODELS_DIR}/${repo}"
            local model_path="${model_dir}/${filename}"
            local url="https://huggingface.co/${repo}/resolve/main/${filename}"

            if [[ -f "${model_path}" ]]; then
                echo "Model already exists: ${model_path}"
                return 0
            fi

            echo ""
            echo "Downloading ${name} (${size})..."
            echo "From: ${url}"
            echo "To: ${model_path}"
            echo ""

            mkdir -p "${model_dir}"

            # Download with progress
            if curl -L -# -o "${model_path}" "${url}"; then
                echo ""
                echo "Downloaded: ${name}"
                echo "Path: ${model_path}"
            else
                echo "Error: Failed to download ${name}"
                rm -f "${model_path}"
                return 1
            fi

            return 0
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        echo "Error: Unknown model '${target_name}'"
        echo "Available models:"
        for model_spec in "${MODELS[@]}"; do
            IFS='|' read -r name repo filename size <<< "${model_spec}"
            echo "  - ${name}"
        done
        return 1
    fi
}

if [[ "$1" == "all" ]]; then
    echo "Downloading ALL models. This will use significant disk space!"
    echo ""
    for model_spec in "${MODELS[@]}"; do
        IFS='|' read -r name repo filename size <<< "${model_spec}"
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
echo "Models are stored in: ${MODELS_DIR}"
echo ""
echo "To use with LM Studio:"
echo "  1. Start LM Studio: lm-studio (or with Xvfb for headless)"
echo "  2. Start server: lms server start"
echo "  3. Load model: lms load <model-path>"
