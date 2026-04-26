#!/usr/bin/env bash
# Build a USB-ready directory tree for one or more target OSes.
#
# Usage:
#   scripts/build_bundle.sh all --out /tmp/slopcode
#   scripts/build_bundle.sh linux-cuda --out /mnt/usb
#   scripts/build_bundle.sh windows-arc --out /mnt/usb
#   scripts/build_bundle.sh mac-m1 --out /mnt/usb
#
# Each target directory contains:
#   llama.cpp/   unpacked upstream release for that OS/backend
#   opencode/    unpacked opencode release for that OS
#   install.sh or install.bat   copies into ~/.local/slopcode and registers a user service
#   start.sh or start.bat       foreground launch for manual testing
#   node/                       Node.js LTS runtime for that OS (bin/node + npm)
# The shared pi/ directory contains an npm offline cache and Pi package tarball.
# Together with each target's bundled node/, that lets the per-OS installer
# install Pi without any online step or any pre-existing Node on the host.
#
# Models live once at <out>/models/ and are referenced by every per-OS start
# script via relative paths:
#   - Qwen3.6-35B-A3B-Q4_K_M.gguf            (~20 GB, all platforms)
#   - mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf  (~1 GB, vision projector for the
#                                             35B-A3B; image input on every
#                                             platform)
#
# Bundle profile mirrors production launchers (server_start_llamacpp.sh +
# install_macbook_launchagent.sh):
#   Linux/Windows: single instance, alias qwen, :8080,
#                  -c 262144 -np 1 -ub 1024 --n-cpu-moe 35
#                  --threads (physical-2) --threads-http 4
#                  --mmproj  (image input via 35B-A3B vision projector)
#   Mac:           single instance, alias qwen, :8080,
#                  -c 131072 -np 1 -ub 1024 (Metal, no MoE split, no thread cap)
#                  --mmproj  (image input via 35B-A3B vision projector)
# The Mac Studio dual-instance deployment (with the 27B dense companion)
# is set up directly from the repo via install_mac_launchagents.sh and is
# intentionally not part of this USB bundle.
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
NODE_VERSION="${NODE_VERSION:-}"
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

# Vision projector is needed by every platform that runs the 35B-A3B (i.e.
# all of them). Build_bundle always copies it.
WANT_MMPROJ="true"

# Network defaults for every curl in this script. --connect-timeout caps
# DNS+TCP+TLS at 30 s and --max-time caps the whole transfer at 30 min,
# so a wedged GitHub mirror or registry can never silently stall the
# bundle build. --retry handles transient TCP RSTs without a wrapper.
CURL_OPTS=(-fsSL --connect-timeout 30 --max-time 1800 --retry 3 --retry-delay 5)

resolve_llamacpp_asset() {
  local flavor="$1"
  local api="https://api.github.com/repos/ggml-org/llama.cpp/releases"
  local url
  if [[ -n "${LLAMACPP_TAG}" ]]; then
    url="${api}/tags/${LLAMACPP_TAG}"
  else
    url="${api}/latest"
  fi
  curl "${CURL_OPTS[@]}" "${url}" | python3 -c '
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
  curl "${CURL_OPTS[@]}" "${url}" | python3 -c '
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

resolve_node_version() {
  if [[ -n "${NODE_VERSION}" ]]; then
    echo "${NODE_VERSION}"
    return
  fi
  curl "${CURL_OPTS[@]}" "https://nodejs.org/dist/index.json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for entry in data:
    if entry.get("lts"):
        print(entry["version"])
        sys.exit(0)
sys.exit(1)
'
}

# Node.js archives unpack to a single wrapper directory like
# node-v22.x.x-linux-x64/. Flatten that wrapper into ${dest} so the install
# scripts can reference ${dest}/bin/node (Unix) or ${dest}/node.exe (Windows).
fetch_node_archive() {
  local url="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  curl "${CURL_OPTS[@]}" -o "${tmp}/pkg" "${url}"
  mkdir -p "${dest}" "${tmp}/unpacked"
  case "${url}" in
    *.tar.xz) tar -xJf "${tmp}/pkg" -C "${tmp}/unpacked" ;;
    *.tar.gz) tar -xzf "${tmp}/pkg" -C "${tmp}/unpacked" ;;
    *.zip)    unzip -q -o "${tmp}/pkg" -d "${tmp}/unpacked" ;;
    *) die "unknown node archive: ${url}" ;;
  esac
  local inner
  inner="$(find "${tmp}/unpacked" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -d "${inner}" ]] || die "node archive layout unexpected: ${url}"
  # -L dereferences symlinks (notably bin/npm -> ../lib/node_modules/npm/...)
  # so the unpacked tree can sit on exFAT, which has no symlink support.
  cp -RL "${inner}/." "${dest}/"
  rm -rf "${tmp}"
}

