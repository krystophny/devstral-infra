# devstral-infra

Cross-platform local inference server for Devstral models using vLLM.

- **Auto-detection**: Automatically selects optimal model, quantization, and context based on hardware
- **Cross-platform**: macOS (Apple Silicon), Linux (NVIDIA/CPU), Windows (WSL)
- **Vibe integration**: Configure Vibe to use your local server
- **Security hardening**: Optional network isolation for Vibe

## Quick Start

```bash
chmod +x scripts/*.sh
scripts/setup.sh           # Install vLLM (auto-detects platform)
scripts/detect_hardware.sh # Show recommended configs
scripts/server_start.sh    # Start server
```

## Supported Hardware

| Platform | GPU | Minimum Memory | Models |
|----------|-----|----------------|--------|
| Mac (Apple Silicon) | Metal | 16 GB unified | 24B, 123B |
| Linux | NVIDIA CUDA | 12 GB VRAM | 24B, 123B |
| Linux | CPU-only | 24 GB RAM | 24B (slow) |
| Windows | WSL2 + NVIDIA | 12 GB VRAM | 24B, 123B |

## Hardware Auto-Detection

The scripts automatically detect your hardware and select the best configuration.

Run `scripts/detect_hardware.sh` to see all viable options:

```
=== Hardware Detection ===
platform: mac
gpu: metal
vram_mb: 192000
ram_mb: 256000

=== Viable Configurations ===
[1] Devstral 2 123B Q4, full 262K context
    model: mistralai/Devstral-2-123B-Instruct-2512
    quantization: Q4_K_M
    max_context: 262144 tokens

[2] Devstral 2 123B Q4, 131K context
    ...

=== Auto-Selected Configuration ===
Devstral 2 123B Q4, full 262K context
```

### Memory Requirements (Q4 quantization)

**Devstral 2 123B:**
| Context | Memory Required |
|---------|-----------------|
| 8K | ~82 GB |
| 32K | ~90 GB |
| 131K | ~123 GB |
| 262K | ~170 GB |

**Devstral Small 24B:**
| Context | Memory Required |
|---------|-----------------|
| 8K | ~16 GB |
| 32K | ~20 GB |
| 57K | ~24 GB |
| 131K | ~35 GB |
| 262K | ~55 GB |

## Commands

### Setup

```bash
scripts/setup.sh  # Auto-detect platform and install vLLM
```

Platform-specific:
```bash
scripts/setup_mac.sh    # macOS with vllm-metal
scripts/setup_linux.sh  # Linux with vLLM (CUDA or CPU)
scripts/setup_wsl.sh    # WSL with vLLM
```

### Server

```bash
scripts/server_start.sh  # Start with auto-detected config
scripts/server_stop.sh   # Stop server
```

Override defaults:
```bash
DEVSTRAL_PORT=9090 scripts/server_start.sh
DEVSTRAL_MODEL=mistralai/Devstral-Small-2-24B-Instruct-2512 scripts/server_start.sh
DEVSTRAL_MAX_MODEL_LEN=32768 scripts/server_start.sh
```

### Vibe Integration

```bash
scripts/vibe_install.sh     # Install Vibe CLI
scripts/vibe_set_local.sh   # Configure Vibe to use local server
scripts/vibe_unset_local.sh # Restore original Vibe config
```

### Security (Optional)

```bash
scripts/security_harden.sh   # Block Vibe network access (requires sudo)
scripts/security_unharden.sh # Restore Vibe network access
```

### Cleanup

```bash
scripts/teardown.sh  # Remove venv, caches, PID files
```

## Environment Variables

### Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVSTRAL_MODEL` | auto | Model ID |
| `DEVSTRAL_MODEL_SIZE` | auto | `small` (24B) or `full` (123B) |
| `DEVSTRAL_MAX_MODEL_LEN` | auto | Context length |
| `DEVSTRAL_HOST` | 127.0.0.1 | Bind address |
| `DEVSTRAL_PORT` | 8080 | Port |

### Vibe Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `VIBE_CONFIG_PATH` | ~/.vibe/config.toml | Config file path |
| `VIBE_LOCAL_MODEL_ID` | auto | Model ID in Vibe config |
| `VIBE_LOCAL_PROVIDER_NAME` | local | Provider name |
| `VIBE_LOCAL_API_BASE` | http://127.0.0.1:8080/v1 | API endpoint |

## Verify Server

```bash
curl -s http://127.0.0.1:8080/v1/models | python -m json.tool

curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello"}]}' \
  | python -m json.tool
```

## Architecture

```
scripts/
  _common.sh          # Shared utilities, hardware detection
  setup.sh            # Platform dispatcher
  setup_mac.sh        # macOS setup (vllm-metal)
  setup_linux.sh      # Linux setup (vLLM CUDA/CPU)
  setup_wsl.sh        # WSL setup
  detect_hardware.sh  # Show hardware and viable configs
  server_start.sh     # Start vLLM server
  server_stop.sh      # Stop server
  teardown.sh         # Cleanup
  vibe_install.sh     # Install Vibe CLI
  vibe_set_local.sh   # Configure Vibe for local server
  vibe_unset_local.sh # Restore Vibe config
  security_harden.sh  # Network isolation (macOS firewall / Linux iptables)
  security_unharden.sh

server/
  run_devstral_server.py  # vLLM launcher

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
