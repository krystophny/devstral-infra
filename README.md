# devstral-infra

Cross-platform local inference server for coding AI models.

- **Auto-detection**: Automatically selects optimal model and configuration based on hardware
- **Cross-platform**: macOS (Ollama + Metal), Linux (vLLM + CUDA/CPU), Windows (WSL)
- **Tool calling**: Full tool use support matching official Mistral setup
- **Vibe integration**: Configure Mistral Vibe CLI to use your local server
- **OpenCode integration**: Configure OpenCode CLI with gpt-oss for efficient tool calling
- **Security hardening**: Optional network isolation for Vibe, OpenCode, and Ollama

## Quick Start

```bash
chmod +x scripts/*.sh ci/*.sh ci/*.py
scripts/setup.sh             # Install backend (auto-detects platform)
scripts/server_start.sh      # Start server
scripts/vibe_set_local.sh    # Configure Vibe to use local server
scripts/opencode_set_local.sh  # Configure OpenCode (creates gpt-oss-20b-16k)
```

## Platform Backends

| Platform | Backend | GPU | Tool Calling | Port |
|----------|---------|-----|--------------|------|
| macOS (Apple Silicon) | Ollama | Metal | Yes | 11434 |
| Linux | vLLM | NVIDIA CUDA | Yes | 8080 |
| Linux | vLLM | CPU | Yes | 8080 |
| Windows | WSL + vLLM | NVIDIA | Yes | 8080 |

**Why Ollama on macOS?**
- Official Mistral models use FP8 quantization
- vllm-metal uses mlx-vlm which doesn't support FP8
- Ollama's devstral-small-2 has native Metal support and working tool calling

## Supported Models

| Model | Parameters | Memory (Q4) | Context | Use Case |
|-------|------------|-------------|---------|----------|
| devstral-small-2 | 24B | ~15 GB | 384K | Vibe (Mistral native) |
| gpt-oss:20b | 20B MoE | ~14 GB | 128K | OpenCode (efficient tool calling) |
| devstral-2 | 123B | ~75 GB | 256K | Linux NVIDIA only |

**Note:** OpenCode requires 8k-64k context for tool calling to work. The default Ollama 4k context causes tools to fail with "invalid tool" errors.

## Commands

### Setup

```bash
scripts/setup.sh  # Auto-detect platform and install backend
```

Platform-specific:
```bash
scripts/setup_mac.sh    # macOS: Install Ollama + pull model
scripts/setup_linux.sh  # Linux: Install vLLM (CUDA or CPU)
scripts/setup_wsl.sh    # WSL: Install vLLM
```

### Server

```bash
scripts/server_start.sh  # Start with auto-detected config
scripts/server_stop.sh   # Stop server
```

**macOS (Ollama):**
```bash
# Default model: devstral-small-2
# Port: 11434
# API: http://127.0.0.1:11434/v1
```

**Linux (vLLM):**
```bash
# Override model:
DEVSTRAL_MODEL=mistralai/Devstral-Small-2-24B-Instruct-2512 scripts/server_start.sh

# Override port:
DEVSTRAL_PORT=9090 scripts/server_start.sh
```

### Vibe Integration

```bash
scripts/vibe_install.sh     # Install Vibe CLI
scripts/vibe_set_local.sh   # Configure Vibe to use local server
scripts/vibe_unset_local.sh # Restore original Vibe config
```

The script auto-configures based on platform:
- **macOS**: Provider `ollama`, port `11434`, model `devstral-small-2`
- **Linux**: Provider `local`, port `8080`, model `mistralai/Devstral-Small-2-24B-Instruct-2512`

### OpenCode Integration

```bash
scripts/opencode_install.sh     # Install OpenCode CLI
scripts/opencode_set_local.sh   # Configure OpenCode for local server (creates gpt-oss-20b-16k)
scripts/opencode_unset_local.sh # Restore original OpenCode config
```

OpenCode uses gpt-oss:20b with 16k context for efficient tool calling.

### Security (Optional)

```bash
scripts/security_harden.sh   # Block Vibe, OpenCode, Ollama network access
scripts/security_unharden.sh # Restore network access
```

**Important:** Pull all required models BEFORE hardening:
```bash
ollama pull devstral-small-2
ollama pull gpt-oss:20b
scripts/security_harden.sh
```

### Cleanup

```bash
scripts/teardown.sh  # Remove venv, caches, PID files
```

## Verify Server

**macOS (Ollama):**
```bash
curl -s http://127.0.0.1:11434/v1/models | python -m json.tool

curl -s http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"devstral-small-2","messages":[{"role":"user","content":"Hello"}]}' \
  | python -m json.tool
```

**Linux (vLLM):**
```bash
curl -s http://127.0.0.1:8080/v1/models | python -m json.tool

curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello"}]}' \
  | python -m json.tool
```

## Environment Variables

### Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVSTRAL_OLLAMA_MODEL` | devstral-small-2 | Ollama model (macOS) |
| `DEVSTRAL_MODEL` | auto | vLLM model ID (Linux) |
| `DEVSTRAL_MAX_MODEL_LEN` | auto | Context length (Linux) |
| `DEVSTRAL_HOST` | 127.0.0.1 | Bind address |
| `DEVSTRAL_PORT` | 8080 | Port (Linux only; macOS uses 11434) |

### Vibe Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_PATH` | ~/.vibe/config.toml | Config file path |
| `VIBE_LOCAL_MODEL_ID` | auto | Model ID in Vibe config |
| `VIBE_LOCAL_PROVIDER_NAME` | auto | Provider name (ollama on Mac, local on Linux) |
| `VIBE_LOCAL_API_BASE` | auto | API endpoint |

### OpenCode Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_CONFIG_PATH` | ~/.config/opencode/opencode.json | Config file path |
| `OPENCODE_LOCAL_MODEL_ID` | gpt-oss-20b-16k | Model ID (16k context for tool calling) |
| `OPENCODE_LOCAL_API_BASE` | http://localhost:11434/v1 | API endpoint |

## Architecture

```
scripts/
  _common.sh            # Shared utilities, hardware detection
  setup.sh              # Platform dispatcher
  setup_mac.sh          # macOS: Ollama + devstral-small-2
  setup_linux.sh        # Linux: vLLM (CUDA/CPU)
  setup_wsl.sh          # WSL setup
  detect_hardware.sh    # Show hardware and viable configs
  server_start.sh       # Start server (Ollama or vLLM)
  server_stop.sh        # Stop server
  teardown.sh           # Cleanup
  vibe_install.sh       # Install Vibe CLI
  vibe_set_local.sh     # Configure Vibe for local server
  vibe_unset_local.sh   # Restore Vibe config
  opencode_install.sh   # Install OpenCode CLI
  opencode_set_local.sh # Configure OpenCode for local server
  opencode_unset_local.sh # Restore OpenCode config
  security_harden.sh    # Network isolation (Vibe, OpenCode, Ollama)
  security_unharden.sh  # Restore network access

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
- **smoke-linux**: Real inference with Ministral 3B GGUF

## License

MIT