prepare_node_runtime() {
  local target_dir="$1" flavor="$2"
  local node_dir="${target_dir}/node"
  local node_ver
  node_ver="$(resolve_node_version)"
  [[ -n "${node_ver}" ]] || die "could not resolve Node.js LTS version"
  rm -rf "${node_dir}"
  mkdir -p "${node_dir}"
  local archive
  case "${flavor}" in
    linux-x64)    archive="node-${node_ver}-linux-x64.tar.xz" ;;
    darwin-arm64) archive="node-${node_ver}-darwin-arm64.tar.xz" ;;
    win-x64)      archive="node-${node_ver}-win-x64.zip" ;;
    *) die "unknown node flavor: ${flavor}" ;;
  esac
  local url="https://nodejs.org/dist/${node_ver}/${archive}"
  echo "node ${node_ver} (${flavor})"
  fetch_node_archive "${url}" "${node_dir}"
  if [[ "${flavor}" == "win-x64" ]]; then
    [[ -f "${node_dir}/node.exe" ]] || die "node.exe missing under ${node_dir}"
    [[ -f "${node_dir}/npm.cmd"  ]] || die "npm.cmd missing under ${node_dir}"
    [[ -f "${node_dir}/node_modules/npm/bin/npm-cli.js" ]] || die "npm-cli.js missing under ${node_dir}"
  else
    [[ -x "${node_dir}/bin/node" ]] || die "bin/node missing under ${node_dir}"
    [[ -f "${node_dir}/lib/node_modules/npm/bin/npm-cli.js" ]] || die "npm-cli.js missing under ${node_dir}"
  fi
}

fetch_archive() {
  local url="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  curl "${CURL_OPTS[@]}" -o "${tmp}/pkg" "${url}"
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
  rm -rf "${tmp}"
}

