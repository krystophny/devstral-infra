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

The Linux service is installed by `scripts/install_linux_systemd.sh`: it writes
`~/.config/systemd/user/slopcode-llamacpp.service`, whose ExecStart invokes
`server_start_llamacpp.sh` with `LLAMACPP_EXEC=true` so llama-server runs in
the foreground under systemd. The installer runs `loginctl enable-linger`
(no sudo in the common case) so the service survives logout and starts at
boot. Re-run the installer any time the launcher changes — the unit only
references the launcher path, so nothing else has to be regenerated.

On Linux with an NVIDIA GPU and the CUDA toolkit present (`nvcc`, `cmake`,
`ninja`, `git` on PATH), `setup_llamacpp.sh` builds llama.cpp from source at
the matching release tag with `-DGGML_CUDA=ON` instead of downloading the
Vulkan release. Rationale: upstream ggml-org only ships CUDA binaries for
Windows, and the portable Vulkan release underperforms on NVIDIA hardware
badly enough that the inter-token stalls trigger `ECONNRESET` in the opencode
client mid-stream. Set `LLAMACPP_BACKEND=prebuilt` to force the Vulkan path
on a box that has the toolkit but shouldn't build from source.

## Telemetry lockdown

All three install paths pin the following user-level environment variables
(HKCU on Windows, `~/.profile` + `environment.d` on Linux/macOS) so opencode
makes no outbound call beyond the configured LLM endpoint:

| Var                                | Blocks                                    |
| ---------------------------------- | ----------------------------------------- |
| `OPENCODE_DISABLE_AUTOUPDATE=1`    | GitHub release / brew / choco version probes |
| `OPENCODE_DISABLE_SHARE=1`         | session upload to opencode.ai              |
| `OPENCODE_DISABLE_MODELS_FETCH=1`  | `https://models.dev/api.json`              |
| `OPENCODE_DISABLE_LSP_DOWNLOAD=1`  | clangd/texlab/zls autofetch from GitHub    |
| `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` | built-in github-copilot / llmgateway probes |
| `OPENCODE_DISABLE_EMBEDDED_WEB_UI=1` | bundled web-ui code path                  |

`opencode.json` on every platform also sets `share: "disabled"`,
`autoupdate: false`, `tools.websearch: false`, `experimental.openTelemetry: false`,
and extends `disabled_providers` with `opencode`, `llmgateway`, `github-copilot`,
`copilot` alongside the already-excluded cloud providers.

