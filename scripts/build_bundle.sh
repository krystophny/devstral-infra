#!/usr/bin/env bash
# Build a USB-ready directory tree for one or more target OSes.
#
# Usage:
#   scripts/build_bundle.sh all --out /tmp/qwenstack
#   scripts/build_bundle.sh linux-cuda --out /mnt/usb
#   scripts/build_bundle.sh windows-arc --out /mnt/usb
#   scripts/build_bundle.sh mac-m1 --out /mnt/usb
#
# Each target directory contains:
#   llama.cpp/   unpacked upstream release for that OS/backend
#   opencode/    unpacked opencode release for that OS
#   install.sh or install.bat   copies into ~/.local/devstral and registers a user service
#   start.sh or start.bat       foreground launch for manual testing
# The shared pi/ directory contains an npm offline cache and Pi package tarball.
#
# Models live once at <out>/models/ and are referenced by every per-OS start
# script via relative paths:
#   - Qwen3.6-35B-A3B-Q4_K_M.gguf            (~20 GB, all platforms)
#   - mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf  (~1 GB, vision projector for the
#                                             35B-A3B; image input on every
#                                             platform)
#   - Qwen3.6-27B-Q4_K_M.gguf                (~16 GB, Mac dual-instance only,
#                                             text-only)
#
# Bundle profile mirrors production launchers (server_start_llamacpp.sh +
# server_start_mac.sh + install_mac_launchagents.sh):
#   Linux/Windows: single instance, alias qwen,           :8080,
#                  -c 262144 -np 1 -ub 1024 --n-cpu-moe 35
#                  --threads (physical-2) --threads-http 4
#                  --mmproj  (image input via 35B-A3B vision projector)
#   Mac:           two instances, 35B-A3B alias qwen-35b-a3b :8080 (--mmproj),
#                                 27B     alias qwen-27b     :8081 (text only),
#                  each -c 524288 -np 2 -ub 512  (no MoE split, no thread cap)
# Every slot ends up at the model's native 256K window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have curl || die "curl is required"
have unzip || die "unzip is required"
have python3 || die "python3 is required"
have node || die "node is required to build the Pi offline npm cache"
have npm || die "npm is required to build the Pi offline npm cache"

TARGETS=()
OUT=""
LLAMACPP_TAG="${LLAMACPP_TAG:-}"
OPENCODE_TAG="${OPENCODE_TAG:-}"
PI_VERSION="${PI_VERSION:-0.70.2}"
SKIP_MODEL="${SKIP_MODEL:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --llamacpp-tag) LLAMACPP_TAG="$2"; shift 2 ;;
    --opencode-tag) OPENCODE_TAG="$2"; shift 2 ;;
    --skip-model) SKIP_MODEL="true"; shift ;;
    all) TARGETS=(linux-cuda mac-m1 windows-arc); shift ;;
    linux-cuda|mac-m1|windows-arc) TARGETS+=("$1"); shift ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${OUT}" ]] || die "--out is required"
[[ "${#TARGETS[@]}" -gt 0 ]] || die "specify a target: linux-cuda|mac-m1|windows-arc|all"

mkdir -p "${OUT}/models"

WANT_27B="false"
for t in "${TARGETS[@]}"; do
  [[ "${t}" == "mac-m1" ]] && WANT_27B="true"
done
# Vision projector is needed by every platform that runs the 35B-A3B (i.e.
# all of them). Build_bundle always copies it.
WANT_MMPROJ="true"

resolve_llamacpp_asset() {
  local flavor="$1"
  local api="https://api.github.com/repos/ggml-org/llama.cpp/releases"
  local url
  if [[ -n "${LLAMACPP_TAG}" ]]; then
    url="${api}/tags/${LLAMACPP_TAG}"
  else
    url="${api}/latest"
  fi
  curl -fsSL "${url}" | python3 -c '
import json, re, sys
flavor = sys.argv[1]
data = json.load(sys.stdin)
pat = re.compile(rf"llama-.*-bin-{re.escape(flavor)}\.(zip|tar\.gz)$")
for asset in data["assets"]:
    if pat.search(asset["name"]):
        print(data["tag_name"], asset["browser_download_url"])
        sys.exit(0)
sys.exit(1)
' "${flavor}"
}

resolve_opencode_asset() {
  local suffix="$1"
  local api="https://api.github.com/repos/sst/opencode/releases"
  local url
  if [[ -n "${OPENCODE_TAG}" ]]; then
    url="${api}/tags/${OPENCODE_TAG}"
  else
    url="${api}/latest"
  fi
  curl -fsSL "${url}" | python3 -c '
import json, sys
suffix = sys.argv[1]
data = json.load(sys.stdin)
for asset in data["assets"]:
    if asset["name"].endswith(suffix):
        print(data["tag_name"], asset["browser_download_url"])
        sys.exit(0)
sys.exit(1)
' "${suffix}"
}