build_linux_cuda() {
  local t="${OUT}/linux-cuda"
  rm -rf "${t}/llama.cpp" "${t}/opencode" "${t}/node"
  mkdir -p "${t}/llama.cpp" "${t}/opencode"
  read -r tag url <<< "$(resolve_llamacpp_asset "ubuntu-vulkan-x64" || die "no ubuntu-vulkan-x64 asset")"
  echo "linux-cuda: llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp"

  read -r oc_tag oc_url <<< "$(resolve_opencode_asset "opencode-linux-x64.tar.gz" || die "no opencode linux-x64 asset")"
  echo "linux-cuda: opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode"
  chmod +x "${t}/opencode/opencode" 2>/dev/null || true

  prepare_node_runtime "${t}" linux-x64

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
# Install the local Qwen stack into ~/.local/slopcode and register a
# systemd --user service. No sudo required.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/.local/slopcode"
LEGACY_DEST="${HOME}/.local/devstral"
mkdir -p "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/models"
# Boot out the previous devstral-named unit if present so the new
# slopcode-llamacpp service doesn't race a stale ExecStart pointing at
# the old install path.
if systemctl --user list-unit-files devstral-llamacpp.service >/dev/null 2>&1; then
  systemctl --user disable --now devstral-llamacpp.service 2>/dev/null || true
  rm -f "${HOME}/.config/systemd/user/devstral-llamacpp.service"
  systemctl --user daemon-reload 2>/dev/null || true
fi
[[ -d "${LEGACY_DEST}" ]] && rm -rf "${LEGACY_DEST}"
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
cat > "${UNIT_DIR}/slopcode-llamacpp.service" <<UNIT
[Unit]
Description=slopcode llama.cpp (Qwen3.6 35B-A3B Q4)
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
systemctl --user enable --now slopcode-llamacpp.service

# Linger lets the user's systemd instance (and therefore the llama.cpp
# service) start at boot and survive logout, without needing root. On
# most Arch/Ubuntu polkit setups self-linger works for the current user
# without an admin password; if it doesn't, the service still starts at
# the next interactive login.
if loginctl enable-linger "${USER}" >/dev/null 2>&1; then
  echo "linger enabled: slopcode-llamacpp starts at boot"
else
  echo "note: could not enable-linger (polkit denied); service will start"
  echo "      at user login, not at boot. Run manually later with:"
  echo "        sudo loginctl enable-linger ${USER}"
fi

sleep 2
systemctl --user status --no-pager slopcode-llamacpp.service | head -15

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

# Bundled Node.js LTS + offline npm cache: no system node/npm required, no
# sudo, nothing leaks outside ${DEST}.
mkdir -p "${DEST}/node"
cp -RL "${HERE}/node/." "${DEST}/node/"
chmod +x "${DEST}/node/bin/node" 2>/dev/null || true
NODE_BIN="${DEST}/node/bin/node"
NPM_CLI_JS="${DEST}/node/lib/node_modules/npm/bin/npm-cli.js"
PI_TARBALL="$(ls "${BUNDLE_ROOT}/pi"/mariozechner-pi-coding-agent-*.tgz 2>/dev/null | head -1)"
[[ -x "${NODE_BIN}" && -f "${NPM_CLI_JS}" && -f "${PI_TARBALL}" ]] \
  || { echo "bundled node or pi tarball missing under ${BUNDLE_ROOT}"; exit 1; }
echo "installing Pi Coding Agent from bundled Node + npm cache..."
PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 \
  "${NODE_BIN}" "${NPM_CLI_JS}" install -g \
    --prefix "${DEST}/node" \
    --offline --cache "${BUNDLE_ROOT}/pi/npm-cache" \
    "${PI_TARBALL}"

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
# Wrapper for pi: invoke bundled node with pi's resolved cli.js, no PATH
# pollution and no dependence on system node.
PI_BIN_REAL="$(realpath "${DEST}/node/bin/pi")"
cat > "${HOME}/.local/bin/pi" <<PI_WRAP
#!/bin/sh
exec "${NODE_BIN}" "${PI_BIN_REAL}" "\$@"
PI_WRAP
chmod +x "${HOME}/.local/bin/pi"

# Make sure ~/.local/bin is on the user's PATH for new shells. Idempotent
# marker block, mirrors pi_privacy.sh.
LOCAL_BIN_BEGIN='# >>> slopcode-infra ~/.local/bin >>>'
LOCAL_BIN_END='# <<< slopcode-infra ~/.local/bin <<<'
LOCAL_BIN_BLOCK='case ":${PATH}:" in *":${HOME}/.local/bin:"*) ;; *) export PATH="${HOME}/.local/bin:${PATH}" ;; esac'
ensure_local_bin_on_path() {
  local rc="$1"
  [[ -e "${rc}" || "${rc}" == "${HOME}/.profile" ]] || return 0
  [[ -e "${rc}" ]] || : > "${rc}"
  python3 - "${rc}" "${LOCAL_BIN_BEGIN}" "${LOCAL_BIN_END}" "${LOCAL_BIN_BLOCK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
begin, end, body = sys.argv[2], sys.argv[3], sys.argv[4]
text = p.read_text() if p.exists() else ""
block = f"{begin}\n{body}\n{end}\n"
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    new = pre.rstrip() + ("\n\n" if pre.strip() else "") + block + post.lstrip()
else:
    new = text.rstrip() + ("\n\n" if text.strip() else "") + block
p.write_text(new)
PY
}
ensure_local_bin_on_path "${HOME}/.profile"
[[ -e "${HOME}/.bashrc"   ]] && ensure_local_bin_on_path "${HOME}/.bashrc"   || true
[[ -e "${HOME}/.zshrc"    ]] && ensure_local_bin_on_path "${HOME}/.zshrc"    || true
[[ -e "${HOME}/.zprofile" ]] && ensure_local_bin_on_path "${HOME}/.zprofile" || true

echo "OK. New shell, then: opencode   pi   (binaries under ~/.local/bin)"
EOF
  chmod +x "${t}/install.sh"
}

