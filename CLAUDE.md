# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

devstral-infra is a cross-platform local inference server for coding AI models.

**Supported models:**
- devstral-small-2 (24B parameters, ~15GB, 32K context) - for Vibe and OpenCode
- GLM-4.7-REAP-50 (47B parameters, ~30GB, 32K context) - for OpenCode (reasoning)
- devstral-2 (123B parameters, ~75GB, 32K context) - high-end hardware

**Supported clients:**
- Mistral Vibe CLI - works with devstral-small-2
- OpenCode CLI - works with devstral-small-2 or GLM-4.7

**Supported platforms:**
- macOS (Apple Silicon via LM Studio + MLX)
- Linux (LM Studio or vLLM + NVIDIA CUDA/CPU)
- Windows (WSL2 + LM Studio)

**Backend decision:**
- **macOS uses LM Studio** with MLX backend for native Apple Silicon acceleration. Models use 4-bit quantization.
- **Linux uses LM Studio** or **vLLM** with the Mistral-recommended flags (`--tokenizer_mode mistral --config_format mistral --load_format mistral`).

## Commands

**Setup (LM Studio - recommended):**
```bash
chmod +x scripts/*.sh ci/*.sh ci/*.py
scripts/lmstudio_install.sh       # Install LM Studio + lms CLI
scripts/lmstudio_server_start.sh  # Start API server
```

**Configure Vibe:**
```bash
scripts/vibe_install.sh
scripts/vibe_set_lmstudio.sh
```

**Configure OpenCode:**
```bash
scripts/opencode_install.sh
scripts/opencode_set_lmstudio.sh
```

**One-command setup (GLM-4.7 + OpenCode):**
```bash
scripts/lmstudio_set_local.sh  # Downloads model, starts server, configures OpenCode
```

**Stop server:**
```bash
scripts/lmstudio_server_stop.sh
```

**Security hardening (block network access):**
```bash
scripts/security_harden.sh   # Block Vibe, OpenCode, LM Studio
scripts/security_unharden.sh # Restore network access
```

**Run tests:**
```bash
bash ci/run_tests.sh
```

## Environment Variables

### LM Studio

| Variable | Default | Description |
|----------|---------|-------------|
| `LMSTUDIO_PORT` | 1234 | API server port |
| `LMSTUDIO_HOST` | 127.0.0.1 | Bind address |
| `LMSTUDIO_MODEL_ID` | auto | Model to load |
| `LMSTUDIO_CONTEXT_SIZE` | 32768 | Context length |

### Vibe

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_PATH` | ~/.vibe/config.toml | Config file path |
| `VIBE_LOCAL_MODEL_ID` | mistralai/devstral-small-2-2512 | Model ID |

### OpenCode

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_CONFIG_PATH` | ~/.config/opencode/opencode.json | Config file path |
| `OPENCODE_LOCAL_MODEL_ID` | mistralai/devstral-small-2-2512 | Model ID |

## Architecture

```
scripts/
  _common.sh              # Core utilities, hardware detection
  lmstudio_install.sh     # Install LM Studio + lms CLI
  lmstudio_download_models.sh # Download recommended models
  lmstudio_server_start.sh    # Start LM Studio API server
  lmstudio_server_stop.sh     # Stop server
  lmstudio_set_local.sh       # One-command GLM-4.7 + OpenCode setup
  vibe_install.sh         # Install Vibe CLI (from mistral.ai)
  vibe_set_lmstudio.sh    # Configure Vibe for LM Studio
  vibe_unset_local.sh     # Restore Vibe config from backup
  opencode_install.sh     # Install OpenCode CLI
  opencode_set_lmstudio.sh    # Configure OpenCode for LM Studio
  opencode_unset_local.sh     # Restore OpenCode config from backup
  security_harden.sh      # Block Vibe/OpenCode/LM Studio network access
  security_unharden.sh    # Restore network access
  setup.sh                # Platform dispatcher
  setup_linux.sh          # vLLM pip install (CUDA auto-detect, CPU fallback)
  setup_wsl.sh            # WSL validation + setup_linux.sh
  detect_hardware.sh      # Display hardware info and viable configurations
  server_start.sh         # Start server (LM Studio on Mac, vLLM on Linux)
  server_stop.sh          # Stop server
  teardown.sh             # Remove venv, caches, runtime files

server/
  run_devstral_server.py  # vLLM launcher (Linux only)

ci/
  mock_server.py          # Pure-stdlib mock OpenAI server
  run_tests.sh            # Test suite runner
  test_*.sh               # Test suites
```

## Key Functions in _common.sh

- `detect_platform()` - Returns `mac`, `linux`, or `wsl`
- `detect_vram_mb()` - VRAM on NVIDIA, 75% of RAM on Mac
- `detect_ram_mb()` - Total system RAM
- `detect_gpu()` - Returns `metal`, `cuda`, or `cpu`
- `detect_gpu_count()` - Number of GPUs (for tensor parallelism)
- `list_viable_configs()` - All configs that fit in available memory
- `best_config()` - Top recommendation
- `auto_config()` - Full config string: model|context|extra_flags

## API Endpoints

**LM Studio (macOS/Linux):**
- Base URL: `http://127.0.0.1:1234/v1`
- Models: `mistralai/devstral-small-2-2512`, `glm-4.7-reap-50`
- Tool calling: Yes (native support)

**vLLM (Linux):**
- Base URL: `http://127.0.0.1:8080/v1`
- Model name: `mistralai/Devstral-Small-2-24B-Instruct-2512`
- Tool calling: Yes (`--enable-auto-tool-choice --tool-call-parser mistral`)

## Model Recommendations

