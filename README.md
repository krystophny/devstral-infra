# devstral-infra

Cross-platform local inference server for coding AI models.

License: [MIT](LICENSE)

> **Disclaimer**: This is experimental, vibe-coded infrastructure. No warranty
> of any kind. Use at your own risk. Not affiliated with Mistral AI.

- **Auto-detection**: Automatically selects optimal model and configuration based on hardware
- **Cross-platform**: macOS (llama.cpp, mlx-lm, vllm-mlx, vllm-metal, oMLX), Linux (vLLM + CUDA/CPU), Windows (WSL)
- **Tool calling**: Full tool use support for coding assistants
- **Vibe integration**: Configure Mistral Vibe CLI to use your local server
- **OpenCode integration**: Configure OpenCode CLI for efficient tool calling
- **llama.cpp local benchmark profile**: Uses a real local build from upstream `llama.cpp` `master`, standardizes Qwen on `Q8_0`, and supports official `GPT-OSS` `MXFP4`
- **Security hardening**: Optional network isolation for Vibe, OpenCode, and LM Studio

## Quick Start

```bash
chmod +x scripts/*.sh ci/*.sh ci/*.py
scripts/server_start_llamacpp.sh  # Start local llama.cpp benchmark server on port 8080
scripts/server_start_mlx_lm.sh    # Start direct mlx-lm HTTP server
scripts/server_start_vllm_mlx.sh  # Start vllm-mlx on Apple Silicon
scripts/server_start_vllm_metal.sh  # Start vllm-metal
scripts/server_start_omlx.sh      # Start oMLX
scripts/benchmark_local_stacks.sh # Benchmark all local Mac stacks against the same Qwen 9B 4-bit weights
```

### BGE-M3 Embeddings with llama.cpp

```bash
LLAMACPP_EMBEDDING_MODEL=/home/user/.local/share/local-llm/models/bge-m3.gguf \
LLAMACPP_EMBEDDING_PORT=11434 \
LLAMACPP_EMBEDDING_ALIAS=bge-m3 \
scripts/server_start_bge_llamacpp.sh
```

```bash
scripts/server_stop_bge_llamacpp.sh
```

This keeps the same API port (`11434`) while switching the embedding backend from Ollama to llama.cpp.

## Platform Backends

| Platform | Backend | GPU | Tool Calling | Port |
|----------|---------|-----|--------------|------|
| macOS (Apple Silicon) | llama.cpp | Metal | Yes | 8080 |
| macOS (Apple Silicon) | mlx-lm | MLX | Yes | 8080 |
| macOS (Apple Silicon) | vllm-mlx | MLX | Yes | 8080 |
| macOS (Apple Silicon) | vllm-metal | Metal | Yes | 8080 |
| macOS (Apple Silicon) | oMLX | MLX | Yes | 8000 |
| Linux | vLLM | NVIDIA CUDA | Yes | 8080 |
| Windows | WSL + LM Studio | NVIDIA | Yes | 1234 |

## Supported Models

| Model | Parameters | Memory (4-bit) | Context | Use Case |
|-------|------------|----------------|---------|----------|
| devstral-small-2 | 24B | ~15 GB | 32K | Vibe, OpenCode |
| GLM-4.7-REAP-50 | 47B | ~30 GB | 32K | OpenCode (reasoning) |
| Qwen3.5-122B-A10B Q8_0 | 122B A10B | ~131 GB GGUF + runtime buffers | 256K | OpenCode local llama.cpp |
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
scripts/opencode_set_vllm_mlx.sh  # Configure OpenCode for local vllm-mlx
scripts/opencode_set_omlx.sh      # Configure OpenCode for local oMLX
scripts/opencode_unset_local.sh   # Restore original OpenCode config
scripts/benchmark_local_stacks.sh # Run the local Mac benchmark harness
```

### llama.cpp Local Benchmark Profile

```bash
scripts/setup_llamacpp.sh
scripts/server_start_llamacpp.sh
scripts/opencode_set_llamacpp.sh
```

Recommended local profile:
- default OpenCode model: `Qwen3.5-9B`
- default OpenCode llama.cpp endpoint: `http://127.0.0.1:8081/v1`
- supported local Qwen family: `0.8B`, `2B`, `4B`, `9B`, `27B`, `35B-A3B`, `122B-A10B`
- supported local GPT-OSS family: `20B` `MXFP4`, `120B` `MXFP4`
- context: `65536`
- context checkpoints: `64`
- checkpoint interval: `4096`
- batch / ubatch: `2048 / 512`
- thinking: `on` by default for the OpenCode fast profile
- WebUI: enabled by default on the llama.cpp server
- clients that need a fast non-thinking turn should disable thinking per request instead of forcing the server off globally
- OpenCode sampling defaults for precise coding: `temperature=0.6`, `top_p=0.95`, `top_k=20`, `min_p=0.0`, `presence_penalty=0.0`, `repeat_penalty=1.0`
- OpenCode permissions: `allow` by default for the generated local profile
- launcher: `launchd` user agent on macOS, `systemd --user` on Linux
- readiness gate: waits for `/v1/models`, not just `/health`
- startup now runs a real `POST /v1/chat/completions` smoke test and fails fast if inference is broken
- verify the actual `llama-server` binary version before drawing conclusions; stale local builds were a major source of earlier confusion
- by default the launcher prefers `/Users/user/code/llama.cpp-dev/llama.cpp/build/bin/llama-server` when that real local build exists
- normalized local cache root: `~/Library/Caches/llama.cpp/`
- use `scripts/llamacpp_prefetch_models.sh --mode benchmark` to prefetch the active benchmark set
- use `scripts/llamacpp_model_inventory.sh --json` to inspect exact resolved paths
- use `LLAMACPP_MODEL_ALIAS=<alias>` to switch benchmark models without changing scripts