build_mac_m1() {
  local t="${OUT}/mac-m1"
  rm -rf "${t}/llama.cpp" "${t}/opencode" "${t}/node"
  mkdir -p "${t}/llama.cpp" "${t}/opencode"
  read -r tag url <<< "$(resolve_llamacpp_asset "macos-arm64" || die "no macos-arm64 asset")"
  echo "mac-m1: llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp"

  read -r oc_tag oc_url <<< "$(resolve_opencode_asset "opencode-darwin-arm64.zip" || die "no opencode darwin-arm64 asset")"
  echo "mac-m1: opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode"
  chmod +x "${t}/opencode/opencode" 2>/dev/null || true

  prepare_node_runtime "${t}" darwin-arm64

  install -m 755 "${SCRIPT_DIR}/opencode_privacy.sh" "${t}/opencode_privacy.sh"
  install -m 755 "${SCRIPT_DIR}/pi_privacy.sh" "${t}/pi_privacy.sh"

  # Foreground manual launch: single 35B-A3B at :8080 with mmproj. Mirrors
  # install_macbook_launchagent.sh: -c 131072 -np 1, Metal full offload, no
  # MoE split, no thread cap. The Mac Studio dual-instance setup with the
  # 27B dense companion is intentionally not part of the USB bundle.
  cat > "${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${HERE}/../models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
MMPROJ="$(ls "${HERE}/../models"/mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf 2>/dev/null | head -1)"
[[ -f "${MODEL}" ]] || { ls "${HERE}/../models"; echo "model not found"; exit 1; }
[[ -f "${MMPROJ}" ]] || { ls "${HERE}/../models"; echo "mmproj-35B-A3B not found"; exit 1; }
export DYLD_LIBRARY_PATH="${HERE}/llama.cpp${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
exec "${HERE}/llama.cpp/llama-server" \
  -m "${MODEL}" --mmproj "${MMPROJ}" \
  -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 -ngl 99 -fa on -np 1 \
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
# Install the single-instance Qwen stack into ~/Library/Application Support/slopcode
# and register a launchd user agent (no sudo, no admin):
#   com.slopcode.llamacpp-macbook -> Qwen3.6 35B-A3B Q4 (MoE) on :8080
# Mirrors install_macbook_launchagent.sh: -c 131072 -np 1, alias qwen,
# Metal full offload, with mmproj for image input. Hosts that want the
# dual-instance Mac Studio layout install via install_mac_launchagents.sh
# from the slopcode-infra repo, not the USB bundle.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/Library/Application Support/slopcode"
LEGACY_DEST="${HOME}/Library/Application Support/devstral"
LOG_DIR="${HOME}/Library/Logs/slopcode"
LEGACY_LOG_DIR="${HOME}/Library/Logs/devstral"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
mkdir -p "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/models" "${LOG_DIR}" "${AGENTS_DIR}"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
chmod +x "${DEST}/opencode/opencode" 2>/dev/null || true
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -exec cp -n {} "${DEST}/models/" \;
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf' -exec cp -n {} "${DEST}/models/" \;

MODEL="$(find "${DEST}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -print -quit)"
MMPROJ="$(find "${DEST}/models" -maxdepth 1 -type f -name 'mmproj-Qwen_Qwen3.6-35B-A3B-*.gguf' -print -quit)"
[[ -n "${MODEL}" ]] || { echo "model missing under ${DEST}/models"; exit 1; }
[[ -n "${MMPROJ}" ]] || { echo "mmproj-35B-A3B missing under ${DEST}/models"; exit 1; }

SERVER_BIN="${DEST}/llama.cpp/llama-server"
SERVER_DIR="${DEST}/llama.cpp"
LABEL="com.slopcode.llamacpp-macbook"
PLIST="${AGENTS_DIR}/${LABEL}.plist"
LOG="${LOG_DIR}/llamacpp.log"

