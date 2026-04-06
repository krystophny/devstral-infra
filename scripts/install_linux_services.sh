#!/usr/bin/env bash
# Install systemd user services for llama.cpp and voxtype on Linux.
# Requires: llama.cpp built at ~/code/llama.cpp-dev/llama.cpp/build/bin/llama-server
#           voxtype built at ~/code/voxtype/target/release/voxtype (with gpu-cuda feature)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "${UNIT_DIR}"

LLAMA_SERVER="${HOME}/code/llama.cpp-dev/llama.cpp/build/bin/llama-server"
LLAMA_SERVER_DIR="$(cd "$(dirname "${LLAMA_SERVER}")" && pwd)"
VOXTYPE_BIN="${HOME}/.local/bin/voxtype"
VOXTYPE_SRC="${HOME}/code/voxtype/target/release/voxtype"

build_llamacpp_exec_start() {
    local instance="$1"
    HOME="${HOME}" \
    DEVSTRAL_HOST=127.0.0.1 \
    LLAMACPP_SERVER_BIN="${LLAMA_SERVER}" \
    LLAMACPP_PRINT_EXEC_START=true \
    LLAMACPP_SMOKE_TEST=false \
    bash "${SCRIPT_DIR}/server_start_llamacpp.sh" "${instance}"
}

# --- llama.cpp fast instance (Qwen3.5-9B Q4_K_M, port 8081) ---
echo "Installing devstral-llamacpp-fast.service..."
if [[ ! -x "${LLAMA_SERVER}" ]]; then
    echo "WARNING: llama-server not found at ${LLAMA_SERVER}"
    echo "  Build it first: cd ~/code/llama.cpp-dev/llama.cpp && cmake -B build -DGGML_CUDA=ON && cmake --build build -j\$(nproc) --target llama-server"
fi

if [[ -x "${LLAMA_SERVER}" ]]; then
    FAST_EXEC_START="$(build_llamacpp_exec_start fast)"
else
    FAST_EXEC_START="${LLAMA_SERVER} -hf lmstudio-community/Qwen3.5-9B-GGUF:Q4_K_M -c 131072 --ctx-checkpoints 64 --checkpoint-every-n-tokens 4096 -b 2048 -ub 512 -ngl 99 -fa on -np 1 -t 16 --host 127.0.0.1 --port 8081 --alias qwen --jinja --reasoning on"
fi

cat > "${UNIT_DIR}/devstral-llamacpp-fast.service" <<EOF
[Unit]
Description=llama.cpp inference server (Qwen3.5-9B fast)
After=network.target

[Service]
Type=simple
ExecStart=${FAST_EXEC_START}
Environment=LD_LIBRARY_PATH=${LLAMA_SERVER_DIR}
Restart=on-failure
RestartSec=10
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF

# --- voxtype STT (CUDA, port 8427) ---
echo "Installing voxtype.service..."
if [[ -x "${VOXTYPE_SRC}" ]]; then
    echo "  Installing voxtype binary from source build..."
    mkdir -p "$(dirname "${VOXTYPE_BIN}")"
    # Stop service first to avoid "text file busy"
    systemctl --user stop voxtype.service 2>/dev/null || true
    cp "${VOXTYPE_SRC}" "${VOXTYPE_BIN}"
elif [[ ! -x "${VOXTYPE_BIN}" ]]; then
    echo "WARNING: voxtype not found. Build it first:"
    echo "  cd ~/code/voxtype && cargo clean && cargo build --release --features gpu-cuda"
fi

cat > "${UNIT_DIR}/voxtype.service" <<EOF
[Unit]
Description=Voxtype STT daemon with OpenAI API
After=network.target

[Service]
Type=simple
ExecStart=${VOXTYPE_BIN} --service --service-host 127.0.0.1 --service-port 8427
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

# --- Enable GPU for voxtype ---
if command -v nvidia-smi &>/dev/null; then
    echo "  Enabling GPU acceleration for voxtype..."
    sudo "${VOXTYPE_BIN}" setup gpu --enable 2>/dev/null || echo "  (GPU setup requires sudo, skipping)"
fi

# --- Reload and enable ---
systemctl --user daemon-reload
systemctl --user enable devstral-llamacpp-fast.service voxtype.service

echo ""
echo "Services installed and enabled."
echo "  systemctl --user start devstral-llamacpp-fast.service"
echo "  systemctl --user start voxtype.service"
echo ""
echo "Status:"
echo "  systemctl --user status devstral-llamacpp-fast.service voxtype.service"