Environment overrides:
- `LLAMACPP_SERVER_BIN`
- `LLAMACPP_MODEL` or `LLAMACPP_HF_MODEL`
- `LLAMACPP_CONTEXT`
- `LLAMACPP_CTX_CHECKPOINTS`
- `LLAMACPP_CHECKPOINT_EVERY_N_TOKENS`
- `LLAMACPP_BATCH`
- `LLAMACPP_UBATCH`
- `LLAMACPP_ENABLE_THINKING`
- `LLAMACPP_SMOKE_TEST`
- `LLAMACPP_LAUNCHER`

### Local Stack Benchmark Suite

```bash
scripts/benchmark_local_stacks.sh
```

What it does:
- benchmarks the same local `Qwen3.5-9B` `Q4_K_M` `GGUF` and `Qwen3.5-9B-4bit` `MLX` weights across `llama.cpp`, `mlx-lm`, `vllm-mlx`, `vllm-metal`, and `oMLX`
- measures `TTFT`, prompt-side throughput, decode-side throughput, `TPOT`, end-to-end latency, and parallel request throughput
- writes `summary.md`, `summary.csv`, `raw.csv`, `parallel.csv`, `summary.json`, `raw.json`, `parallel.json`, and `failures.json`

Defaults:
- iterations: `2`
- max generation tokens: `128`
- parallel requests: `4`
- output dir: `/tmp/devstral-infra-benchmarks/local-stacks-<timestamp>`

Useful overrides:
- `OUTPUT_DIR=/path/to/output`
- `scripts/benchmark_local_stacks.sh --iterations 1 --max-tokens 64`
- `scripts/benchmark_local_stacks.sh --parallel-requests 8`
- `scripts/benchmark_local_stacks.sh --stacks llamacpp mlx-lm vllm-mlx`

Latest snapshot:
- date: `2026-04-07`
- machine: Apple Silicon Mac with `32 GB` RAM and `24 GB` VRAM
- `llama.cpp`: upstream `ggml-org/llama.cpp` `master`, commit `15f786e65`, built locally at `/Users/user/code/llama.cpp-dev/llama.cpp/build/bin/llama-server`
- command: `scripts/benchmark_local_stacks.sh --iterations 1 --max-tokens 32 --parallel-requests 2 --long-prompt-repeats 32 --stacks llamacpp mlx-lm vllm-mlx vllm-metal omlx`

```text
+------------+-----------+-------------------+------------------+------------------+
| stack      | short ms  | decode tok/s      | long ms          | parallel req/s   |
+------------+-----------+-------------------+------------------+------------------+
| llama.cpp  | TTFT 394  | 19.05             | TTFT 6227        | 0.48             |
| mlx-lm     | TTFT 438  | 33.01             | TTFT 10116       | 0.76             |
| vllm-mlx   | TTFT 659  | 5.18              | TTFT 9507        | 0.59             |
| vllm-metal | TTFT 1590 | buffered response | TTFT 10256       | 0.63             |
| oMLX       | TTFT 772  | 5.21              | TTFT 9669        | 0.55             |
+------------+-----------+-------------------+------------------+------------------+
```

Notes:
- `mlx-lm` remains the strongest overall result on this machine for Qwen3.5-9B 4bit MLX.
- `vllm-mlx` is now benchmarked in simple mode for single-user comparability, but its decode path is still much slower than `mlx-lm` direct here.
- `vllm-metal` exposed an OpenAI-compatible endpoint, but this benchmark path observed buffered completions rather than token streaming.
- `oMLX` now stays up in the background and serves real `/v1/chat/completions` requests against the same MLX Qwen snapshot.

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