bootout_legacy() {
  local label="$1"
  if launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "${label}"; then
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null \
      || launchctl unload "${AGENTS_DIR}/${label}.plist" 2>/dev/null || true
  fi
  rm -f "${AGENTS_DIR}/${label}.plist"
}
# Strip every previous label this project has shipped, including the
# devstral-named ones, so the new agent lands on a clean slot.
for legacy in com.qwenstack.llamacpp \
              com.devstral.llamacpp-local \
              com.devstral.llamacpp-35b-a3b \
              com.devstral.llamacpp-27b \
              com.devstral.llamacpp-macbook \
              com.slopcode.llamacpp-35b-a3b \
              com.slopcode.llamacpp-27b \
              com.slopcode.llamacpp-macbook; do
  bootout_legacy "${legacy}"
done
[[ -d "${LEGACY_DEST}" ]] && rm -rf "${LEGACY_DEST}"
[[ -d "${LEGACY_LOG_DIR}" ]] && rm -rf "${LEGACY_LOG_DIR}"

cat > "${PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${SERVER_BIN}</string>
    <string>-m</string><string>${MODEL}</string>
    <string>--mmproj</string><string>${MMPROJ}</string>
    <string>-c</string><string>131072</string>
    <string>-b</string><string>2048</string>
    <string>-ub</string><string>1024</string>
    <string>-ngl</string><string>99</string>
    <string>-fa</string><string>on</string>
    <string>-np</string><string>1</string>
    <string>--cache-type-k</string><string>q8_0</string>
    <string>--cache-type-v</string><string>q8_0</string>
    <string>--alias</string><string>qwen</string>
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
    <string>--port</string><string>8080</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_LIBRARY_PATH</key><string>${SERVER_DIR}</string>
  </dict>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
XML
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
echo "loaded ${LABEL} (35B-A3B Q4 on :8080, alias qwen)"

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
          "limit": {"context": 131072, "output": 16384},
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

# Bundled Node.js LTS + offline npm cache (no system node/npm, no admin).
mkdir -p "${DEST}/node"
cp -RL "${HERE}/node/." "${DEST}/node/"
chmod +x "${DEST}/node/bin/node" 2>/dev/null || true
NODE_BIN="${DEST}/node/bin/node"
NPM_CLI_JS="${DEST}/node/lib/node_modules/npm/bin/npm-cli.js"
PI_TARBALL="$(ls "${BUNDLE_ROOT}/pi"/mariozechner-pi-coding-agent-*.tgz 2>/dev/null | head -1)"
[[ -x "${NODE_BIN}" && -f "${NPM_CLI_JS}" && -f "${PI_TARBALL}" ]] \
  || { echo "bundled node or pi tarball missing under ${BUNDLE_ROOT}"; exit 1; }
echo "installing Pi Coding Agent from bundled Node + npm cache..."
PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 \
  "${NODE_BIN}" "${NPM_CLI_JS}" install -g \
    --prefix "${DEST}/node" \
    --offline --cache "${BUNDLE_ROOT}/pi/npm-cache" \
    "${PI_TARBALL}"

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
          "contextWindow": 131072,
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
PI_BIN_REAL="$(realpath "${DEST}/node/bin/pi")"
cat > "${HOME}/.local/bin/pi" <<PI_WRAP
#!/bin/sh
exec "${NODE_BIN}" "${PI_BIN_REAL}" "\$@"
PI_WRAP
chmod +x "${HOME}/.local/bin/pi"

LOCAL_BIN_BEGIN='# >>> slopcode-infra ~/.local/bin >>>'
LOCAL_BIN_END='# <<< slopcode-infra ~/.local/bin <<<'
LOCAL_BIN_BLOCK='case ":${PATH}:" in *":${HOME}/.local/bin:"*) ;; *) export PATH="${HOME}/.local/bin:${PATH}" ;; esac'
ensure_local_bin_on_path() {
  local rc="$1"
  [[ -e "${rc}" || "${rc}" == "${HOME}/.profile" ]] || return 0
  [[ -e "${rc}" ]] || : > "${rc}"
  python3 - "${rc}" "${LOCAL_BIN_BEGIN}" "${LOCAL_BIN_END}" "${LOCAL_BIN_BLOCK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
begin, end, body = sys.argv[2], sys.argv[3], sys.argv[4]
text = p.read_text() if p.exists() else ""
block = f"{begin}\n{body}\n{end}\n"
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    new = pre.rstrip() + ("\n\n" if pre.strip() else "") + block + post.lstrip()
else:
    new = text.rstrip() + ("\n\n" if text.strip() else "") + block
p.write_text(new)
PY
}
ensure_local_bin_on_path "${HOME}/.profile"
[[ -e "${HOME}/.bashrc"   ]] && ensure_local_bin_on_path "${HOME}/.bashrc"   || true
[[ -e "${HOME}/.zshrc"    ]] && ensure_local_bin_on_path "${HOME}/.zshrc"    || true
[[ -e "${HOME}/.zprofile" ]] && ensure_local_bin_on_path "${HOME}/.zprofile" || true