fetch_archive() {
  local url="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/pkg" "${url}"
  mkdir -p "${dest}" "${tmp}/unpacked"
  case "${url}" in
    *.tar.gz|*.tgz) tar -xzf "${tmp}/pkg" -C "${tmp}/unpacked" ;;
    *.tar.xz)       tar -xJf "${tmp}/pkg" -C "${tmp}/unpacked" ;;
    *.zip)          unzip -q -o "${tmp}/pkg" -d "${tmp}/unpacked" ;;
    *) die "unknown archive: ${url}" ;;
  esac
  # Flatten common outer wrapper dirs (e.g. "build/bin" or "llama-<tag>/").
  local inner
  inner="$(find "${tmp}/unpacked" -type f \( -name 'llama-server' -o -name 'llama-server.exe' -o -name 'opencode' -o -name 'opencode.exe' \) -print -quit | xargs -I{} dirname {} 2>/dev/null || true)"
  # -L dereferences symlinks so bundles can live on exFAT USB sticks, which
  # don't support symlinks. Cost: a few duplicated .so files, worth it for
  # cross-platform stick compatibility.
  if [[ -n "${inner}" ]]; then
    cp -RL "${inner}/." "${dest}/"
  else
    cp -RL "${tmp}/unpacked/." "${dest}/"
  fi
  rm -rf "${tmp}"
}

copy_model_alias() {
  local alias="$1" required="$2"
  local primary
  primary="$(python3 "${SCRIPT_DIR}/llamacpp_models.py" resolve "${alias}" 2>/dev/null || true)"
  if [[ -z "${primary}" || ! -f "${primary}" ]]; then
    if [[ "${required}" == "true" ]]; then
      die "model alias ${alias} not cached; run: python3 scripts/llamacpp_models.py prefetch ${alias}"
    else
      echo "skip: model alias ${alias} not cached (optional for selected targets)"
      return 0
    fi
  fi
  local src_dir
  src_dir="$(dirname "${primary}")"
  echo "copying ${alias} from ${src_dir} to ${OUT}/models/"
  find "${src_dir}" -maxdepth 1 -type f -name '*.gguf' -exec cp -n {} "${OUT}/models/" \;
}

copy_models() {
  [[ "${SKIP_MODEL}" == "true" ]] && { echo "skip-model: leaving ${OUT}/models untouched"; return; }
  copy_model_alias qwen3.6-35b-a3b-q4 true
  if [[ "${WANT_27B}" == "true" ]]; then
    copy_model_alias qwen3.6-27b-q4 true
  fi
}

prepare_pi_npm_bundle() {
  local pi_dir="${OUT}/pi"
  local cache_dir="${pi_dir}/npm-cache"
  local tmp
  tmp="$(mktemp -d)"
  rm -rf "${pi_dir}"
  mkdir -p "${cache_dir}"

  echo "preparing Pi npm offline cache (${PI_VERSION})"
  (
    cd "${tmp}"
    cat > package.json <<EOF
{"private":true,"dependencies":{"@mariozechner/pi-coding-agent":"${PI_VERSION}"}}
EOF
    npm install --package-lock-only --include=optional --cache "${cache_dir}" >/dev/null
    python3 - <<'PY' > urls.txt
import json
data = json.load(open("package-lock.json"))
urls = sorted({
    pkg["resolved"]
    for pkg in data.get("packages", {}).values()
    if isinstance(pkg, dict) and str(pkg.get("resolved", "")).startswith("http")
})
print("\n".join(urls))
PY
    while IFS= read -r url; do
      [[ -n "${url}" ]] || continue
      npm cache add --cache "${cache_dir}" "${url}" >/dev/null
    done < urls.txt
  )

  npm pack --pack-destination "${pi_dir}" \
    "@mariozechner/pi-coding-agent@${PI_VERSION}" >/dev/null
  cat > "${pi_dir}/install-unix.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PI_TELEMETRY=0
export PI_SKIP_VERSION_CHECK=1
npm install -g --offline --cache "${HERE}/npm-cache" \
  "${HERE}"/mariozechner-pi-coding-agent-*.tgz
EOF
  chmod +x "${pi_dir}/install-unix.sh"
  cat > "${pi_dir}/install-windows.bat" <<'EOF'
@echo off
setlocal
set HERE=%~dp0
set PI_TELEMETRY=0
set PI_SKIP_VERSION_CHECK=1
for %%F in ("%HERE%mariozechner-pi-coding-agent-*.tgz") do (
  npm install -g --offline --cache "%HERE%npm-cache" "%%~fF"
  exit /b %ERRORLEVEL%
)
echo Pi package tarball missing under %HERE%
exit /b 1
EOF
  rm -rf "${tmp}"
}

