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
#   install.sh or install.bat   copies into ~/.local/qwenstack and wires up a user service
#   start.sh or start.bat       foreground launch for manual testing
#
# The model lives once at <out>/models/ (single 20 GB Q4_K_M GGUF) and is
# referenced by every per-OS start script via a relative path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have curl || die "curl is required"
have unzip || die "unzip is required"
have python3 || die "python3 is required"

TARGETS=()
OUT=""
LLAMACPP_TAG="${LLAMACPP_TAG:-}"
OPENCODE_TAG="${OPENCODE_TAG:-}"
SKIP_MODEL="${SKIP_MODEL:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --llamacpp-tag) LLAMACPP_TAG="$2"; shift 2 ;;
    --opencode-tag) OPENCODE_TAG="$2"; shift 2 ;;
    --skip-model) SKIP_MODEL="true"; shift ;;
    all) TARGETS=(linux-cuda mac-m1 windows-arc); shift ;;
    linux-cuda|mac-m1|windows-arc) TARGETS+=("$1"); shift ;;
    -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${OUT}" ]] || die "--out is required"
[[ "${#TARGETS[@]}" -gt 0 ]] || die "specify a target: linux-cuda|mac-m1|windows-arc|all"

mkdir -p "${OUT}/models"

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
  if [[ -n "${inner}" ]]; then
    cp -R "${inner}/." "${dest}/"
  else
    cp -R "${tmp}/unpacked/." "${dest}/"
  fi
  rm -rf "${tmp}"
}

copy_model() {
  [[ "${SKIP_MODEL}" == "true" ]] && { echo "skip-model: leaving ${OUT}/models untouched"; return; }
  local dst="${OUT}/models"
  local primary
  primary="$(python3 "${SCRIPT_DIR}/llamacpp_models.py" resolve qwen3.6-35b-a3b-q4 2>/dev/null || true)"
  [[ -n "${primary}" && -f "${primary}" ]] || die "blessed model not cached; run: python3 scripts/llamacpp_models.py prefetch"
  local src_dir
  src_dir="$(dirname "${primary}")"
  echo "copying model from ${src_dir} to ${dst}"
  find "${src_dir}" -maxdepth 1 -type f -name '*.gguf' -exec cp -n {} "${dst}/" \;
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

  cat > "${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${HERE}/../models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
[[ -f "${MODEL}" ]] || { ls "${HERE}/../models"; echo "model not found"; exit 1; }
exec "${HERE}/llama.cpp/llama-server" \
  -m "${MODEL}" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 512 -ngl 99 -fa on --cpu-moe \
  --alias qwen --jinja --reasoning-format deepseek \
  --host 127.0.0.1 --port 8080
EOF
  chmod +x "${t}/start.sh"

  cat > "${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
# Install qwenstack into ~/.local/qwenstack and register a systemd --user service.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/.local/qwenstack"
mkdir -p "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/models"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
chmod +x "${DEST}/opencode/opencode" 2>/dev/null || true
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name '*.gguf' -exec cp -n {} "${DEST}/models/" \;

MODEL="$(find "${DEST}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -print -quit)"
[[ -n "${MODEL}" ]] || { echo "model missing under ${DEST}/models"; exit 1; }

UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "${UNIT_DIR}"
cat > "${UNIT_DIR}/qwenstack-llamacpp.service" <<UNIT
[Unit]
Description=qwenstack llama.cpp (Qwen3.6 35B A3B Q4)
After=default.target

[Service]
ExecStart=${DEST}/llama.cpp/llama-server -m ${MODEL} -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 -ngl 99 -fa on --cpu-moe --alias qwen --jinja --reasoning-format deepseek --host 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now qwenstack-llamacpp.service
sleep 2
systemctl --user status --no-pager qwenstack-llamacpp.service | head -15

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
          "tool_call": true,
          "options": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096}
        }
      }
    }
  }
}
JSON

bash "${HERE}/opencode_privacy.sh"

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

  cat > "${t}/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${HERE}/../models/Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf"
[[ -f "${MODEL}" ]] || { ls "${HERE}/../models"; echo "model not found"; exit 1; }
exec "${HERE}/llama.cpp/llama-server" \
  -m "${MODEL}" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 512 -ngl 99 -fa on \
  --alias qwen --jinja --reasoning-format deepseek \
  --host 127.0.0.1 --port 8080
EOF
  chmod +x "${t}/start.sh"

  cat > "${t}/install.sh" <<'EOF'
#!/usr/bin/env bash
# Install qwenstack into ~/Library/Application Support/qwenstack and register
# a launchd user agent. No sudo, no admin.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(cd "${HERE}/.." && pwd)"
DEST="${HOME}/Library/Application Support/qwenstack"
mkdir -p "${DEST}/llama.cpp" "${DEST}/opencode" "${DEST}/models" "${HOME}/Library/Logs/qwenstack"
cp -R "${HERE}/llama.cpp/." "${DEST}/llama.cpp/"
cp -R "${HERE}/opencode/." "${DEST}/opencode/"
chmod +x "${DEST}/opencode/opencode" 2>/dev/null || true
find "${BUNDLE_ROOT}/models" -maxdepth 1 -type f -name '*.gguf' -exec cp -n {} "${DEST}/models/" \;

MODEL="$(find "${DEST}/models" -maxdepth 1 -type f -name 'Qwen_Qwen3.6-35B-A3B-Q4_K_M*.gguf' -print -quit)"
[[ -n "${MODEL}" ]] || { echo "model missing under ${DEST}/models"; exit 1; }

