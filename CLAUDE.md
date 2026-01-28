# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

devstral-infra is a cross-platform local inference server for coding AI models.

**Supported models:**
- devstral-small-2 (24B parameters, ~15GB, 384K context) - for Vibe
- glm-4.7-flash (30B total / 3B active MoE, ~19GB, 198K context) - for OpenCode
- devstral-2 (123B parameters, ~75GB, 256K context) - Linux only

**Supported clients:**
- Mistral Vibe CLI - works with devstral-small-2
- OpenCode CLI - works with glm-4.7-flash (officially recommended by Ollama)

**Supported platforms:**
- macOS (Apple Silicon via Ollama + Metal)
- Linux (vLLM + NVIDIA CUDA or CPU)
- Windows (WSL2 + vLLM)

**Backend decision:**
- **macOS uses Ollama** because official Mistral models use FP8 quantization which Apple Silicon cannot accelerate (FP8 requires NVIDIA tensor cores). Ollama models use Q4_K_M quantization with native Metal support.
- **Linux uses vLLM** with the Mistral-recommended flags (`--tokenizer_mode mistral --config_format mistral --load_format mistral`).

**Known limitations (macOS):**
- Ollama/llama.cpp Devstral quality may be lower than vLLM on NVIDIA - Mistral recommends API if issues occur
- No official Mistral documentation for self-hosted Vibe on Mac
- Vibe config based on community guide: https://dev.to/chung_duy_51a346946b27a3d/running-mistral-vibe-with-local-llms-a-complete-guide-1mde

## Commands

**Setup** (auto-detects platform):
```bash
chmod +x scripts/*.sh ci/*.sh ci/*.py
scripts/setup.sh
```

**Start server:**
```bash
scripts/server_start.sh
```

**Stop server:**
```bash
scripts/server_stop.sh
```

**Configure Vibe (Mistral):**
```bash
scripts/vibe_install.sh
scripts/vibe_set_local.sh
```

**Configure OpenCode (recommended for tool calling):**
```bash
scripts/opencode_install.sh
scripts/opencode_set_local.sh  # Creates glm-4.7-flash-16k automatically
```

**Security hardening (block network access):**
```bash
scripts/security_harden.sh   # Block Vibe, OpenCode, Ollama
scripts/security_unharden.sh # Restore network access
```

**Run tests:**
```bash
bash ci/run_tests.sh
```

## Environment Variables

### Server

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVSTRAL_OLLAMA_MODEL` | devstral-small-2 | Ollama model (macOS) |
| `DEVSTRAL_MODEL` | auto-detected | vLLM model ID (Linux) |
| `DEVSTRAL_MAX_MODEL_LEN` | auto-detected | Context length (Linux) |
| `DEVSTRAL_HOST` | 127.0.0.1 | Bind address |
| `DEVSTRAL_PORT` | 8080 | Port (Linux; macOS uses 11434) |

### Vibe

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_PATH` | ~/.vibe/config.toml | Config file path |
| `VIBE_LOCAL_MODEL_ID` | auto-detected | Model ID in config |
| `VIBE_LOCAL_PROVIDER_NAME` | ollama (Mac) / local (Linux) | Provider name |
| `VIBE_LOCAL_API_BASE` | auto | API endpoint |

### OpenCode

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_CONFIG_PATH` | ~/.config/opencode/opencode.json | Config file path |
| `OPENCODE_LOCAL_MODEL_ID` | glm-4.7-flash-16k | Model ID (16k context for tool calling) |
| `OPENCODE_LOCAL_API_BASE` | http://localhost:11434/v1 | API endpoint |

## Architecture

```
scripts/
  _common.sh              # Core utilities, hardware detection
  setup.sh                # Platform dispatcher -> setup_{mac,linux,wsl}.sh
  setup_mac.sh            # Ollama installation + model pull
  setup_linux.sh          # vLLM pip install (CUDA auto-detect, CPU fallback)
  setup_wsl.sh            # WSL validation + setup_linux.sh
  detect_hardware.sh      # Display hardware info and viable configurations
  server_start.sh         # Launch Ollama (Mac) or vLLM (Linux)
  server_stop.sh          # Graceful shutdown
  teardown.sh             # Remove venv, caches, runtime files
  vibe_install.sh         # Install Vibe CLI (from mistral.ai)
  vibe_set_local.sh       # Generate Vibe config.toml for local Ollama
  vibe_unset_local.sh     # Restore Vibe config from backup
  opencode_install.sh     # Install OpenCode CLI
  opencode_set_local.sh   # Generate OpenCode config for local Ollama
  opencode_unset_local.sh # Restore OpenCode config from backup
  security_harden.sh      # Block Vibe/OpenCode/Ollama network access
  security_unharden.sh    # Restore network access

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

**macOS (Ollama):**
- Base URL: `http://127.0.0.1:11434/v1`
- Models: `devstral-small-2`, `glm-4.7-flash`
- Tool calling: Yes (native support)

**Linux (vLLM):**
- Base URL: `http://127.0.0.1:8080/v1`
- Model name: `mistralai/Devstral-Small-2-24B-Instruct-2512`
- Tool calling: Yes (`--enable-auto-tool-choice --tool-call-parser mistral`)

## Model Recommendations

| Use Case | Model | Size | Why |
|----------|-------|------|-----|
| OpenCode (tool calling) | glm-4.7-flash-16k | 19GB + 5GB KV | 16k context required for tool calling |
| Vibe (Mistral native) | devstral-small-2 | 15GB | Native Mistral tool calling format |
| Linux NVIDIA | devstral-small-2 | 24GB | Full quality via vLLM |

**Important:** OpenCode requires 16k-64k context for tool calling to work. The default Ollama 4k context causes tools to fail with "invalid tool" errors.

**Performance on Apple Silicon (32GB):**
- GLM-4.7-Flash-16k: 30-50 tok/s (16k context uses ~5GB extra for KV cache)
- Devstral-small-2: 40-60 tok/s with default context

## Runtime Directories

- `.venv/` - Python virtual environment (Linux only)
- `.hf/` - HuggingFace model cache (Linux only)
- `.run/` - PID file, port file, server logs

## Key Constraints

- macOS requires Ollama 0.14.3+ for glm-4.7-flash-16k, 0.13.3+ for devstral-small-2
- Linux requires Python 3.11+ for vLLM
- OpenCode requires 64K+ context for best tool calling
- Graceful shutdown has 30-second timeout before SIGTERM
- Multi-GPU (Linux) uses `--tensor-parallel-size` (auto-detected)

## Security Hardening

The `security_harden.sh` script blocks network access for:
- **Vibe** - prevents telemetry and cloud API calls
- **OpenCode** - disables autoupdate, telemetry, websearch
- **Ollama** - prevents model downloads and potential telemetry

After hardening, applications can only connect to localhost (local Ollama server).

**Important:** Pull all required models BEFORE running security_harden.sh:
```bash
ollama pull devstral-small-2
ollama pull glm-4.7-flash
scripts/security_harden.sh
```
