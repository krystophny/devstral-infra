# CLAUDE.md

Guidance for Claude Code working inside this repository.

## What this repo is

One blessed local coding stack, nothing else:

- **Runtime**: `llama-server` from the latest upstream ggml-org/llama.cpp release.
- **Models**:
  - `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` at `Q4_K_M` — alias `qwen3.6-35b-a3b-q4`.
  - `bartowski/Qwen_Qwen3.6-27B-GGUF` at `Q4_K_M` — alias `qwen3.6-27b-q4` (macOS only).
- **Harness**: `opencode` CLI, title generation disabled, reasoning on.

macOS runs a dual-instance deployment — dense 27B on port `8081` (OpenCode
default) and MoE 35B-A3B on port `8080` (small_model, USB bundle port).
Linux/Windows and the USB bundles keep the single-instance 35B-A3B on port
`8080`. The launcher binds `0.0.0.0` by default so the host can also expose the
service on the LAN.

| OS      | Backend | Instances | Models served                   | User service        |
| ------- | ------- | --------- | ------------------------------- | ------------------- |
| Linux   | CUDA    | 1         | 35B-A3B `qwen` :8080            | `systemd --user`    |
| Windows | Vulkan  | 1         | 35B-A3B `qwen` :8080            | `schtasks ONLOGON`  |
| macOS   | Metal   | 2         | 27B `qwen-27b` :8081, 35B-A3B `qwen-35b-a3b` :8080 | launchd user agent |

No root or admin is required anywhere. The only automatic downloads are the two
GGUFs (one on non-Mac) and the two binaries.

## Repo map

```
scripts/
  _common.sh                    shared bash helpers (paths, platform detect, stop_pid)
  setup_llamacpp.sh             fetch latest upstream release, unpack to ~/.local/llama.cpp
  llamacpp_models.py            default + optional model aliases; prefetch/resolve
  server_start_llamacpp.sh      single-instance launcher (LAN-capable by default)
  server_stop_llamacpp.sh
  server_start_mac.sh           macOS dual-instance orchestrator (35B :8080 + 27B :8081)
  server_stop_mac.sh
  opencode_install.sh           curl|bash (online) or OPENCODE_OFFLINE_ARCHIVE (USB)
  opencode_set_llamacpp.sh      write ~/.config/opencode/opencode.json (dual on Mac, single on PC)
  build_bundle.sh               build USB-ready per-OS trees with embedded installers
  usb_format.sh                 exFAT format + skeleton (requires sudo, typed confirm)

ci/
  run_tests.sh                  runs the two suites below
  test_llamacpp_profile.sh      launcher dry-run + opencode config assertions
  test_server_health.sh         pure-stdlib mock server
  mock_server.py
```

## Flags that are load-bearing

Every instance launched through `server_start_llamacpp.sh` always passes:

```
-c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 \
-ngl 99 -fa on --alias "${LLAMACPP_SERVED_ALIAS:-qwen}" --jinja \
-np 2 --reasoning on
```

`-c 262144 -np 2` = 131072 tokens per slot (128K) — matches the model's
`n_ctx_train` so no YaRN scaling is involved.

Plus `--cpu-moe` on Linux and Windows (the local 16 GB VRAM box cannot hold the
Q4_K_M experts on GPU). On Mac unified memory makes `--cpu-moe` counterproductive,
so Metal holds everything.

Default deployment per platform:

| Host            | Instances                   | `--alias`                    | `-np` | Per-slot ctx |
| --------------- | --------------------------- | ---------------------------- | ----- | ------------ |
| Linux / Windows | 35B-A3B on :8080            | `qwen`                       | 2     | 131072       |
| macOS           | 35B-A3B on :8080, 27B on :8081 | `qwen-35b-a3b`, `qwen-27b` | 2 each | 131072       |

On Mac the 27B is a dense model so its KV cache per token is ~3× the MoE's
(64 layers / 4 KV heads vs 40 / 2). Per-slot 128K keeps the 27B's KV envelope
around 17 GiB; combined footprint for both instances is ~85 GiB on the 256 GB
box.

Override per invocation with `LLAMACPP_PARALLEL` and `LLAMACPP_CONTEXT`. The
Mac orchestrator also accepts these and forwards them to both instances.

## Don't reintroduce

Explicitly out of scope — do not add LM Studio, vLLM, vLLM-MLX, MLX-LM, oMLX,
Vibe, aider, qwen-code, Codex, SearXNG, BGE embeddings, extra local stacks,
`security_harden.sh`, dual-instance local/fast servers, or anything that auto-
downloads another model family beyond the small manual alias list in
`scripts/llamacpp_models.py`. If one of those becomes useful again, add it
deliberately and update this file.

## USB stick note

The USB layout ships the 20 GB GGUF once at the bundle root. Per-OS `start`
scripts reference `../models/…`. exFAT is required (FAT32 chokes at 4 GB per
file); `usb_format.sh` handles the format.

## Testing

`bash ci/run_tests.sh` must be green locally before any commit. Tests are
dry-run only — real inference costs too much to run in CI.
