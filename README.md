# slopcode-infra

Single-path local coding stack: **llama.cpp + Qwen3.6 35B A3B (Q4_K_M) + OpenCode + Pi**,
packaged so a USB stick hands it to a Linux, macOS, or Windows machine with no
root, no admin, and no internet.

License: [MIT](LICENSE)

## The one blessed configuration

| Target           | OS      | GPU          | Memory         | Backend | CPU-MoE |
| ---------------- | ------- | ------------ | -------------- | ------- | ------- |
| Local (this box) | Linux   | NVIDIA 16 GB | 96 GB          | CUDA    | on      |
| Intel Arc box    | Windows | Intel Arc    | 32 GB shared   | Vulkan  | on      |
| Apple M1         | macOS   | M1           | 32 GB unified  | Metal   | off     |

- **Model**: `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` at `Q4_K_M` (~20 GB), served as `qwen`.
- **Runtime**: `llama-server` (upstream release, Q8_0 KV, 128 K context, `-fa on`, `--jinja`).
- **Harnesses**: `opencode` and Pi, title generation disabled for OpenCode, local llama.cpp provider, telemetry disabled, `reasoning: true`, server-enforced thinking budget (`4096` by default).

Nothing else is downloaded automatically. Optional aliases live in
`scripts/llamacpp_models.py` for manual prefetch only, including the FortBench
MiniMax benchmark profiles.

## Install from a USB stick

```
./<target>/install.sh          # linux-cuda or mac-m1
.\windows-arc\install.bat      # windows-arc (no admin)
```

The installer copies `llama.cpp/`, `opencode/`, and the model into the user
profile (`~/.local/slopcode` on Linux, `~/Library/Application Support/slopcode`
on macOS, `%USERPROFILE%\slopcode` on Windows), registers a user-level service
(`systemd --user` unit `slopcode-llamacpp`, a `launchd` user agent
`com.slopcode.llamacpp-macbook`, or a Startup-folder shortcut on Windows), and
writes the OpenCode + Pi configs. OpenCode points at `http://127.0.0.1:8080/v1`,
and the local launcher binds `0.0.0.0:8080` by default so the service is
reachable on the LAN as well. The Mac Studio dual-instance layout (35B-A3B on
`:8080` plus the 27B dense companion on `:8081`) is set up directly from this
repo via `scripts/install_mac_launchagents.sh` and is intentionally not part of
the USB bundle.

## Install from this repo (local development)

```
scripts/setup_llamacpp.sh                     # fetch latest upstream release for this OS
python3 scripts/llamacpp_models.py prefetch   # download the blessed model
scripts/server_start_llamacpp.sh              # foreground run, smoke test
scripts/opencode_install.sh                   # curl|bash the opencode CLI
scripts/pi_install.sh                         # npm install Pi Coding Agent + local config
scripts/opencode_set_llamacpp.sh              # write ~/.config/opencode/opencode.json
opencode                                      # go
```

## Build the USB bundle

```
python3 scripts/llamacpp_models.py prefetch   # ensure the model is cached
scripts/build_bundle.sh all --out /tmp/slopcode
```

Layout it produces:

```
/tmp/slopcode/
  README.txt
  models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf
  models/mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf
  linux-cuda/   {llama.cpp/, opencode/, install.sh, start.sh}
  mac-m1/       {llama.cpp/, opencode/, install.sh, start.sh}
  windows-arc/  {llama.cpp/, opencode/, install.bat, start.bat}
  pi/           {npm-cache/, mariozechner-pi-coding-agent-*.tgz, install-unix.sh,
                 install-windows.bat}
```

Then format a USB stick to exFAT (FAT32 cannot hold the 20 GB single file) and
copy the tree over:

```
scripts/usb_format.sh /dev/sdX SLOPCODE     # requires sudo, typed confirmation
rsync -a /tmp/slopcode/ /run/media/$USER/SLOPCODE/
```

## Tests

```
bash ci/run_tests.sh
```

Exercises the llama.cpp launcher (dry-run), the OpenCode config generator, and
a pure-stdlib mock-server health check. Real inference is out of scope for CI.
