# CLAUDE.md

Guidance for Claude Code working inside this repository.

## What this repo is

One blessed local coding stack, nothing else:

- **Runtime**: `llama-server` from the latest upstream ggml-org/llama.cpp release.
- **Model**: `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` at `Q4_K_M` — alias
  `qwen3.6-35b-a3b-q4`. The same model on every platform.
- **Harness**: `opencode` CLI, title generation disabled, reasoning on.
- **Optional load balancer**: `sloppy-org/slopgate` (fork of distantmagic/
  paddler v1.x) for multi-host deployments. See "Multi-host (slopgate)" below.

The launcher binds `0.0.0.0:8080` by default. When a slopgate balancer or
agent unit is locally installed, the launcher flips to `127.0.0.1:8081` so the
proxy can take `:8080`.

| OS      | Backend | Instances | Model + alias              | User service        |
| ------- | ------- | --------- | -------------------------- | ------------------- |
| Linux   | CUDA    | 1         | 35B-A3B `qwen` :8080       | `systemd --user`    |
| Windows | Vulkan  | 1         | 35B-A3B `qwen` :8080       | `schtasks ONLOGON`  |
| macOS   | Metal   | 1         | 35B-A3B `qwen` :8080       | launchd user agent  |

No root or admin is required anywhere. The only automatic downloads are the
single GGUF and the llama-server binary.

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
                                replaces the shell with llama-server for systemd.
                                Flips to 127.0.0.1:8081 when slopgate is locally
                                installed; LLAMACPP_BIND_LOOPBACK=true forces it
                                without slopgate detection (followers).
  server_stop_llamacpp.sh
  install_linux_systemd.sh      write & enable ~/.config/systemd/user/slopcode-
                                llamacpp.service; enable-linger for boot autostart
  install_mac_launchagents.sh   macOS launchd user agent (single 35B-A3B instance)
  install_slopgate_leader.sh    install slopgate balancer + co-located agent
                                (sources ~/.config/slopgate/leader.env)
  install_slopgate_follower.sh  install slopgate agent only (sources
                                ~/.config/slopgate/follower.env)
  opencode_install.sh           curl|bash (online) or OPENCODE_OFFLINE_ARCHIVE (USB)
  opencode_set_llamacpp.sh      write ~/.config/opencode/opencode.json. SLOPGATE_LEADER
                                points baseURL at the proxy + emits
                                X-Slopgate-Session header for sticky routing.
  build_bundle.sh               build USB-ready per-OS trees with embedded installers,
                                bundled Node.js LTS (linux-x64/darwin-arm64/win-x64),
                                and a fully populated offline npm cache for Pi
  usb_format.sh                 exFAT format + skeleton (requires sudo, typed confirm)

config/slopgate/
  leader.env.example            template for ~/.config/slopgate/leader.env
  follower.env.example          template for ~/.config/slopgate/follower.env

ci/
  run_tests.sh                  runs the three suites below
  test_llamacpp_profile.sh      launcher dry-run + opencode config assertions
  test_slopgate_profile.sh      install_slopgate_{leader,follower} dry-run +
                                gitignore behaviour
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

`-np`, `-ub`, and MoE placement are caller/platform-dependent. Linux/Windows
default to `-np 1 -ub 1024 --n-cpu-moe 35 -c 262144` (partial MoE offload,
5/40 routed-expert layers on GPU, small compute buffer to coexist with
whisper-server and Qwen3-TTS). Mac defaults to `-np 8 -ub 1024 -c 2097152`
(eight slots × 256K each, no MoE split — Metal handles experts in unified
memory). The 27B dense companion that previously occupied the Mac's second
port is gone; the freed unified-memory budget pays for the eight-slot config.
Per-slot context lands at the model's native `n_ctx_train` (262144) on every
platform, so no YaRN scaling is involved.