build_linux_cuda() {
  local t="${OUT}/linux-cuda"
  mkdir -p "${t}/llama.cpp" "${t}/opencode"
  read -r tag url <<< "$(resolve_llamacpp_asset "ubuntu-vulkan-x64" || die "no ubuntu-vulkan-x64 asset")"
  echo "linux-cuda: llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp"

  read -r oc_tag oc_url <<< "$(resolve_opencode_asset "opencode-linux-x64.tar.gz" || die "no opencode linux-x64 asset")"
  echo "linux-cuda: opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode"
  chmod +x "${t}/opencode/opencode" 2>/dev/null || true

  install -m 755 "${SCRIPT_DIR}/opencode_privacy.sh" "${t}/opencode_privacy.sh"
  install -m 755 "${SCRIPT_DIR}/pi_privacy.sh" "${t}/pi_privacy.sh"

  cat > "${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${HERE}/../models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
MMPROJ="${HERE}/../models/mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf"
[[ -f "${MODEL}" ]] || { ls "${HERE}/../models"; echo "model not found"; exit 1; }
[[ -f "${MMPROJ}" ]] || { ls "${HERE}/../models"; echo "mmproj not found"; exit 1; }
PHYS="$(lscpu -p=core 2>/dev/null | awk -F, '!/^#/ && NF {print $1}' | sort -u | wc -l | tr -d ' ')"
[[ "${PHYS}" =~ ^[0-9]+$ && "${PHYS}" -ge 1 ]] || PHYS="$(nproc 2>/dev/null || echo 4)"
THREADS=$(( PHYS - 2 ))
[[ "${THREADS}" -lt 2 ]] && THREADS=2
export LD_LIBRARY_PATH="${HERE}/llama.cpp${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${HERE}/llama.cpp/llama-server" \
  -m "${MODEL}" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 \
  --threads "${THREADS}" --threads-http 4 \
  --mmproj "${MMPROJ}" \
  --alias qwen --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --reasoning-format deepseek --reasoning-budget 4096 \
  --no-context-shift --reasoning on \
  --host 0.0.0.0 --port 8080
EOF
  chmod +x "${t}/start.sh"

  cat > "${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
# Install the local Qwen stack into ~/.local/devstral and register a
# systemd --user service. No sudo required.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/.local/devstral"
mkdir -p "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/models"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
chmod +x "${DEST}/opencode/opencode" 2>/dev/null || true
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -exec cp -n {} "${DEST}/models/" \;
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf' -exec cp -n {} "${DEST}/models/" \;

MODEL="$(find "${DEST}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -print -quit)"
[[ -n "${MODEL}" ]] || { echo "model missing under ${DEST}/models"; exit 1; }
MMPROJ="$(find "${DEST}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf' -print -quit)"
[[ -n "${MMPROJ}" ]] || { echo "mmproj missing under ${DEST}/models"; exit 1; }

# Reserve 2 physical cores for the host so Claude Code / opencode / the DE
# aren't starved during MoE decode. Baked into the unit at install time;
# re-run install.sh to re-detect after hardware changes.
PHYS="$(lscpu -p=core 2>/dev/null | awk -F, '!/^#/ && NF {print $1}' | sort -u | wc -l | tr -d ' ')"
[[ "${PHYS}" =~ ^[0-9]+$ && "${PHYS}" -ge 1 ]] || PHYS="$(nproc 2>/dev/null || echo 4)"
THREADS=$(( PHYS - 2 ))
[[ "${THREADS}" -lt 2 ]] && THREADS=2

UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "${UNIT_DIR}"
cat > "${UNIT_DIR}/devstral-llamacpp.service" <<UNIT
[Unit]
Description=devstral llama.cpp (Qwen3.6 35B-A3B Q4)
After=default.target

[Service]
Environment=LD_LIBRARY_PATH=${DEST}/llama.cpp
ExecStart=${DEST}/llama.cpp/llama-server -m ${MODEL} --mmproj ${MMPROJ} -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads ${THREADS} --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --host 0.0.0.0 --port 8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now devstral-llamacpp.service

# Linger lets the user's systemd instance (and therefore the llama.cpp
# service) start at boot and survive logout, without needing root. On
# most Arch/Ubuntu polkit setups self-linger works for the current user
# without an admin password; if it doesn't, the service still starts at
# the next interactive login.
if loginctl enable-linger "${USER}" >/dev/null 2>&1; then
  echo "linger enabled: devstral-llamacpp starts at boot"
else
  echo "note: could not enable-linger (polkit denied); service will start"
  echo "      at user login, not at boot. Run manually later with:"
  echo "        sudo loginctl enable-linger ${USER}"
fi

sleep 2
systemctl --user status --no-pager devstral-llamacpp.service | head -15

mkdir -p "${HOME}/.config/opencode"
cat > "${HOME}/.config/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "llamacpp/qwen",
  "small_model": "llamacpp/qwen",
  "agent": {"title": {"disable": true}},
  "share": "disabled",
  "autoupdate": false,
  "permission": "allow",
  "tools": {"websearch": false},
  "experimental": {"openTelemetry": false},
  "disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"],
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (Local)",
      "options": {"baseURL": "http://127.0.0.1:8080/v1"},
      "models": {
        "qwen": {
          "name": "Qwen3.6 35B A3B Q4 + KV-Q8 (Local)",
          "limit": {"context": 262144, "output": 16384},
          "reasoning": true,
          "attachment": true,
          "tool_call": true,
          "modalities": {"input": ["text", "image"], "output": ["text"]},
          "options": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096}
        }
      }
    }
  }
}
JSON

bash "${HERE}/opencode_privacy.sh"
bash "${HERE}/pi_privacy.sh"

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  echo "installing Pi Coding Agent from bundled npm cache..."
  bash "${BUNDLE_ROOT}/pi/install-unix.sh"
else
  echo "note: node/npm not found; skipping Pi install"
