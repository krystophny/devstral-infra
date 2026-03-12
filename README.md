# devstral-infra

Cross-platform local inference server for coding AI models.

- **Auto-detection**: Automatically selects optimal model and configuration based on hardware
- **Cross-platform**: macOS (LM Studio + MLX), Linux (vLLM + CUDA/CPU), Windows (WSL)
- **Tool calling**: Full tool use support for coding assistants
- **Vibe integration**: Configure Mistral Vibe CLI to use your local server
- **OpenCode integration**: Configure OpenCode CLI for efficient tool calling
- **llama.cpp + Qwen3.5 profile**: Uses a real local build from upstream `llama.cpp` `master`, with `Q4` as the default working quantization
- **Security hardening**: Optional network isolation for Vibe, OpenCode, and LM Studio

## Quick Start

```bash
chmod +x scripts/*.sh ci/*.sh ci/*.py
scripts/lmstudio_install.sh       # Install LM Studio (macOS/Linux)
scripts/lmstudio_server_start.sh  # Start server
scripts/vibe_set_lmstudio.sh      # Configure Vibe for local server
scripts/opencode_set_lmstudio.sh  # Configure OpenCode for local server
scripts/server_start_llamacpp.sh  # Start local llama.cpp Qwen3.5 server on port 8080
scripts/opencode_set_llamacpp.sh  # Configure OpenCode for local llama.cpp server
```

## Platform Backends

| Platform | Backend | GPU | Tool Calling | Port |
|----------|---------|-----|--------------|------|
| macOS (Apple Silicon) | LM Studio | MLX | Yes | 1234 |
| Linux | LM Studio | NVIDIA/CPU | Yes | 1234 |
| Linux | vLLM | NVIDIA CUDA | Yes | 8080 |
| Windows | WSL + LM Studio | NVIDIA | Yes | 1234 |

**Why LM Studio on macOS?**
- Native MLX backend with full Apple Silicon acceleration
- OpenAI-compatible API with `lms` CLI
- Supports 4-bit quantization for large models

## Supported Models

| Model | Parameters | Memory (4-bit) | Context | Use Case |
|-------|------------|----------------|---------|----------|
| devstral-small-2 | 24B | ~15 GB | 32K | Vibe, OpenCode |
| GLM-4.7-REAP-50 | 47B | ~30 GB | 32K | OpenCode (reasoning) |
| Qwen3.5-35B-A3B Q4 | 35B A3B | ~18 GB GGUF + KV cache | 256K | OpenCode local llama.cpp |
| devstral-2 | 123B | ~75 GB | 32K | High-end hardware |

## Commands

### Setup

```bash
scripts/lmstudio_install.sh       # Install LM Studio + lms CLI
scripts/lmstudio_download_models.sh  # Download recommended models
```

### Server

```bash
scripts/lmstudio_server_start.sh  # Start LM Studio API server
scripts/lmstudio_server_stop.sh   # Stop server
```

**macOS/Linux (LM Studio):**
```bash
# Default port: 1234
# API: http://127.0.0.1:1234/v1

# Load a model:
lms load mistralai/devstral-small-2-2512

# List models:
lms ls
```

**Linux (vLLM alternative):**
```bash
scripts/server_start.sh  # Start vLLM server on port 8080
scripts/server_stop.sh   # Stop server
```

### Vibe Integration

```bash
scripts/vibe_install.sh       # Install Vibe CLI
scripts/vibe_set_lmstudio.sh  # Configure Vibe for LM Studio
scripts/vibe_unset_local.sh   # Restore original Vibe config
```

### OpenCode Integration

```bash
scripts/opencode_install.sh       # Install OpenCode CLI
scripts/opencode_set_lmstudio.sh  # Configure OpenCode for LM Studio
scripts/opencode_set_llamacpp.sh  # Configure OpenCode for local llama.cpp
scripts/opencode_unset_local.sh   # Restore original OpenCode config
```

### llama.cpp Local Qwen3.5 Profile

```bash
scripts/setup_llamacpp.sh
scripts/server_start_llamacpp.sh
scripts/opencode_set_llamacpp.sh
```