PLIST="${HOME}/Library/LaunchAgents/com.qwenstack.llamacpp.plist"
cat > "${PLIST}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.qwenstack.llamacpp</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProgramArguments</key>
  <array>
    <string>${DEST}/llama.cpp/llama-server</string>
    <string>-m</string><string>${MODEL}</string>
    <string>-c</string><string>131072</string>
    <string>--cache-type-k</string><string>q8_0</string>
    <string>--cache-type-v</string><string>q8_0</string>
    <string>-b</string><string>2048</string>
    <string>-ub</string><string>512</string>
    <string>-ngl</string><string>99</string>
    <string>-fa</string><string>on</string>
    <string>--alias</string><string>qwen</string>
    <string>--jinja</string>
    <string>--reasoning-format</string><string>deepseek</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>8080</string>
  </array>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/qwenstack/llamacpp.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/qwenstack/llamacpp.err</string>
</dict>
</plist>
XML
launchctl unload "${PLIST}" 2>/dev/null || true
launchctl load "${PLIST}"

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
          "tool_call": true,
          "options": {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "presence_penalty": 0.0, "repeat_penalty": 1.0, "thinking_budget": 4096}
        }
      }
    }
  }
}
JSON

bash "${HERE}/opencode_privacy.sh"

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
setlocal
set HERE=%~dp0
set MODEL=%HERE%..\models\Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf
if not exist "%MODEL%" (
  echo Model not found under %HERE%..\models
  dir "%HERE%..\models"
  exit /b 1
)
"%HERE%llama.cpp\llama-server.exe" ^
  -m "%MODEL%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 ^
  -b 2048 -ub 512 -ngl 99 -fa on --cpu-moe ^
  --alias qwen --jinja --reasoning-format deepseek ^
  --host 127.0.0.1 --port 8080
EOF

  cat > "${t}/install.bat" <<'EOF'
@echo off
REM Install qwenstack into %USERPROFILE%\qwenstack and register a Startup
REM shortcut so the server launches at every logon. No admin, no UAC:
REM the Startup folder and %USERPROFILE% are always user-writable.
setlocal EnableDelayedExpansion
set HERE=%~dp0
set BUNDLE_ROOT=%HERE%..
set DEST=%USERPROFILE%\qwenstack
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
xcopy /Y /I /Q "%BUNDLE_ROOT%\models\*.gguf" "%DEST%\models\" >nul

set MODEL=%DEST%\models\Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf
if not exist "%MODEL%" (
  echo Model missing under %DEST%\models
  exit /b 1
)

echo [3/6] writing %DEST%\run-llamacpp.bat
> "%DEST%\run-llamacpp.bat" echo @echo off
>> "%DEST%\run-llamacpp.bat" echo start "qwenstack-llamacpp" /MIN "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 -ngl 99 -fa on --cpu-moe --alias qwen --jinja --reasoning-format deepseek --host 127.0.0.1 --port 8080

echo [4/6] installing Startup shortcut at "%STARTUP%\qwenstack-llamacpp.bat"
if not exist "%STARTUP%" mkdir "%STARTUP%"
copy /Y "%DEST%\run-llamacpp.bat" "%STARTUP%\qwenstack-llamacpp.bat" >nul

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
>> "%OC_CFG%" echo           "limit": { "context": 131072, "output": 16384 },
>> "%OC_CFG%" echo           "reasoning": true,
>> "%OC_CFG%" echo           "tool_call": true,
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
start "qwenstack-llamacpp" /MIN "%DEST%\llama.cpp\llama-server.exe" -m "%MODEL%" -c 131072 --cache-type-k q8_0 --cache-type-v q8_0 -b 2048 -ub 512 -ngl 99 -fa on --cpu-moe --alias qwen --jinja --reasoning-format deepseek --host 127.0.0.1 --port 8080

echo.
echo OK. Wait ~30s for the model to load, then open a NEW command prompt
echo so the OPENCODE_DISABLE_* env vars and PATH are picked up, and run:
echo     opencode
echo (to stop the server: open Task Manager and end llama-server.exe)
EOF
}

cat > "${OUT}/README.txt" <<'EOF'
qwenstack USB bundle
====================

Three self-contained per-OS directories plus a shared models/ folder:

  linux-cuda/   NVIDIA GPU + Linux (install.sh, no sudo)
  mac-m1/       Apple Silicon Mac (install.sh, no sudo)
  windows-arc/  Intel Arc GPU + Windows, Vulkan backend (install.bat, no admin)
  models/       Qwen3.6 35B A3B Q4_K_M (single GGUF, ~20 GB)

Requires exFAT formatting on the USB stick (FAT32 cannot hold the 20 GB
GGUF; exFAT is natively mounted by Windows and macOS and supported by
Linux kernels since 5.7).

To install on a target machine:

  Linux/Mac:   ./<target>/install.sh
  Windows:     .\windows-arc\install.bat

The installer copies llama.cpp + opencode + the model into the user's
home directory, registers a user-level service (systemd --user, launchd,
or schtasks ONLOGON), writes an OpenCode config, and exits.

Smoke test:
  curl -s http://127.0.0.1:8080/v1/models

Then launch opencode from the bundle's opencode/ directory.
EOF

for t in "${TARGETS[@]}"; do
  case "${t}" in
    linux-cuda)   build_linux_cuda ;;
    mac-m1)       build_mac_m1 ;;
    windows-arc)  build_windows_arc ;;
    *) die "unknown target: ${t}" ;;
  esac
done

copy_model

echo
echo "bundle built at ${OUT}:"
du -sh "${OUT}/"* 2>/dev/null | sort -k2