fi
mkdir -p "${HOME}/.pi/agent"
cat > "${HOME}/.pi/agent/settings.json" <<JSON
{
  "defaultProvider": "llamacpp",
  "defaultModel": "qwen",
  "defaultThinkingLevel": "high",
  "enabledModels": ["llamacpp/qwen"],
  "enableInstallTelemetry": false
}
JSON
cat > "${HOME}/.pi/agent/models.json" <<JSON
{
  "providers": {
    "llamacpp": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "llamacpp",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsUsageInStreaming": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        {
          "id": "qwen",
          "name": "Qwen3.6 35B A3B Q4 + KV-Q8 (Local llama.cpp)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 262144,
          "maxTokens": 16384,
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
        }
      ]
    }
  }
}
JSON

mkdir -p "${HOME}/.local/bin"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to PATH (export PATH=\"\${HOME}/.local/bin:\${PATH}\") to run 'opencode' directly." ;;
esac

echo "OK. New shell, then: opencode   (or: ${DEST}/opencode/opencode)"
EOF
  chmod +x "${t}/install.sh"
}

build_mac_m1() {
  local t="${OUT}/mac-m1"
  mkdir -p "${t}/llama.cpp" "${t}/opencode"
  read -r tag url <<< "$(resolve_llamacpp_asset "macos-arm64" || die "no macos-arm64 asset")"
  echo "mac-m1: llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp"

  read -r oc_tag oc_url <<< "$(resolve_opencode_asset "opencode-darwin-arm64.zip" || die "no opencode darwin-arm64 asset")"
  echo "mac-m1: opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode"
  chmod +x "${t}/opencode/opencode" 2>/dev/null || true

  install -m 755 "${SCRIPT_DIR}/opencode_privacy.sh" "${t}/opencode_privacy.sh"
  install -m 755 "${SCRIPT_DIR}/pi_privacy.sh" "${t}/pi_privacy.sh"

  # Foreground manual launch: starts both 35B-A3B (8080) and 27B (8081).
  cat > "${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_35B="${HERE}/../models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
MODEL_27B="${HERE}/../models/Qwen_Qwen3.6-27B-Q4_K_M.gguf"
MMPROJ_35B="$(ls "${HERE}/../models"/mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf 2>/dev/null | head -1)"
MMPROJ_27B="$(ls "${HERE}/../models"/mmproj-Qwen_Qwen3.6-27B-*.gguf 2>/dev/null | head -1)"
[[ -f "${MODEL_35B}" ]] || { ls "${HERE}/../models"; echo "35B model not found"; exit 1; }
[[ -f "${MODEL_27B}" ]] || { ls "${HERE}/../models"; echo "27B model not found"; exit 1; }
[[ -f "${MMPROJ_35B}" ]] || { ls "${HERE}/../models"; echo "mmproj-35B-A3B not found"; exit 1; }
[[ -f "${MMPROJ_27B}" ]] || { ls "${HERE}/../models"; echo "mmproj-27B not found"; exit 1; }
export DYLD_LIBRARY_PATH="${HERE}/llama.cpp${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
"${HERE}/llama.cpp/llama-server" \
  -m "${MODEL_35B}" --mmproj "${MMPROJ_35B}" \
  -c 524288 --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 512 -ngl 99 -fa on -np 2 \
  --alias qwen-35b-a3b --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --reasoning-format deepseek --reasoning-budget 4096 \
  --no-context-shift --reasoning on \
  --host 0.0.0.0 --port 8080 &
PID_35B=$!
trap 'kill ${PID_35B} 2>/dev/null || true' EXIT
exec "${HERE}/llama.cpp/llama-server" \
  -m "${MODEL_27B}" --mmproj "${MMPROJ_27B}" \
  -c 524288 --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 512 -ngl 99 -fa on -np 2 \
  --alias qwen-27b --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --reasoning-format deepseek --reasoning-budget 4096 \
  --no-context-shift --reasoning on \
  --host 0.0.0.0 --port 8081
EOF
  chmod +x "${t}/start.sh"

  cat > "${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
# Install the dual-instance Qwen stack into ~/Library/Application Support/devstral
# and register two launchd user agents (no sudo, no admin):
#   com.devstral.llamacpp-35b-a3b -> Qwen3.6 35B-A3B Q4 (MoE) on :8080
#   com.devstral.llamacpp-27b     -> Qwen3.6 27B    Q4 (dense) on :8081
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/Library/Application Support/devstral"
LOG_DIR="${HOME}/Library/Logs/devstral"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
mkdir -p "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/models" "${LOG_DIR}" "${AGENTS_DIR}"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
chmod +x "${DEST}/opencode/opencode" 2>/dev/null || true
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -exec cp -n {} "${DEST}/models/" \;
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-27B-Q4_K_M*.gguf' -exec cp -n {} "${DEST}/models/" \;
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf' -exec cp -n {} "${DEST}/models/" \;
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-27B-*.gguf' -exec cp -n {} "${DEST}/models/" \;

MODEL_35B="$(find "${DEST}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -print -quit)"
MODEL_27B="$(find "${DEST}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-27B-Q4_K_M*.gguf' -print -quit)"
MMPROJ_35B="$(find "${DEST}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf' -print -quit)"
MMPROJ_27B="$(find "${DEST}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-27B-*.gguf' -print -quit)"
[[ -n "${MODEL_35B}" ]] || { echo "35B model missing under ${DEST}/models"; exit 1; }
[[ -n "${MODEL_27B}" ]] || { echo "27B model missing under ${DEST}/models"; exit 1; }
[[ -n "${MMPROJ_35B}" ]] || { echo "mmproj-35B-A3B missing under ${DEST}/models"; exit 1; }
[[ -n "${MMPROJ_27B}" ]] || { echo "mmproj-27B missing under ${DEST}/models"; exit 1; }

