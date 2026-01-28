# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

devstral-infra is a cross-platform local inference server for Devstral models using vLLM. It auto-detects hardware and selects optimal model configuration.

**Supported models:**
- Devstral 2 123B (mistralai/Devstral-2-123B-Instruct-2512)
- Devstral Small 24B (mistralai/Devstral-Small-2-24B-Instruct-2512)

**Supported platforms:**
- macOS (Apple Silicon via vllm-metal)
- Linux (NVIDIA CUDA or CPU)
- Windows (WSL2)

## Commands

**Setup** (auto-detects platform):
```bash
chmod +x scripts/*.sh ci/*.sh ci/*.py
scripts/setup.sh
```

**Show hardware and viable configs:**
```bash
scripts/detect_hardware.sh
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

**Security hardening:**
```bash
scripts/security_harden.sh   # Requires sudo
scripts/security_unharden.sh
```

**Run tests:**
```bash
bash ci/run_tests.sh
```

**Cleanup:**
```bash
scripts/teardown.sh
```

## Environment Variables

### Server

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVSTRAL_MODEL` | auto-detected | Full model ID |
| `DEVSTRAL_MODEL_SIZE` | auto | `small` (24B) or `full` (123B) |
| `DEVSTRAL_MAX_MODEL_LEN` | auto-detected | Context length |
| `DEVSTRAL_HOST` | 127.0.0.1 | Bind address |
| `DEVSTRAL_PORT` | 8080 | Port |
| `DEVSTRAL_EXTRA_FLAGS` | (empty) | Additional vLLM flags |

### Vibe

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_PATH` | ~/.vibe/config.toml | Config file path |
| `VIBE_LOCAL_MODEL_ID` | auto-detected | Model ID in config |
| `VIBE_LOCAL_PROVIDER_NAME` | local | Provider name |
| `VIBE_LOCAL_API_BASE` | http://127.0.0.1:8080/v1 | API endpoint |

## Architecture

```
scripts/
  _common.sh          # Core utilities, hardware detection, config mapping
  setup.sh            # Platform dispatcher -> setup_{mac,linux,wsl}.sh
  setup_mac.sh        # vllm-metal installation
  setup_linux.sh      # vLLM pip install (CUDA auto-detect, CPU fallback)
  setup_wsl.sh        # WSL validation + setup_linux.sh
  detect_hardware.sh  # Display hardware info and viable configurations
  server_start.sh     # Launch vLLM with auto-detected config
  server_stop.sh      # Graceful shutdown (SIGINT -> SIGTERM)
  teardown.sh         # Remove venv, caches, runtime files
  vibe_install.sh     # Install Vibe CLI
  vibe_set_local.sh   # Patch Vibe TOML for local server
  vibe_unset_local.sh # Restore Vibe config from backup
  security_harden.sh  # Block Vibe network (macOS firewall / Linux iptables)
  security_unharden.sh

server/
  run_devstral_server.py  # vLLM launcher with Mistral flags

ci/
  mock_server.py          # Pure-stdlib mock OpenAI server
  run_tests.sh            # Test suite runner
  test_setup.sh           # Platform detection, config tests
  test_hardware_detect.sh # Hardware -> config mapping tests
  test_vibe_config.sh     # TOML patching tests
  test_security.sh        # Security setting tests
  test_server_health.sh   # Mock server endpoint tests
  test_server_inference.sh # Real inference with Ministral 3B (CI_SMOKE_TEST=1)

.github/workflows/
  ci.yml              # lint, test-linux, test-macos, test-wsl, smoke-linux
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
- `model_memory_requirements()` - Memory needed for model+quantization
- `context_memory_overhead()` - Additional memory for context

## Hardware-to-Config Mapping

The system maps available memory to optimal configurations:

**Mac (unified memory, 75% usable for GPU):**
| Memory | Model | Context |
|--------|-------|---------|
| >= 170 GB | 123B | 262K |
| >= 123 GB | 123B | 131K |
| >= 82 GB | 123B | 32K |
| >= 55 GB | 24B | 262K |
| >= 35 GB | 24B | 131K |
| >= 24 GB | 24B | 57K |
| >= 20 GB | 24B | 32K |
| >= 16 GB | 24B | 8K |

**NVIDIA (VRAM):**
| VRAM | Model | Context | Notes |
|------|-------|---------|-------|
| >= 96 GB | 123B | 32K | Multi-GPU (4x24GB) |
| >= 48 GB | 24B | 262K | |
| >= 24 GB | 24B | 57K | |
| >= 16 GB | 24B | 32K | |
| >= 12 GB | 24B | 8K | |

## Runtime Directories

- `.venv/` - Python virtual environment
- `.hf/` - HuggingFace model cache (`HF_HOME`)
- `.run/` - PID file, port file, server logs

## Key Constraints

- macOS requires Python 3.12 (vllm-metal wheel compatibility)
- Linux accepts Python 3.11+
- Vibe TOML manipulation uses regex (not full TOML parser)
- Graceful shutdown has 30-second timeout before SIGTERM
- Multi-GPU uses `--tensor-parallel-size` (auto-detected)

## vllm-metal Fork (macOS)

On macOS, we use a fork of vllm-metal that upgrades vLLM from 0.13.0 to 0.14.1 for transformers 5.x compatibility.

- **Fork**: https://github.com/krystophny/vllm-metal
- **Branch**: `fix-transformers-5-compat`
- **Issue**: https://github.com/krystophny/vllm-metal/issues/6

The upstream vllm-metal hardcodes vLLM 0.13.0, which is incompatible with transformers >= 5.0 due to a renamed constant (`ALLOWED_LAYER_TYPES` -> `ALLOWED_MLP_LAYER_TYPES`). The fix was merged in vLLM 0.14.0 (PR vllm-project/vllm#31146).

**Override fork settings:**
```bash
VLLM_METAL_FORK_REPO=krystophny/vllm-metal VLLM_METAL_FORK_BRANCH=fix-transformers-5-compat scripts/setup.sh
```