| Use Case | Model | Size | Why |
|----------|-------|------|-----|
| Vibe + OpenCode | devstral-small-2 | 15GB | Good all-rounder for coding |
| OpenCode (reasoning) | GLM-4.7-REAP-50 | 30GB | Better reasoning, needs 64GB RAM |
| Linux NVIDIA | devstral-small-2 | 24GB | Full quality via vLLM |

## Runtime Directories

- `.venv/` - Python virtual environment (Linux only)
- `.hf/` - HuggingFace model cache (Linux only)
- `.run/` - PID file, port file, server logs

## Key Constraints

- macOS requires LM Studio with MLX backend
- Linux requires Python 3.11+ for vLLM
- Graceful shutdown has 30-second timeout before SIGTERM
- Multi-GPU (Linux) uses `--tensor-parallel-size` (auto-detected)

## llama.cpp Backend (Qwen3.5-35B-A3B)

**Server script:** `scripts/server_start_llamacpp.sh`
- Prefers the real local sibling build at `/Users/user/code/llama.cpp-dev/llama.cpp/build/bin/llama-server` when present
- Defaults to the local cached `UD-Q4_K_XL` GGUF because it is currently the reliable quantization in this setup
- Default context: 262144 (256k)
- Default context checkpoints: 64
- Default checkpoint interval: 4096 tokens
- Default batch / ubatch: 2048 / 512
- Reasoning disabled by default for shorter, more stable OpenCode turns
- OpenCode config generator sets `permission: "allow"` for the local llama.cpp profile
- Prefers detached `tmux` supervision on macOS for reliable background operation
- Waits for `/v1/models` readiness instead of just `/health`
- Prints the actual `llama-server` version at launch so stale local builds are visible
- API: `http://127.0.0.1:8080/v1`
- Override binary: `LLAMACPP_SERVER_BIN=/path/to/llama-server`
- Override model: `LLAMACPP_HF_MODEL=unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL`

**Local model cache (macOS):** `~/Library/Caches/llama.cpp/`
- Q4: `unsloth_Qwen3.5-35B-A3B-GGUF_Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf` (18GB, cached)
- Q6: `unsloth_Qwen3.5-35B-A3B-GGUF_Qwen3.5-35B-A3B-UD-Q6_K_XL.gguf` (download separately, not default)
- Q8: `unsloth_Qwen3.5-35B-A3B-GGUF_Qwen3.5-35B-A3B-UD-Q8_K_XL.gguf` (49GB)

**llama.cpp source checkout and local experimentation:**
- Repo: `/Users/user/code/llama.cpp` (fork: `krystophny/llama.cpp`)
- Remotes: `origin` (krystophny), `upstream` (ggml-org), `eauchs` (eauchs)
- Build: `cmake -B build -G Ninja -DGGML_METAL=ON -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ && cmake --build build -j$(sysctl -n hw.ncpu)`
- Binary: `/Users/user/code/llama.cpp/build/bin/llama-server`

For normal local OpenCode use, prefer actual upstream `master` behavior and verify the binary version before drawing conclusions.

**Branches in llama.cpp fork:**
- `fix-hybrid-spec-bugs` — PR 1: bug fixes for eauchs's SSM state rollback (PR #20075). Against `eauchs/feat/qwen-moe-speculative-decoding`.
- `hybrid-cache-reuse` — PR 2 (WIP): multi-turn cache reuse for hybrid models. Against `upstream/master`. Depends on PR #20075.

**Recommended local OpenCode profile:**
```bash
LLAMACPP_CONTEXT=262144 \
LLAMACPP_CTX_CHECKPOINTS=64 \
LLAMACPP_CHECKPOINT_EVERY_N_TOKENS=4096 \
LLAMACPP_BATCH=2048 \
LLAMACPP_UBATCH=512 \
LLAMACPP_ENABLE_THINKING=false \
LLAMACPP_SERVER_BIN=/Users/user/code/llama.cpp-dev/llama.cpp/build/bin/llama-server \
scripts/server_start_llamacpp.sh
scripts/opencode_set_llamacpp.sh
```

**Testing the custom build with Qwen3.5:**
```bash
# Single-turn test
/Users/user/code/llama.cpp-dev/llama.cpp/build/bin/llama-server \
  -m ~/Library/Caches/llama.cpp/unsloth_Qwen3.5-35B-A3B-GGUF_Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  -c 262144 --ctx-checkpoints 64 --checkpoint-every-n-tokens 4096 \
  -b 2048 -ub 512 -fa -ngl 99 -np 1 --port 18080 \
  --reasoning off

# Multi-turn cache reuse test (observe prompt_eval on turn 2+)
curl -s http://127.0.0.1:18080/v1/chat/completions -d '{
  "model": "qwen3.5",
  "messages": [{"role":"system","content":"You are a helpful assistant."},
               {"role":"user","content":"What is 2+2?"}]
}' | jq '.usage'
```

**Speculative decoding note:** Qwen3.5 dense models (0.8B etc) are NOT compatible as draft models for the MoE variants. Spec decoding for Qwen3.5-A3B requires same-architecture drafts which don't exist yet.

## Security Hardening

The `security_harden.sh` script blocks network access for:
- **Vibe** - prevents telemetry and cloud API calls
- **OpenCode** - disables autoupdate, telemetry, websearch
- **LM Studio** - prevents model downloads and potential telemetry

After hardening, applications can only connect to localhost (local LM Studio server).

**Important:** Download all required models BEFORE running security_harden.sh:
```bash
lms get mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
lms get mlx-community/GLM-4.7-REAP-50-mxfp4
scripts/security_harden.sh
```