SERVER_BIN="${DEST}/llama.cpp/llama-server"
SERVER_DIR="${DEST}/llama.cpp"

bootout_legacy() {
  local label="$1"
  if launchctl list | awk '{print $3}' | grep -qx "${label}"; then
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || launchctl unload "${AGENTS_DIR}/${label}.plist" 2>/dev/null || true
  fi
  rm -f "${AGENTS_DIR}/${label}.plist"
}
# Legacy single-instance labels from older bundles -> remove cleanly first.
bootout_legacy com.qwenstack.llamacpp
bootout_legacy com.devstral.llamacpp-local

write_plist() {
  local label="$1" port="$2" alias="$3" model="$4" instance="$5" mmproj="${6:-}"
  local plist="${AGENTS_DIR}/${label}.plist"
  local log="${LOG_DIR}/llamacpp-${instance}.log"
  local mmproj_xml=""
  if [[ -n "${mmproj}" ]]; then
    mmproj_xml=$'\n    <string>--mmproj</string><string>'"${mmproj}"$'</string>'
  fi
  cat > "${plist}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${SERVER_BIN}</string>
    <string>-m</string><string>${model}</string>${mmproj_xml}
    <string>-c</string><string>524288</string>
    <string>-b</string><string>2048</string>
    <string>-ub</string><string>512</string>
    <string>-ngl</string><string>99</string>
    <string>-fa</string><string>on</string>
    <string>-np</string><string>2</string>
    <string>--cache-type-k</string><string>q8_0</string>
    <string>--cache-type-v</string><string>q8_0</string>
    <string>--alias</string><string>${alias}</string>
    <string>--jinja</string>
    <string>--temp</string><string>0.6</string>
    <string>--top-p</string><string>0.95</string>
    <string>--top-k</string><string>20</string>
    <string>--min-p</string><string>0</string>
    <string>--presence-penalty</string><string>0.0</string>
    <string>--repeat-penalty</string><string>1.0</string>
    <string>--reasoning-format</string><string>deepseek</string>
    <string>--reasoning-budget</string><string>4096</string>
    <string>--no-context-shift</string>
    <string>--reasoning</string><string>on</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>${port}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key><string>${SERVER_DIR}</string>
  </dict>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
XML
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${plist}"
  echo "loaded ${label} (port ${port}, alias ${alias})"
}

write_plist com.devstral.llamacpp-35b-a3b 8080 qwen-35b-a3b "${MODEL_35B}" 35b-a3b "${MMPROJ_35B}"
write_plist com.devstral.llamacpp-27b     8081 qwen-27b     "${MODEL_27B}" 27b     "${MMPROJ_27B}"

mkdir -p "${HOME}/.config/opencode"
cat > "${HOME}/.config/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "llamacpp/qwen-27b",
  "small_model": "llamacpp-moe/qwen-35b-a3b",
  "agent": {"title": {"disable": true}},
  "share": "disabled",
  "autoupdate": false,
  "permission": "allow",
  "tools": {"websearch": false},
  "experimental": {"openTelemetry": false},
  "disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"],
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp 27B (Local)",
      "options": {"baseURL": "http://127.0.0.1:8081/v1"},
      "models": {
        "qwen-27b": {
          "name": "Qwen3.6 27B Q4 + KV-Q8 (Local dense)",
          "limit": {"context": 262144, "output": 16384},
          "reasoning": true,
          "attachment": true,
          "tool_call": true,
          "modalities": {"input": ["text", "image"], "output": ["text"]},
          "options": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096}
        }
      }
    },
    "llamacpp-moe": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp 35B-A3B (Local)",
      "options": {"baseURL": "http://127.0.0.1:8080/v1"},
      "models": {
        "qwen-35b-a3b": {
          "name": "Qwen3.6 35B A3B Q4 + KV-Q8 (Local MoE)",
          "limit": {"context": 262144, "output": 16384},
          "reasoning": true,
          "attachment": true,
          "tool_call": true,
          "modalities": {"input": ["text", "image"], "output": ["text"]},
          "options": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096}
        }
      }
    }
  }
}
JSON

bash "${HERE}/opencode_privacy.sh"
bash "${HERE}/pi_privacy.sh"

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  echo "installing Pi Coding Agent from bundled npm cache..."
  bash "${BUNDLE_ROOT}/pi/install-unix.sh"
else
  echo "note: node/npm not found; skipping Pi install"
fi
mkdir -p "${HOME}/.pi/agent"
cat > "${HOME}/.pi/agent/settings.json" <<JSON
{
  "defaultProvider": "llamacpp",
  "defaultModel": "qwen",
  "defaultThinkingLevel": "high",
  "enabledModels": ["llamacpp/qwen"],
  "enableInstallTelemetry": false
}
JSON
cat > "${HOME}/.pi/agent/models.json" <<JSON
{
  "providers": {
    "llamacpp": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "llamacpp",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsUsageInStreaming": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        {
          "id": "qwen",
          "name": "Qwen3.6 35B A3B Q4 + KV-Q8 (Local llama.cpp)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 262144,
          "maxTokens": 16384,
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
        }
      ]
    }
  }
}
JSON