Recommended local profile:
- model: `Qwen3.5-35B-A3B` `UD-Q4_K_XL` by default
- context: `262144`
- context checkpoints: `64`
- checkpoint interval: `4096`
- batch / ubatch: `2048 / 512`
- reasoning: `off` by default for shorter, more stable coding-agent turns
- launcher: `tmux` on macOS when available, otherwise `nohup`
- readiness gate: waits for `/v1/models`, not just `/health`
- verify the actual `llama-server` binary version before drawing conclusions; stale local builds were a major source of earlier confusion
- by default the launcher prefers `/Users/ert/code/llama.cpp-dev/llama.cpp/build/bin/llama-server` when that real local build exists
- `Q8` currently reproduces `@`-only gibberish on trivial prompts in this setup and is not the default
- `Q6` is worth keeping in cache for later evaluation, but is not the default runtime yet

Environment overrides:
- `LLAMACPP_SERVER_BIN`
- `LLAMACPP_MODEL` or `LLAMACPP_HF_MODEL`
- `LLAMACPP_CONTEXT`
- `LLAMACPP_CTX_CHECKPOINTS`
- `LLAMACPP_CHECKPOINT_EVERY_N_TOKENS`
- `LLAMACPP_BATCH`
- `LLAMACPP_UBATCH`
- `LLAMACPP_ENABLE_THINKING`
- `LLAMACPP_LAUNCHER`

### One-Command Setup (GLM-4.7 + OpenCode)

```bash
scripts/lmstudio_set_local.sh  # Downloads GLM-4.7, starts server, configures OpenCode
```

### Security (Optional)

```bash
scripts/security_harden.sh   # Block Vibe, OpenCode, LM Studio network access
scripts/security_unharden.sh # Restore network access
```

**Important:** Download all required models BEFORE hardening:
```bash
lms get mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
lms get mlx-community/GLM-4.7-REAP-50-mxfp4
scripts/security_harden.sh
```

### Cleanup

```bash
scripts/teardown.sh  # Remove venv, caches, PID files
```

## Verify Server

```bash
# Check server status
curl -s http://127.0.0.1:1234/v1/models | python -m json.tool

# Test chat completion
curl -s http://127.0.0.1:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mistralai/devstral-small-2-2512","messages":[{"role":"user","content":"Hello"}]}' \
  | python -m json.tool
```

## Environment Variables

### LM Studio Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LMSTUDIO_PORT` | 1234 | API server port |
| `LMSTUDIO_HOST` | 127.0.0.1 | Bind address |
| `LMSTUDIO_MODEL_ID` | auto | Model to load |
| `LMSTUDIO_CONTEXT_SIZE` | 32768 | Context length |

### Vibe Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_PATH` | ~/.vibe/config.toml | Config file path |
| `VIBE_LOCAL_MODEL_ID` | mistralai/devstral-small-2-2512 | Model ID |

### OpenCode Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_CONFIG_PATH` | ~/.config/opencode/opencode.json | Config file path |
| `OPENCODE_LOCAL_MODEL_ID` | mistralai/devstral-small-2-2512 | Model ID |

## Architecture

```
scripts/
  _common.sh              # Shared utilities, hardware detection
  lmstudio_install.sh     # Install LM Studio + lms CLI
  lmstudio_download_models.sh # Download recommended models
  lmstudio_server_start.sh    # Start LM Studio API server
  lmstudio_server_stop.sh     # Stop server
  lmstudio_set_local.sh       # One-command GLM-4.7 + OpenCode setup
  vibe_install.sh         # Install Vibe CLI
  vibe_set_lmstudio.sh    # Configure Vibe for LM Studio
  vibe_unset_local.sh     # Restore Vibe config
  opencode_install.sh     # Install OpenCode CLI
  opencode_set_lmstudio.sh    # Configure OpenCode for LM Studio
  opencode_unset_local.sh     # Restore OpenCode config
  security_harden.sh      # Network isolation
  security_unharden.sh    # Restore network access
  setup.sh                # Platform dispatcher
  setup_linux.sh          # Linux vLLM setup
  setup_wsl.sh            # WSL setup
  server_start.sh         # Start server (LM Studio on Mac, vLLM on Linux)
  server_stop.sh          # Stop server
  teardown.sh             # Cleanup

server/
  run_devstral_server.py  # vLLM launcher (Linux only)

ci/
  mock_server.py          # Pure-stdlib mock for testing
  run_tests.sh            # Test runner
  test_*.sh               # Test suites
```

## CI/CD

GitHub Actions runs:
- **lint**: shellcheck on all scripts
- **test-linux**: Mock server tests on Ubuntu
- **test-macos**: Mock server tests on macOS
- **test-wsl**: Mock server tests in WSL

## License

MIT
