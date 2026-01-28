#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"
[[ "${platform}" == "linux" || "${platform}" == "wsl" ]] \
  || die "setup_linux.sh must run on Linux or WSL"

gpu="$(detect_gpu)"

# Check Python version for vLLM compatibility (requires Python 3.10-3.13)
PYTHON_VERSION="$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")"
PYTHON_MAJOR="${PYTHON_VERSION%%.*}"
PYTHON_MINOR="${PYTHON_VERSION#*.}"

try_vllm() {
    ensure_python_venv
    activate_venv
    python -m pip install -U pip >/dev/null

    case "${gpu}" in
      cuda)
        echo "installing vllm (NVIDIA CUDA)..."
        python -m pip install "vllm>=0.8.0"
        ;;
      cpu)
        echo "installing vllm (CPU-only)..."
        python -m pip install "vllm>=0.8.0" \
          --extra-index-url https://download.pytorch.org/whl/cpu
        ;;
    esac
}

install_ollama() {
    echo "installing Ollama..."
    if have ollama; then
        echo "Ollama already installed"
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    # Verify Ollama version
    OLLAMA_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")"
    echo "Ollama version: ${OLLAMA_VERSION}"

    # Start Ollama if not running
    if ! pgrep -x "ollama" >/dev/null 2>&1; then
        echo "starting Ollama server..."
        ollama serve >/dev/null 2>&1 &
        sleep 3
    fi

    # Pull the model
    MODEL="${DEVSTRAL_OLLAMA_MODEL:-devstral-small-2}"
    echo "pulling model ${MODEL} (this may take a while, ~15GB)..."
    ollama pull "${MODEL}"
}

# Prefer vLLM on compatible Python, fall back to Ollama
BACKEND=""
if [[ "${PYTHON_MAJOR}" -eq 3 && "${PYTHON_MINOR}" -ge 10 && "${PYTHON_MINOR}" -le 13 ]]; then
    echo "Python ${PYTHON_VERSION} compatible with vLLM, attempting install..."
    if try_vllm; then
        BACKEND="vllm"
        mkdir -p "${HF_HOME_DIR}"
    else
        echo "vLLM install failed, falling back to Ollama..."
        install_ollama
        BACKEND="ollama"
    fi
else
    echo "Python ${PYTHON_VERSION} incompatible with vLLM (requires 3.10-3.13), using Ollama..."
    install_ollama
    BACKEND="ollama"
fi

mkdir -p "${RUN_DIR}"

if [[ "${BACKEND}" == "vllm" ]]; then
    cat <<EOF
OK (Linux + vLLM, backend: ${gpu})
- venv: ${VENV_DIR}
- HF cache: ${HF_HOME_DIR}

Next:
- Start server: scripts/server_start.sh
EOF
else
    cat <<EOF
OK (Linux + Ollama, backend: ${gpu})
- Model: ${DEVSTRAL_OLLAMA_MODEL:-devstral-small-2}

Next:
- Start server: scripts/server_start.sh
- Configure Vibe: scripts/vibe_set_local.sh
EOF
fi
