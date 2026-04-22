# CLAUDE.md

Guidance for Claude Code working inside this repository.

## What this repo is

One blessed local coding stack, nothing else:

- **Runtime**: `llama-server` from the latest upstream ggml-org/llama.cpp release.
- **Model**: `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` at `Q4_K_M`, alias `qwen3.6-35b-a3b-q4`.
- **Harness**: `opencode` CLI, title generation disabled, reasoning on.

All three target OSes run the same server on `127.0.0.1:8080`:

| OS      | Backend | CPU-MoE | User service          |
| ------- | ------- | ------- | --------------------- |
| Linux   | CUDA    | on      | `systemd --user`      |
| Windows | Vulkan  | on      | `schtasks ONLOGON`    |
| macOS   | Metal   | off     | launchd user agent    |

No root or admin is required anywhere. The only automatic download is the one
GGUF and the two binaries.

## Repo map

```
scripts/
  _common.sh                    shared bash helpers (paths, platform detect, stop_pid)
  setup_llamacpp.sh             fetch latest upstream release, unpack to ~/.local/llama.cpp
  llamacpp_models.py            one default model + optional aliases; prefetch/resolve
  server_start_llamacpp.sh      single-instance launcher (port 8080, Q8 KV, 128K ctx)
  server_stop_llamacpp.sh
  opencode_install.sh           curl|bash (online) or OPENCODE_OFFLINE_ARCHIVE (USB)
  opencode_set_llamacpp.sh      write ~/.config/opencode/opencode.json
  build_bundle.sh               build USB-ready per-OS trees with embedded installers
  usb_format.sh                 exFAT format + skeleton (requires sudo, typed confirm)

ci/
  run_tests.sh                  runs the two suites below
  test_llamacpp_profile.sh      launcher dry-run + opencode config assertions
  test_server_health.sh         pure-stdlib mock server
  mock_server.py
```

## Flags that are load-bearing

The launcher always passes:

```
-c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 \
-ngl 99 -fa on --alias qwen --jinja --reasoning on
```

Plus `--cpu-moe` on Linux and Windows (the local 16 GB VRAM box cannot hold the
Q4_K_M experts on GPU; the M1's unified memory makes CPU-MoE counterproductive).

## Don't reintroduce

Explicitly out of scope — do not add LM Studio, vLLM, vLLM-MLX, MLX-LM, oMLX,
Vibe, aider, qwen-code, Codex, SearXNG, BGE embeddings, benchmarking harnesses,
`security_harden.sh`, dual-instance local/fast servers, or anything that auto-
downloads a second model. If one of those becomes useful again, add it
deliberately and update this file.

## USB stick note

The USB layout ships the 20 GB GGUF once at the bundle root. Per-OS `start`
scripts reference `../models/…`. exFAT is required (FAT32 chokes at 4 GB per
file); `usb_format.sh` handles the format.

## Testing

`bash ci/run_tests.sh` must be green locally before any commit. Tests are
dry-run only — real inference costs too much to run in CI.