echo
echo "waiting for /v1/models on :8080 (up to 900s)..."
deadline=$(( $(date +%s) + 900 ))
while : ; do
  if curl -fsS "http://127.0.0.1:8080/v1/models" >/dev/null 2>&1; then
    echo "ready: http://127.0.0.1:8080/v1"
    break
  fi
  [[ $(date +%s) -ge ${deadline} ]] && { echo "timed out on port 8080" >&2; break; }
  sleep 2
done

echo "OK. New shell, then: opencode   pi   (binaries under ~/.local/bin)"
EOF
  chmod +x "${t}/install.sh"
}

build_windows_arc() {
  local t="${OUT}/windows-arc"
  rm -rf "${t}/llama.cpp" "${t}/opencode" "${t}/node"
  mkdir -p "${t}/llama.cpp" "${t}/opencode"
  read -r tag url <<< "$(resolve_llamacpp_asset "win-vulkan-x64" || die "no win-vulkan-x64 asset")"
  echo "windows-arc: llama.cpp ${tag}"
  fetch_archive "${url}" "${t}/llama.cpp"

  read -r oc_tag oc_url <<< "$(resolve_opencode_asset "opencode-windows-x64.zip" || die "no opencode windows-x64 asset")"
  echo "windows-arc: opencode ${oc_tag}"
  fetch_archive "${oc_url}" "${t}/opencode"

  prepare_node_runtime "${t}" win-x64

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
powershell -NoProfile -Command "try { [Math]::Max(2, (Get-CimInstance Win32_Processor | Measure-Object -Sum NumberOfCores).Sum - 2) } catch { [Math]::Max(2, [int]($env:NUMBER_OF_PROCESSORS) / 2 - 1) }" > "%TEMP%\slopcode_threads.txt" 2>nul
if exist "%TEMP%\slopcode_threads.txt" (
  set /p THREADS=<"%TEMP%\slopcode_threads.txt"
  del "%TEMP%\slopcode_threads.txt"
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
REM Install the local Qwen stack into %USERPROFILE%\slopcode and register a
REM Startup shortcut so the server launches at every logon. No admin, no UAC:
REM the Startup folder and %USERPROFILE% are always user-writable.
setlocal EnableDelayedExpansion
set HERE=%~dp0
set BUNDLE_ROOT=%HERE%..
set DEST=%USERPROFILE%\slopcode
set LEGACY_DEST=%USERPROFILE%\devstral
set STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
set OC_CFG_DIR=%USERPROFILE%\.config\opencode
set OC_CFG=%OC_CFG_DIR%\opencode.json

REM Strip the prior devstral-named startup shortcut and install dir so the
REM new slopcode-llamacpp shortcut doesn't run alongside a stale one.
if exist "%STARTUP%\devstral-llamacpp.bat" del /Q "%STARTUP%\devstral-llamacpp.bat" >nul
if exist "%LEGACY_DEST%" rmdir /S /Q "%LEGACY_DEST%" >nul 2>&1

echo [1/7] creating %DEST%
if not exist "%DEST%" mkdir "%DEST%"
if not exist "%DEST%\llama.cpp" mkdir "%DEST%\llama.cpp"
if not exist "%DEST%\opencode" mkdir "%DEST%\opencode"
if not exist "%DEST%\node" mkdir "%DEST%\node"
if not exist "%DEST%\models" mkdir "%DEST%\models"

echo [2/7] copying binaries, bundled node, and model (this takes a while for the GGUF)...
xcopy /E /Y /I /Q "%HERE%llama.cpp\*" "%DEST%\llama.cpp\" >nul
xcopy /E /Y /I /Q "%HERE%opencode\*" "%DEST%\opencode\" >nul
xcopy /E /Y /I /Q "%HERE%node\*" "%DEST%\node\" >nul
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

echo [3/7] detecting physical cores and writing %DEST%\run-llamacpp.bat
set THREADS=
powershell -NoProfile -Command "try { [Math]::Max(2, (Get-CimInstance Win32_Processor | Measure-Object -Sum NumberOfCores).Sum - 2) } catch { [Math]::Max(2, [int]($env:NUMBER_OF_PROCESSORS) / 2 - 1) }" > "%TEMP%\slopcode_threads.txt" 2>nul
if exist "%TEMP%\slopcode_threads.txt" (
  set /p THREADS=<"%TEMP%\slopcode_threads.txt"
  del "%TEMP%\slopcode_threads.txt"
)
if "!THREADS!"=="" set /a THREADS=%NUMBER_OF_PROCESSORS%/2 - 1
if !THREADS! LSS 2 set THREADS=2
echo     using --threads !THREADS! --threads-http 4
> "%DEST%\run-llamacpp.bat" echo @echo off
>> "%DEST%\run-llamacpp.bat" echo start "slopcode-llamacpp" /MIN "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --host 0.0.0.0 --port 8080

echo [4/7] installing Startup shortcut at "%STARTUP%\slopcode-llamacpp.bat"
if not exist "%STARTUP%" mkdir "%STARTUP%"
copy /Y "%DEST%\run-llamacpp.bat" "%STARTUP%\slopcode-llamacpp.bat" >nul

echo [5/7] writing OpenCode config to %OC_CFG%
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

echo [6/7] pinning opencode privacy env vars in HKCU\Environment (no admin)
setx OPENCODE_DISABLE_AUTOUPDATE 1 >nul
setx OPENCODE_DISABLE_SHARE 1 >nul
setx OPENCODE_DISABLE_MODELS_FETCH 1 >nul
setx OPENCODE_DISABLE_LSP_DOWNLOAD 1 >nul
setx OPENCODE_DISABLE_DEFAULT_PLUGINS 1 >nul
setx OPENCODE_DISABLE_EMBEDDED_WEB_UI 1 >nul
setx PI_TELEMETRY 0 >nul
setx PI_SKIP_VERSION_CHECK 1 >nul

echo [7/7] installing Pi Coding Agent from bundled Node + npm cache (no system node, no admin)
set NODE_EXE=%DEST%\node\node.exe
set NPM_CLI_JS=%DEST%\node\node_modules\npm\bin\npm-cli.js
set PI_TARBALL=
for %%F in ("%BUNDLE_ROOT%\pi\mariozechner-pi-coding-agent-*.tgz") do set PI_TARBALL=%%~fF
if not exist "%NODE_EXE%" (
  echo bundled node missing under %DEST%\node
  exit /b 1
)
if not exist "%NPM_CLI_JS%" (
  echo bundled npm-cli.js missing under %DEST%\node\node_modules\npm
  exit /b 1
)
if not defined PI_TARBALL (
  echo pi tarball missing under %BUNDLE_ROOT%\pi
  exit /b 1
)
"%NODE_EXE%" "%NPM_CLI_JS%" install -g --prefix "%DEST%\node" --offline --cache "%BUNDLE_ROOT%\pi\npm-cache" "%PI_TARBALL%"
if errorlevel 1 exit /b 1

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
>> "%PI_MODELS%" echo           "contextWindow": 262144,
>> "%PI_MODELS%" echo           "maxTokens": 16384,
>> "%PI_MODELS%" echo           "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
>> "%PI_MODELS%" echo         }
>> "%PI_MODELS%" echo       ]
>> "%PI_MODELS%" echo     }
>> "%PI_MODELS%" echo   }
>> "%PI_MODELS%" echo }

