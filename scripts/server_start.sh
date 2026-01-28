#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

migrate_legacy_pid

HOST="${DEVSTRAL_HOST:-127.0.0.1}"
PORT="${DEVSTRAL_PORT:-8080}"

PID_FILE="$(server_pid_file)"
LOG_FILE="$(server_log_file)"
PORT_FILE="$(server_port_file)"

if [[ -f "${PID_FILE}" ]]; then
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" >/dev/null 2>&1; then
        echo "already running (pid ${pid})"
        exit 0
    fi
    rm -f "${PID_FILE}"
fi

mkdir -p "${RUN_DIR}"

platform="$(detect_platform)"

if [[ "${platform}" == "mac" ]]; then
    # macOS: Use Ollama (native Metal, tool calling works)
    OLLAMA_MODEL="${DEVSTRAL_OLLAMA_MODEL:-gpt-oss:20b-12k}"
    OLLAMA_PORT="${PORT}"

    # Check if Ollama is installed
    if ! have ollama; then
        die "Ollama not installed. Run: scripts/setup_mac.sh"
    fi

    # Check if model exists (match model name with or without :tag suffix)
    # Use subshell to avoid SIGPIPE issues with pipefail
    if ! (ollama list 2>/dev/null || true) | grep -qE "^${OLLAMA_MODEL}(:|[[:space:]])"; then
        die "Model ${OLLAMA_MODEL} not found. Run: ollama pull ${OLLAMA_MODEL}"
    fi

    # Start Ollama serve if not running
    if ! pgrep -x "ollama" >/dev/null 2>&1; then
        echo "starting Ollama server..."
        nohup ollama serve >"${LOG_FILE}" 2>&1 &
        pid=$!
        echo "${pid}" > "${PID_FILE}"
        sleep 2
    else
        # Ollama already running, get its PID
        pid="$(pgrep -x "ollama" | head -1)"
        echo "${pid}" > "${PID_FILE}"
    fi

    # Ollama listens on 11434 by default
    OLLAMA_PORT="11434"
    echo "${OLLAMA_PORT}" > "${PORT_FILE}"

    echo "started Ollama (pid ${pid})"
    echo "- model: ${OLLAMA_MODEL}"
    echo "- url: http://${HOST}:${OLLAMA_PORT}/v1"
    echo "- log: ${LOG_FILE}"
    echo ""
    echo "Note: Ollama uses port 11434 (OpenAI-compatible at /v1)"
else
    # Linux/WSL: Use vLLM if available, otherwise Ollama
    USE_OLLAMA=0

    # Check if vLLM venv exists and has vllm installed
    if [[ -d "${VENV_DIR}" ]]; then
        activate_venv
        if ! python -c "import vllm" >/dev/null 2>&1; then
            USE_OLLAMA=1
        fi
    else
        USE_OLLAMA=1
    fi

    # Also use Ollama if explicitly requested
    if [[ "${DEVSTRAL_USE_OLLAMA:-0}" == "1" ]]; then
        USE_OLLAMA=1
    fi

    if [[ "${USE_OLLAMA}" == "1" ]]; then
        # Linux with Ollama fallback
        OLLAMA_MODEL="${DEVSTRAL_OLLAMA_MODEL:-gpt-oss:20b-12k}"

        if ! have ollama; then
            die "Neither vLLM nor Ollama installed. Run: scripts/setup.sh"
        fi

        # Check if model exists
        if ! (ollama list 2>/dev/null || true) | grep -qE "^${OLLAMA_MODEL}(:|[[:space:]])"; then
            die "Model ${OLLAMA_MODEL} not found. Run: ollama pull ${OLLAMA_MODEL}"
        fi

        # Start Ollama serve if not running
        if ! pgrep -x "ollama" >/dev/null 2>&1; then
            echo "starting Ollama server..."
            nohup ollama serve >"${LOG_FILE}" 2>&1 &
            pid=$!
            echo "${pid}" > "${PID_FILE}"
            sleep 2
        else
            pid="$(pgrep -x "ollama" | head -1)"
            echo "${pid}" > "${PID_FILE}"
        fi

        OLLAMA_PORT="11434"
        echo "${OLLAMA_PORT}" > "${PORT_FILE}"

        echo "started Ollama (pid ${pid})"
        echo "- model: ${OLLAMA_MODEL}"
        echo "- url: http://${HOST}:${OLLAMA_PORT}/v1"
        echo "- log: ${LOG_FILE}"
    else
        # Linux with vLLM
        mkdir -p "${HF_HOME_DIR}"

        config="$(auto_config)"
        MODEL="$(echo "${config}" | cut -d'|' -f1)"
        MAX_MODEL_LEN="$(echo "${config}" | cut -d'|' -f2)"
        EXTRA_FLAGS="$(echo "${config}" | cut -d'|' -f3)"

        export HF_HOME="${HF_HOME_DIR}"
        export VLLM_HOST_IP="127.0.0.1"
        export DEVSTRAL_MODEL="${MODEL}"
        export DEVSTRAL_HOST="${HOST}"
        export DEVSTRAL_PORT="${PORT}"
        export DEVSTRAL_MAX_MODEL_LEN="${MAX_MODEL_LEN}"
        export DEVSTRAL_EXTRA_FLAGS="${EXTRA_FLAGS}"

        nohup python "${REPO_ROOT}/server/run_devstral_server.py" \
            >"${LOG_FILE}" 2>&1 &

        pid=$!
        echo "${pid}" > "${PID_FILE}"
        echo "${PORT}" > "${PORT_FILE}"

        echo "started (pid ${pid})"
        echo "- model: ${MODEL}"
        echo "- max_model_len: ${MAX_MODEL_LEN}"
        echo "- url: http://${HOST}:${PORT}/v1"
        echo "- log: ${LOG_FILE}"
    fi
fi