Why eight slots on the Mac and not four: Qwen3.6-35B-A3B is a hybrid
architecture (10/40 layers carry full-attention KV, the other 30 are Gated
DeltaNet linear-attention with a constant ~250 MiB recurrent state). At
q8_0 KV that puts each 256K slot at ~2.5 GiB of cache. Eight slots
fit comfortably (~20 GiB KV + 21 GiB Q4_K_M weights + 2 GiB mmproj +
~3 GiB compute = ~46 GiB out of 256 GiB unified memory, leaving ~180 GiB
for whisper / Qwen3-TTS / other apps). The bandwidth-saturated decode
ceiling on M3 Ultra is around 8 concurrent streams; per-slot decode
falls from ~77 t/s (single user, measured) to ~55-65 t/s only when 5+
slots are actually busy at the same time. Slopgate's `--overbook-factor 1.5`
on top advertises 12 logical slots, deep enough to absorb burst admissions
without ever overshooting the physical 1-request-per-slot llama-server
invariant.

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

| Host            | Instances        | `--alias` | `-np` | `-c`     | Per-slot ctx |
| --------------- | ---------------- | --------- | ----- | -------- | ------------ |
| Linux / Windows | 35B-A3B on :8080 | `qwen`    | 1     | 262144   | 262144       |
| macOS           | 35B-A3B on :8080 | `qwen`    | 8     | 2097152  | 262144       |

Every slot on every platform gets 256K — exactly the model's native
`n_ctx_train`. Linux/Windows run one slot because a single local user rarely
needs two concurrent decode streams and halving the window made opencode
auto-compaction fire at ~79K conversation tokens instead of ~210K. With
`-np 1` compaction still blocks the only slot for the duration of the summary
call, but the user gets ~2.6× more working context before that happens and
the session always recovers. macOS runs eight slots because the M3 Ultra has
unified memory to spare and Qwen3-Next's hybrid attention puts the per-slot
KV at only ~2.5 GiB at 256K (q8) — combined opencode + student traffic
through the slopgate proxy benefits from concurrent decode streams.

Override per invocation with `LLAMACPP_PARALLEL` and `LLAMACPP_CONTEXT`.

## Multi-host (slopgate)

For deployments spanning more than one box, `sloppy-org/slopgate` (a private
fork of `distantmagic/paddler` v1.2.1-rc1, MIT-licensed) is a slot-aware
reverse proxy that fronts every node's `llama-server` on a single port.

**Topology.** A leader runs `slopgate balancer` on `0.0.0.0:8080` and a
co-located `slopgate agent`. Each follower runs `slopgate agent` only,
registering its local `llama-server` with the leader's management endpoint
over a private network (WireGuard or LAN). When followers go offline they
drop out of rotation; when they come back they re-register on the next
heartbeat.

**Routing.** Power-of-Two-Choices over the free-slot count, filtered by
KV-cache headroom so a long-context request never lands on a slot that can't
fit it. Optional sticky session affinity via the `X-Slopgate-Session` header
(opencode emits this automatically when `SLOPGATE_LEADER` is configured).

**Configuration.** Per-host capability data and topology live in env files
outside the repo:
- `~/.config/slopgate/leader.env` — leader balancer + local agent
- `~/.config/slopgate/follower.env` — follower agent

Templates at `config/slopgate/{leader,follower}.env.example`. Real env files
are gitignored. Concrete IPs and hostnames never leak into commits, PR
descriptions, or issue bodies.

**Install.** From the leader: `bash scripts/install_slopgate_leader.sh`.
From each follower: `bash scripts/install_slopgate_follower.sh`. Both
scripts link `~/.local/bin/slopgate` to the cargo build at
`~/code/sloppy/slopgate/target/release/slopgate` and write systemd user
units (Linux) or launchd user agents (macOS). No sudo.

**opencode integration.** Set `SLOPGATE_LEADER=<wg-ip>:8080` (or just
`<wg-ip>`) when running `scripts/opencode_set_llamacpp.sh`; baseURL becomes
`http://<wg-ip>:8080/v1` and a stable `X-Slopgate-Session` header is added
for sticky multi-turn routing.

## Whisper transcription server