REM Idempotent prepend of the opencode and bundled node dirs to user PATH
REM via PowerShell (reads HKCU\Environment directly so successive runs don't
REM duplicate). After install, both opencode and pi are reachable in any new
REM cmd/powershell window without admin and without a system node.
set OC_BIN_DIR=%DEST%\opencode
set NODE_BIN_DIR=%DEST%\node
powershell -NoProfile -Command ^
  "$u = [Environment]::GetEnvironmentVariable('Path','User');" ^
  "$dirs = @('%OC_BIN_DIR%', '%NODE_BIN_DIR%');" ^
  "if ($null -eq $u) { $u = '' }" ^
  "$parts = $u.Split(';') | Where-Object { $_ -and -not ($dirs -contains $_) };" ^
  "$new = ($dirs + $parts) -join ';';" ^
  "[Environment]::SetEnvironmentVariable('Path', $new, 'User')"
echo     (env vars and PATH take effect in new cmd/powershell windows, not this one)

echo.
echo Starting the server now (will also auto-start at every logon)...
start "slopcode-llamacpp" /MIN "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" --mmproj "%MMPROJ%" -c 262144 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 1024 -ngl 99 -fa on --n-cpu-moe 35 -np 1 --threads !THREADS! --threads-http 4 --alias qwen --jinja --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0.0 --repeat-penalty 1.0 --reasoning-format deepseek --reasoning-budget 4096 --no-context-shift --reasoning on --host 0.0.0.0 --port 8080