All of this is idempotent: re-running `install.sh` / `install.bat` rewrites
in place. No admin or sudo required. Upstream still has open feature requests
for a first-class air-gapped mode (ggml-org/opencode issues #16117 / #18492),
so if a future release introduces a new phone-home path this list has to be
revisited.

## Repo map

```
scripts/
  _common.sh                    shared bash helpers (paths, platform detect, stop_pid)
  setup_llamacpp.sh             prebuilt download (default), or CUDA source build on Linux+NVIDIA
  opencode_privacy.sh           pin OPENCODE_DISABLE_* env vars in ~/.profile + environment.d (idempotent)
  llamacpp_models.py            default + optional model aliases; prefetch/resolve
  server_start_llamacpp.sh      single-instance launcher; LLAMACPP_EXEC=true
                                replaces the shell with llama-server for systemd
  server_stop_llamacpp.sh
  server_start_mac.sh           macOS dual-instance orchestrator (35B :8080 + 27B :8081)
  server_stop_mac.sh
  install_linux_systemd.sh      write & enable ~/.config/systemd/user/slopcode-
                                llamacpp.service; enable-linger for boot autostart
  install_mac_launchagents.sh   macOS launchd user agents for the dual-instance stack
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
--cache-type-k q8_0 --cache-type-v q8_0 -b 2048 \
-ngl 99 -fa on --alias "${LLAMACPP_SERVED_ALIAS:-qwen}" --jinja \
--reasoning on
```

`-np`, `-ub`, and MoE placement are caller/platform-dependent. The launcher
defaults to `-np 1 -ub 1024 --n-cpu-moe 35` (partial MoE offload, 5/40
routed-expert layers on GPU, small enough compute buffer to coexist with
whisper-server and Qwen3-TTS). The Mac orchestrator passes
`LLAMACPP_PARALLEL=2` and no MoE split. Per-slot context lands at the
model's native `n_ctx_train` (262144) on every platform, so no YaRN
scaling is involved.

On Linux/Windows partial MoE offload replaces the old blanket `--cpu-moe`.
Benchmark on RTX 5060 Ti 16 GB with Qwen3.6-35B-A3B Q4_K_M at c=262144:

| Config                                 | llama  | Prefill | Decode | Stack peak | Free |
| -------------------------------------- | ------ | ------- | ------ | ---------- | ---- |
| `--cpu-moe -ub 512` (old baseline)     | ~5.3G  | ~300    | 33.0   | n/a        | n/a  |
| `--n-cpu-moe 30 -ub 1024`              | 11.0G  | 647     | 39.7   | TTS OOM    | —    |
| `--n-cpu-moe 33 -ub 1024`              | 9.65G  | 594     | 38.6   | 15.6G      | 0.2G |
| `--n-cpu-moe 35 -ub 1024` (default)    | 8.72G  | 569     | 37.0   | 14.6G      | 1.3G |
| `--n-cpu-moe 35 -ub 512`               | 7.94G  | 335     | 37.0   | 13.8G      | 2.0G |
| `--n-cpu-moe 25 -ub 1024`              | 13.3G  | 748     | 44.1   | TTS OOM    | —    |

"Stack peak" is llama + whisper-server (~0.9 G) + Qwen3-TTS loaded and
synthesising (~4.4 G peak). The chosen default delivers 1.9x prefill and
1.12x decode vs the old all-CPU-moe baseline while leaving ~1.3 G free
for OS pressure and further GPU callers. Raising to `--n-cpu-moe 33`
gains ~4 % prefill and decode but shrinks the free margin to 0.2 GB —
one TTS spike away from OOM. `LLAMACPP_CPU_MOE=true` remains as an
emergency escape hatch that forces `--n-cpu-moe 99` (all experts on
CPU) for even more crowded GPUs.

Linux and Windows also pass `--threads <physical_cores - 2> --threads-http 4`
(clamped to a minimum of 2). Rationale: MoE decode on Qwen3-Next is
memory-bandwidth-bound and by default llama-server grabs every core. That
starves the rest of userspace — Claude Code's HTTP/2 keepalive and opencode's
Bun HTTP pool both miss their scheduling windows long enough for the server
side to send idle-timeout RSTs. Reserving 2 physical cores for the host
eliminates the host-side stall. Mac is untouched (Metal schedules on its
own, user sees no stalls in unified-memory mode); defaults can be overridden
per invocation via `LLAMACPP_THREADS` / `LLAMACPP_THREADS_HTTP`.

Default deployment per platform:

| Host            | Instances                        | `--alias`                    | `-np` | `-c`   | Per-slot ctx |
| --------------- | -------------------------------- | ---------------------------- | ----- | ------ | ------------ |
| Linux / Windows | 35B-A3B on :8080                 | `qwen`                       | 1     | 262144 | 262144       |
| macOS           | 35B-A3B on :8080, 27B on :8081   | `qwen-35b-a3b`, `qwen-27b`   | 2 ea. | 524288 | 262144       |

Every slot on every platform gets 256K — exactly the model's native
`n_ctx_train`. Linux/Windows run one slot because a single local user rarely
needs two concurrent decode streams and halving the window made opencode
auto-compaction fire at ~79K conversation tokens instead of ~210K (compaction
triggers at `context - 32K output - 20K buffer`). With `-np 1` compaction
still blocks the only slot for the duration of the summary call, but the user
gets ~2.6× more working context before that happens and the session always
recovers. On Mac the dense 27B's KV cache per token is ~3× the MoE's (64
layers / 4 KV heads vs 40 / 2): at 256K per slot the 27B's KV envelope is
~68 GiB, and combined footprint for both instances is ~130 GiB on the 256 GB
box.

Override per invocation with `LLAMACPP_PARALLEL` and `LLAMACPP_CONTEXT`. The
Mac orchestrator also accepts these and forwards them to both instances.

## Don't reintroduce

Explicitly out of scope — do not add LM Studio, vLLM, vLLM-MLX, MLX-LM, oMLX,
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