`whisper.cpp` runs alongside llama-server on the same box, exposing an
OpenAI-compatible STT endpoint at `http://0.0.0.0:8427/v1/audio/transcriptions`.

| Host  | Backend | Model                       | Port | Path                              | Daemon                      |
| ----- | ------- | --------------------------- | ---- | --------------------------------- | --------------------------- |
| macOS | Metal   | `ggml-large-v3-turbo.bin`   | 8427 | `/v1/audio/transcriptions`        | `com.slopcode.whisper-server` |
| Linux | CUDA    | `ggml-large-v3-turbo.bin`   | 8427 | `/v1/audio/transcriptions`        | (systemd unit, future)      |

Every instance launched through `server_start_whisper.sh` always passes:

```
-l auto -fa --inference-path /v1/audio/transcriptions --convert
```

`-l auto` means whisper auto-detects the spoken language (the default `en`
silently produces nonsense on German voice memos). `-fa` enables flash
attention (default-on; explicit so it survives upstream changes). `--convert`
lets clients upload arbitrary container formats (m4a, mp3, mp4) and the server
reaches for ffmpeg to decode — required because iOS Voice Memos are AAC-in-m4a.
GPU usage is on by default; the binary is built with `-DGGML_METAL=1` on Mac,
`-DGGML_CUDA=1` on Linux/NVIDIA, `-DGGML_VULKAN=1` on other GPUs. CPU-only
falls through `setup_whisper.sh`'s safety check unless `WHISPER_ALLOW_CPU=1`
is set.

Clients in this stack:
- `voxtype` macOS push-to-talk (`feature/macos-release`) with
  `--remote-endpoint http://127.0.0.1:8427`
- `~/Nextcloud/plasma/DOCUMENTS/MEETINGS/tools/transcribe-memo`
- `slopbox` voice-memo classifier (uses the first ~60s of audio for the
  is-meeting decision, then hands off to `process-memo` for the full transcribe)

Override with `WHISPER_HOME`, `WHISPER_PORT`, `WHISPER_LANGUAGE`,
`WHISPER_THREADS`, `WHISPER_MODEL`. Foreground-mode for launchd ExecStart with
`WHISPER_EXEC=true` (mirrors `LLAMACPP_EXEC=true`).

## Don't reintroduce

Explicitly out of scope — do not add LM Studio, vLLM, vLLM-MLX, MLX-LM, oMLX,
`security_harden.sh`, dual-instance local/fast servers, the macOS Qwen 27B
dense companion as a default-installed model, intentee/paddler v2+ (the
embedded-llama.cpp rewrite — slopgate stays on the v1.x transparent-proxy
line so we keep control of llama-server flags), or anything that auto-
downloads another model family beyond the small manual alias list in
`scripts/llamacpp_models.py`. If one of those becomes useful again, add it
deliberately and update this file.

## USB stick note

The USB layout ships the 20 GB GGUF once at the bundle root. Per-OS `start`
scripts reference `../models/…`. exFAT is required (FAT32 chokes at 4 GB per
file); `usb_format.sh` handles the format.

Each per-OS directory also carries its own Node.js LTS under `node/`
(linux-x64, darwin-arm64, win-x64). The shared `pi/` directory holds the
Pi tarball and a fully populated offline npm cache. The per-OS installer
copies its `node/` into the install destination, runs `npm install -g`
with `--prefix <dest>/node --offline --cache <bundle>/pi/npm-cache`, and
exposes Pi as `~/.local/bin/pi` (Unix) or via a user-PATH prepend
(Windows). No system Node, no sudo, no admin, no internet at install
time. Outside the USB path, `scripts/pi_install.sh` keeps using the
system npm — unchanged.

The Node.js version is auto-resolved to the latest LTS via
`https://nodejs.org/dist/index.json` at build time; override with
`NODE_VERSION=v22.x.x scripts/build_bundle.sh ...`.

## Testing

`bash ci/run_tests.sh` must be green locally before any commit. Tests are
dry-run only — real inference costs too much to run in CI.