mkdir -p "${HOME}/.local/bin"
ln -sf "${DEST}/opencode/opencode" "${HOME}/.local/bin/opencode"
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to PATH (export PATH=\"\${HOME}/.local/bin:\${PATH}\") to run 'opencode' directly." ;;
esac

echo
echo "waiting for both endpoints (up to 900s each)..."
wait_ready() {
  local port="$1" deadline=$(( $(date +%s) + 900 ))
  while : ; do
    if curl -fsS "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
      echo "ready: http://127.0.0.1:${port}/v1"
      return 0
    fi
    [[ $(date +%s) -ge ${deadline} ]] && { echo "timed out on port ${port}" >&2; return 1; }
    sleep 2
  done
}
wait_ready 8080 || true
wait_ready 8081 || true

echo "OK. New shell, then: opencode   (or: ${DEST}/opencode/opencode)"
EOF
  chmod +x "${t}/install.sh"
}

build_windows_arc() {
  local t="${OUT}/windows-arc"
  mkdir -p "${t}/llama.cpp" "${t}/opencode"
  read -r tag url <<< "$(resolve_llamacpp_asset "win-vulkan-x64" || die "no win-vulkan-x64 asset")"
  echo "windows-arc: llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp"

  read -r oc_tag oc_url <<< "$(resolve_opencode_asset "opencode-windows-x64.zip" || die "no opencode windows-x64 asset")"
  echo "windows-arc: opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode"

  cat > "${t}/start.bat" <<'EOF'
@echo off
setlocal EnableDelayedExpansion
set HERE=%~dp0
set MODEL=%HERE%..\models\Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf
set MMPROJ=%HERE%..\models\mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf
if not exist "%MODEL%" (
  echo Model not found under %HERE%..\models
  dir "%HERE%..\models"
  exit /b 1
)
if not exist "%MMPROJ%" (
  echo mmproj not found under %HERE%..\models
  dir "%HERE%..\models"
  exit /b 1
)
REM Reserve 2 physical cores for the host (Claude Code, opencode, DE) so
REM MoE decode doesn't starve unrelated userspace and trip TCP idle timeouts.
set THREADS=
powershell -NoProfile -Command "try { [Math]::Max(2, (Get-CimInstance Win32_Processor | Measure-Object -Sum NumberOfCores).Sum - 2) } catch { [Math]::Max(2, [int]($env:NUMBER_OF_PROCESSORS) / 2 - 1) }" > "%TEMP%\devstral_threads.txt" 2>nul
if exist "%TEMP%\devstral_threads.txt" (
  set /p THREADS=<"%TEMP%\devstral_threads.txt"
  del "%TEMP%\devstral_threads.txt"
)
if "!THREADS!"=="" set /a THREADS=%NUMBER_OF_PROCESSORS%/2 - 1
if !THREADS! LSS 2 set THREADS=2
"%HERE%llama.cpp\llama-server.exe" ^
  -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 ^
  -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 ^
  --threads !THREADS! --threads-http 4 ^
  --alias qwen --jinja ^
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 ^
  --presence-penalty 0.0 --repeat-penalty 1.0 ^
  --reasoning-format deepseek --reasoning-budget 4096 ^
  --no-context-shift --reasoning on ^
  --host 0.0.0.0 --port 8080
EOF

  cat > "${t}/install.bat" <<'EOF'
@echo off
REM Install the local Qwen stack into %USERPROFILE%\devstral and register a
REM Startup shortcut so the server launches at every logon. No admin, no UAC:
REM the Startup folder and %USERPROFILE% are always user-writable.
setlocal EnableDelayedExpansion
set HERE=%~dp0
set BUNDLE_ROOT=%HERE%..
set DEST=%USERPROFILE%\devstral
set STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
set OC_CFG_DIR=%USERPROFILE%\.config\opencode
set OC_CFG=%OC_CFG_DIR%\opencode.json

echo [1/6] creating %DEST%
if not exist "%DEST%" mkdir "%DEST%"
if not exist "%DEST%\llama.cpp" mkdir "%DEST%\llama.cpp"
if not exist "%DEST%\opencode" mkdir "%DEST%\opencode"
if not exist "%DEST%\models" mkdir "%DEST%\models"

echo [2/6] copying binaries and model (this takes a while for the GGUF)...
xcopy /E /Y /I /Q "%HERE%llama.cpp\*" "%DEST%\llama.cpp\" >nul
xcopy /E /Y /I /Q "%HERE%opencode\*" "%DEST%\opencode\" >nul
xcopy /Y /I /Q "%BUNDLE_ROOT%\models\Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf" "%DEST%\models\" >nul
xcopy /Y /I /Q "%BUNDLE_ROOT%\models\mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf" "%DEST%\models\" >nul

set MODEL=%DEST%\models\Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf
set MMPROJ=%DEST%\models\mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf
if not exist "%MODEL%" (
  echo Model missing under %DEST%\models
  exit /b 1
)
if not exist "%MMPROJ%" (
  echo mmproj missing under %DEST%\models
  exit /b 1
)

echo [3/6] detecting physical cores and writing %DEST%\run-llamacpp.bat
set THREADS=
powershell -NoProfile -Command "try { [Math]::Max(2, (Get-CimInstance Win32_Processor | Measure-Object -Sum NumberOfCores).Sum - 2) } catch { [Math]::Max(2, [int]($env:NUMBER_OF_PROCESSORS) / 2 - 1) }" > "%TEMP%\devstral_threads.txt" 2>nul
if exist "%TEMP%\devstral_threads.txt" (
  set /p THREADS=<"%TEMP%\devstral_threads.txt"
  del "%TEMP%\devstral_threads.txt"
)
if "!THREADS!"=="" set /a THREADS=%NUMBER_OF_PROCESSORS%/2 - 1
if !THREADS! LSS 2 set THREADS=2
echo     using --threads !THREADS! --threads-http 4
> "%DEST%\run-llamacpp.bat" echo @echo off
>> "%DEST%\run-llamacpp.bat" echo start "devstral-llamacpp" /MIN "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --host 0.0.0.0 --port 8080

echo [4/6] installing Startup shortcut at "%STARTUP%\devstral-llamacpp.bat"
if not exist "%STARTUP%" mkdir "%STARTUP%"
copy /Y "%DEST%\run-llamacpp.bat" "%STARTUP%\devstral-llamacpp.bat" >nul

echo [5/6] writing OpenCode config to %OC_CFG%
if not exist "%OC_CFG_DIR%" mkdir "%OC_CFG_DIR%"
>  "%OC_CFG%" echo {
>> "%OC_CFG%" echo   "$schema": "https://opencode.ai/config.json",
>> "%OC_CFG%" echo   "model": "llamacpp/qwen",
>> "%OC_CFG%" echo   "small_model": "llamacpp/qwen",
>> "%OC_CFG%" echo   "agent": { "title": { "disable": true } },
>> "%OC_CFG%" echo   "share": "disabled",
>> "%OC_CFG%" echo   "autoupdate": false,
>> "%OC_CFG%" echo   "permission": "allow",
>> "%OC_CFG%" echo   "tools": { "websearch": false },
>> "%OC_CFG%" echo   "experimental": { "openTelemetry": false },
>> "%OC_CFG%" echo   "disabled_providers": ["exa", "opencode", "llmgateway", "github-copilot", "copilot", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"],
>> "%OC_CFG%" echo   "provider": {
>> "%OC_CFG%" echo     "llamacpp": {
>> "%OC_CFG%" echo       "npm": "@ai-sdk/openai-compatible",
>> "%OC_CFG%" echo       "name": "llama.cpp (Local)",
>> "%OC_CFG%" echo       "options": { "baseURL": "http://127.0.0.1:8080/v1" },
>> "%OC_CFG%" echo       "models": {
>> "%OC_CFG%" echo         "qwen": {
>> "%OC_CFG%" echo           "name": "Qwen3.6 35B A3B Q4 + KV-Q8 (Local)",
>> "%OC_CFG%" echo           "limit": { "context": 262144, "output": 16384 },
>> "%OC_CFG%" echo           "reasoning": true,
>> "%OC_CFG%" echo           "attachment": true,
>> "%OC_CFG%" echo           "tool_call": true,
>> "%OC_CFG%" echo           "modalities": { "input": ["text", "image"], "output": ["text"] },
>> "%OC_CFG%" echo           "options": { "temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096 }
>> "%OC_CFG%" echo         }
>> "%OC_CFG%" echo       }
>> "%OC_CFG%" echo     }
>> "%OC_CFG%" echo   }
>> "%OC_CFG%" echo }

echo [6/6] pinning opencode privacy env vars in HKCU\Environment (no admin)
setx OPENCODE_DISABLE_AUTOUPDATE 1 >nul
setx OPENCODE_DISABLE_SHARE 1 >nul
setx OPENCODE_DISABLE_MODELS_FETCH 1 >nul
setx OPENCODE_DISABLE_LSP_DOWNLOAD 1 >nul
setx OPENCODE_DISABLE_DEFAULT_PLUGINS 1 >nul
setx OPENCODE_DISABLE_EMBEDDED_WEB_UI 1 >nul
setx PI_TELEMETRY 0 >nul
setx PI_SKIP_VERSION_CHECK 1 >nul

where node >nul 2>nul
set HAS_NODE=%ERRORLEVEL%
where npm >nul 2>nul
set HAS_NPM=%ERRORLEVEL%
if "%HAS_NODE%%HAS_NPM%"=="00" (
  echo Installing Pi Coding Agent from bundled npm cache...
  call "%BUNDLE_ROOT%\pi\install-windows.bat"
  if errorlevel 1 exit /b 1
) else (
  echo note: node/npm not found; skipping Pi install
)

set PI_CFG_DIR=%USERPROFILE%\.pi\agent
if not exist "%PI_CFG_DIR%" mkdir "%PI_CFG_DIR%"
set PI_SETTINGS=%PI_CFG_DIR%\settings.json
set PI_MODELS=%PI_CFG_DIR%\models.json
>  "%PI_SETTINGS%" echo {
>> "%PI_SETTINGS%" echo   "defaultProvider": "llamacpp",
>> "%PI_SETTINGS%" echo   "defaultModel": "qwen",
>> "%PI_SETTINGS%" echo   "defaultThinkingLevel": "high",
>> "%PI_SETTINGS%" echo   "enabledModels": ["llamacpp/qwen"],
>> "%PI_SETTINGS%" echo   "enableInstallTelemetry": false
>> "%PI_SETTINGS%" echo }
>  "%PI_MODELS%" echo {
>> "%PI_MODELS%" echo   "providers": {
>> "%PI_MODELS%" echo     "llamacpp": {
>> "%PI_MODELS%" echo       "baseUrl": "http://127.0.0.1:8080/v1",
>> "%PI_MODELS%" echo       "api": "openai-completions",
>> "%PI_MODELS%" echo       "apiKey": "llamacpp",
>> "%PI_MODELS%" echo       "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false, "supportsUsageInStreaming": false, "maxTokensField": "max_tokens" },
>> "%PI_MODELS%" echo       "models": [
>> "%PI_MODELS%" echo         {
>> "%PI_MODELS%" echo           "id": "qwen",
>> "%PI_MODELS%" echo           "name": "Qwen3.6 35B A3B Q4 + KV-Q8 (Local llama.cpp)",
>> "%PI_MODELS%" echo           "reasoning": true,
>> "%PI_MODELS%" echo           "input": ["text", "image"],
>> "%PI_MODELS%" echo           "contextWindow": 131072,
>> "%PI_MODELS%" echo           "maxTokens": 16384,
>> "%PI_MODELS%" echo           "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
>> "%PI_MODELS%" echo         }
>> "%PI_MODELS%" echo       ]
>> "%PI_MODELS%" echo     }
>> "%PI_MODELS%" echo   }
>> "%PI_MODELS%" echo }

REM Idempotent prepend of the opencode dir to user PATH via PowerShell
REM (reads HKCU\Environment directly so successive runs don't duplicate).
set OC_BIN_DIR=%DEST%\opencode
powershell -NoProfile -Command ^
  "$u = [Environment]::GetEnvironmentVariable('Path','User');" ^
  "$d = '%OC_BIN_DIR%';" ^
  "if ($null -eq $u) { $u = '' }" ^
  "$parts = $u.Split(';') | Where-Object { $_ -and $_ -ne $d };" ^
  "$new = (@($d) + $parts) -join ';';" ^
  "[Environment]::SetEnvironmentVariable('Path', $new, 'User')"
echo     (env vars and PATH take effect in new cmd/powershell windows, not this one)

echo.
echo Starting the server now (will also auto-start at every logon)...
start "devstral-llamacpp" /MIN "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --host 0.0.0.0 --port 8080

echo.
echo OK. Wait ~30s for the model to load, then open a NEW command prompt
echo so the OPENCODE_DISABLE_* env vars and PATH are picked up, and run:
echo     opencode
echo (to stop the server: open Task Manager and end llama-server.exe)
EOF
}

cat > "${OUT}/README.txt" <<'EOF'
devstral USB bundle (Qwen3.6 local stack)
=========================================

Three self-contained per-OS directories plus a shared models/ folder:

  linux-cuda/   Linux + Vulkan/CUDA GPU (install.sh, no sudo)
                  -> single 35B-A3B :8080, 256K window, --n-cpu-moe 35,
                     image input via mmproj
  mac-m1/       Apple Silicon Mac (install.sh, no sudo)
                  -> dual instance: 35B-A3B :8080 + 27B dense :8081,
                     256K per slot (-c 524288 -np 2), both with image input
  windows-arc/  Windows + Vulkan GPU (install.bat, no admin)
                  -> single 35B-A3B :8080, 256K window, --n-cpu-moe 35,
                     image input via mmproj
  pi/           Pi Coding Agent npm tarball + offline npm cache
  models/       Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf       (~20 GB, all platforms)
                mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf (~1 GB,  vision projector,
                                                       all platforms)
                Qwen_Qwen3.6-27B-Q4_K_M.gguf          (~16 GB, Mac only)
                mmproj-Qwen_Qwen3.6-27B-bf16.gguf     (~1 GB,  Mac only)

Requires exFAT formatting on the USB stick (FAT32 cannot hold the 20 GB
GGUF; exFAT is mounted natively by Windows and macOS and supported by
Linux kernels since 5.7).

To install on a target machine:

  Linux/Mac:   ./<target>/install.sh
  Windows:     .\windows-arc\install.bat

The installer copies llama.cpp + opencode + the model(s) into the user's
home directory, registers a user-level service (systemd --user, two
launchd agents on Mac, or a Startup shortcut on Windows), runs the bundled
offline npm install for the Pi Coding Agent, and writes OpenCode + Pi
configs that disable every outbound network call beyond the local LLM
endpoint. Image input is enabled wherever a vision projector is shipped.

Smoke test:
  curl -s http://127.0.0.1:8080/v1/models
  (Mac also: curl -s http://127.0.0.1:8081/v1/models)

Then launch opencode from the bundle's opencode/ directory, or pi if node/npm
were installed and the bundled offline npm install succeeded.
EOF

prepare_pi_npm_bundle

for t in "${TARGETS[@]}"; do
  case "${t}" in
    linux-cuda)   build_linux_cuda ;;
    mac-m1)       build_mac_m1 ;;
    windows-arc)  build_windows_arc ;;
    *) die "unknown target: ${t}" ;;
  esac
done

copy_models

echo
echo "bundle built at ${OUT}:"
du -sh "${OUT}/"* 2>/dev/null | sort -k2