echo.
echo OK. Wait ~30s for the model to load, then open a NEW command prompt
echo so the OPENCODE_DISABLE_* env vars and PATH are picked up, and run:
echo     opencode
echo     pi
echo (to stop the server: open Task Manager and end llama-server.exe)
EOF
}

cat > "${OUT}/README.txt" <<'EOF'
slopcode USB bundle (Qwen3.6 local stack)
=========================================

Three self-contained per-OS directories plus a shared models/ folder.
Every per-OS directory carries its own Node.js LTS, so Pi installs fully
offline and does not need a pre-existing node/npm on the host.

  linux-cuda/   Linux + Vulkan/CUDA GPU (install.sh, no sudo)
                  -> single 35B-A3B :8080, 256K window, --n-cpu-moe 35,
                     image input via mmproj
                  -> bundled node/ used to install Pi offline into ~/.local/
                     slopcode/node and expose it as ~/.local/bin/pi
  mac-m1/       Apple Silicon Mac (install.sh, no sudo)
                  -> single 35B-A3B :8080, 128K window, Metal full offload,
                     image input via mmproj. Mirrors install_macbook_launchagent.sh.
                     The Mac Studio dual-instance layout is set up directly
                     from the slopcode-infra repo, not from the USB.
                  -> bundled node/ used to install Pi offline into the
                     install dir and expose it as ~/.local/bin/pi
  windows-arc/  Windows + Vulkan GPU (install.bat, no admin)
                  -> single 35B-A3B :8080, 256K window, --n-cpu-moe 35,
                     image input via mmproj
                  -> bundled node/ used to install Pi offline into
                     %USERPROFILE%\slopcode\node, prepended to user PATH
  pi/           Pi Coding Agent npm tarball + fully populated offline cache
                (consumed by every per-OS installer; no install-*.sh shims)
  models/       Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf       (~20 GB, all platforms)
                mmproj-Qwen_Qwen3.6-35B-A3B-bf16.gguf (~1 GB,  vision projector,
                                                       all platforms)

Requires exFAT formatting on the USB stick (FAT32 cannot hold the 20 GB
GGUF; exFAT is mounted natively by Windows and macOS and supported by
Linux kernels since 5.7).

To install on a target machine:

  Linux/Mac:   ./<target>/install.sh
  Windows:     .\windows-arc\install.bat

The installer copies llama.cpp + opencode + bundled node + the model into
the user's home directory, registers a user-level service (systemd --user
on Linux, a launchd user agent on Mac, a Startup shortcut on Windows),
runs an offline `npm install -g --prefix <dest>/node --offline --cache
<bundle>/pi/npm-cache` using the bundled Node, and writes OpenCode + Pi
configs that disable every outbound network call beyond the local LLM
endpoint. Image input is enabled via the bundled vision projector. No
sudo, no admin, no internet required at install time.

Smoke test:
  curl -s http://127.0.0.1:8080/v1/models

Then in a new shell run `opencode` or `pi` directly.
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
