# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

devstral-infra is a cross-platform local inference server for Devstral models.

**Supported models:**
- devstral-small-2 (24B parameters, ~15GB, 384K context)
- devstral-2 (123B parameters, ~75GB, 256K context)

**Supported platforms:**
- macOS (Apple Silicon via Ollama + Metal)
- Linux (vLLM + NVIDIA CUDA or CPU)
- Windows (WSL2 + vLLM)

**Backend decision:**
- **macOS uses Ollama** because official Mistral models use FP8 quantization which vllm-metal (mlx-vlm) cannot load. Ollama's devstral-small-2 has native Metal support and working tool calling.
- **Linux uses vLLM** with the Mistral-recommended flags (`--tokenizer_mode mistral --config_format mistral --load_format mistral`).

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

**Configure Vibe:**
```bash
scripts/vibe_install.sh
scripts/vibe_set_local.sh
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

## Architecture

```
scripts/
  _common.sh          # Core utilities, hardware detection
  setup.sh            # Platform dispatcher -> setup_{mac,linux,wsl}.sh
  setup_mac.sh        # Ollama installation + model pull
  setup_linux.sh      # vLLM pip install (CUDA auto-detect, CPU fallback)
  setup_wsl.sh        # WSL validation + setup_linux.sh
  detect_hardware.sh  # Display hardware info and viable configurations
  server_start.sh     # Launch Ollama (Mac) or vLLM (Linux)
  server_stop.sh      # Graceful shutdown
  teardown.sh         # Remove venv, caches, runtime files
  vibe_install.sh     # Install Vibe CLI
  vibe_set_local.sh   # Patch Vibe TOML for local server
  vibe_unset_local.sh # Restore Vibe config from backup
  security_harden.sh  # Block Vibe network
  security_unharden.sh

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
- Model name: `devstral-small-2`
- Tool calling: Yes (native support)

**Linux (vLLM):**
- Base URL: `http://127.0.0.1:8080/v1`
- Model name: `mistralai/Devstral-Small-2-24B-Instruct-2512`
- Tool calling: Yes (`--enable-auto-tool-choice --tool-call-parser mistral`)

## Runtime Directories

- `.venv/` - Python virtual environment (Linux only)
- `.hf/` - HuggingFace model cache (Linux only)
- `.run/` - PID file, port file, server logs

## Key Constraints

- macOS requires Ollama 0.13.3+ for devstral-small-2
- Linux requires Python 3.11+ for vLLM
- Vibe TOML manipulation uses regex (not full TOML parser)
- Graceful shutdown has 30-second timeout before SIGTERM
- Multi-GPU (Linux) uses `--tensor-parallel-size` (auto-detected)
