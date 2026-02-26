#!/usr/bin/env bash
# Create offline installation package for Windows
# Includes: llama.cpp + Qwen3.5-35B-A3B, LM Studio fallback, OpenCode, and Vibe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${1:-${HOME}/offline-ai-package}"
MODELS_DIR="${HOME}/.lmstudio/models"
LLAMACPP_CACHE_DIR="${HOME}/Library/Caches/llama.cpp"

# Versions
LMSTUDIO_VERSION="0.4.0-18"
OPENCODE_VERSION="1.2.15"
VIBE_VERSION="2.0.1"
LLAMACPP_VERSION="${LLAMACPP_VERSION:-b8157}"
LLAMACPP_WINDOWS_FLAVOR="${LLAMACPP_WINDOWS_FLAVOR:-win-vulkan-x64}"
LLAMACPP_ASSET="llama-${LLAMACPP_VERSION}-bin-${LLAMACPP_WINDOWS_FLAVOR}.zip"
LLAMACPP_MODEL_FILE="${LLAMACPP_MODEL_FILE:-unsloth_Qwen3.5-35B-A3B-GGUF_Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf}"

echo "Creating offline AI package at: ${PACKAGE_DIR}"
echo "==========================================="

mkdir -p "${PACKAGE_DIR}"/{installers,models,configs,scripts}

# ============================================================
# 1. Download Windows installers
# ============================================================
echo ""
echo "[1/4] Downloading Windows installers..."

# LM Studio Windows
LMSTUDIO_WIN_URL="https://installers.lmstudio.ai/win32/x64/${LMSTUDIO_VERSION}/LM-Studio-${LMSTUDIO_VERSION}-x64.exe"
if [[ ! -f "${PACKAGE_DIR}/installers/LM-Studio-${LMSTUDIO_VERSION}-x64.exe" ]]; then
    echo "  Downloading LM Studio ${LMSTUDIO_VERSION} for Windows..."
    curl -L -# -o "${PACKAGE_DIR}/installers/LM-Studio-${LMSTUDIO_VERSION}-x64.exe" "${LMSTUDIO_WIN_URL}" || echo "  Warning: LM Studio download failed"
else
    echo "  LM Studio already downloaded"
fi

# OpenCode Windows
OPENCODE_WIN_URL="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-windows-amd64.exe"
if [[ ! -f "${PACKAGE_DIR}/installers/opencode-${OPENCODE_VERSION}-windows-amd64.exe" ]]; then
    echo "  Downloading OpenCode ${OPENCODE_VERSION} for Windows..."
    curl -L -# -o "${PACKAGE_DIR}/installers/opencode-${OPENCODE_VERSION}-windows-amd64.exe" "${OPENCODE_WIN_URL}" || echo "  Warning: OpenCode download failed"
else
    echo "  OpenCode already downloaded"
fi

# llama.cpp Windows runtime (used for qwen35-a3b-local)
LLAMACPP_WIN_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_VERSION}/${LLAMACPP_ASSET}"
if [[ ! -f "${PACKAGE_DIR}/installers/${LLAMACPP_ASSET}" ]]; then
    echo "  Downloading llama.cpp ${LLAMACPP_VERSION} (${LLAMACPP_WINDOWS_FLAVOR}) for Windows..."
    curl -L -# -o "${PACKAGE_DIR}/installers/${LLAMACPP_ASSET}" "${LLAMACPP_WIN_URL}" || echo "  Warning: llama.cpp download failed"
else
    echo "  llama.cpp runtime already downloaded"
fi

# Vibe is Python-based, we'll include the wheel
VIBE_WHEEL_URL="https://files.pythonhosted.org/packages/py3/m/mistral_vibe/mistral_vibe-${VIBE_VERSION}-py3-none-any.whl"
if [[ ! -f "${PACKAGE_DIR}/installers/mistral_vibe-${VIBE_VERSION}-py3-none-any.whl" ]]; then
    echo "  Downloading Mistral Vibe ${VIBE_VERSION} wheel..."
    curl -L -# -o "${PACKAGE_DIR}/installers/mistral_vibe-${VIBE_VERSION}-py3-none-any.whl" "${VIBE_WHEEL_URL}" || echo "  Warning: Vibe download failed"
else
    echo "  Vibe wheel already downloaded"
fi

# ============================================================
# 2. Copy models
# ============================================================
echo ""
echo "[2/4] Copying models..."

if [[ -d "${MODELS_DIR}" ]]; then
    # Copy only complete models (>1GB)
    find "${MODELS_DIR}" -name "*.gguf" -type f -size +1G | while read -r model; do
        rel_path="${model#${MODELS_DIR}/}"
        dest_dir="${PACKAGE_DIR}/models/$(dirname "${rel_path}")"
        mkdir -p "${dest_dir}"
        if [[ ! -f "${PACKAGE_DIR}/models/${rel_path}" ]]; then
            echo "  Copying: ${rel_path} ($(du -h "${model}" | cut -f1))"
            cp "${model}" "${dest_dir}/"
        else
            echo "  Already copied: ${rel_path}"
        fi
    done
else
    echo "  No models found at ${MODELS_DIR}"
fi

# Copy llama.cpp model cache for Qwen3.5-35B-A3B
mkdir -p "${PACKAGE_DIR}/models-llamacpp"
if [[ -f "${LLAMACPP_CACHE_DIR}/${LLAMACPP_MODEL_FILE}" ]]; then
    if [[ ! -f "${PACKAGE_DIR}/models-llamacpp/${LLAMACPP_MODEL_FILE}" ]]; then
        echo "  Copying llama.cpp model: ${LLAMACPP_MODEL_FILE} ($(du -h "${LLAMACPP_CACHE_DIR}/${LLAMACPP_MODEL_FILE}" | cut -f1))"
        cp "${LLAMACPP_CACHE_DIR}/${LLAMACPP_MODEL_FILE}" "${PACKAGE_DIR}/models-llamacpp/"
    else
        echo "  Already copied llama.cpp model: ${LLAMACPP_MODEL_FILE}"
    fi
else
    echo "  Warning: ${LLAMACPP_CACHE_DIR}/${LLAMACPP_MODEL_FILE} not found"
    echo "  Run llama.cpp once with:"
    echo "    llama-server -hf unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL"
fi

# ============================================================
# 3. Create Windows batch scripts
# ============================================================
echo ""
echo "[3/4] Creating Windows installation scripts..."

# Main install script
cat > "${PACKAGE_DIR}/scripts/install-all.bat" << 'BATCH'
@echo off
echo ============================================
echo Offline AI Package Installer for Windows
echo ============================================
echo.

REM Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Please run as Administrator!
    pause
    exit /b 1
)

set SCRIPT_DIR=%~dp0
set PACKAGE_DIR=%SCRIPT_DIR%..

echo [1/5] Installing LM Studio...
if exist "%PACKAGE_DIR%\installers\LM-Studio-*-x64.exe" (
    for %%f in ("%PACKAGE_DIR%\installers\LM-Studio-*-x64.exe") do (
        echo Installing %%f...
        start /wait "" "%%f" /S
    )
) else (
    echo LM Studio installer not found!
)

echo.
echo [2/5] Installing OpenCode...
if exist "%PACKAGE_DIR%\installers\opencode-*-windows-amd64.exe" (
    for %%f in ("%PACKAGE_DIR%\installers\opencode-*-windows-amd64.exe") do (
        if not exist "%USERPROFILE%\.local\bin" mkdir "%USERPROFILE%\.local\bin"
        copy "%%f" "%USERPROFILE%\.local\bin\opencode.exe"
        echo OpenCode copied to %USERPROFILE%\.local\bin\opencode.exe
    )
) else (
    echo OpenCode installer not found!
)

echo.
echo [3/5] Installing llama.cpp runtime...
if not exist "%USERPROFILE%\.local\llama.cpp" mkdir "%USERPROFILE%\.local\llama.cpp"
if exist "%PACKAGE_DIR%\installers\llama-*-bin-win-*.zip" (
    for %%f in ("%PACKAGE_DIR%\installers\llama-*-bin-win-*.zip") do (
        echo Extracting %%f to %USERPROFILE%\.local\llama.cpp ...
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%%f' -DestinationPath '%USERPROFILE%\\.local\\llama.cpp' -Force"
    )
) else (
    echo llama.cpp runtime zip not found!
)

echo.
echo [4/5] Installing Mistral Vibe...
where python >nul 2>&1
if %errorLevel% equ 0 (
    if exist "%PACKAGE_DIR%\installers\mistral_vibe-*.whl" (
        for %%f in ("%PACKAGE_DIR%\installers\mistral_vibe-*.whl") do (
            pip install "%%f" --no-deps --force-reinstall
        )
    )
) else (
    echo Python not found! Install Python 3.12+ first, then run install-vibe.bat
)

echo.
echo [5/5] Copying models...
call "%SCRIPT_DIR%\copy-models.bat"
call "%SCRIPT_DIR%\copy-qwen-llamacpp.bat"

echo.
echo ============================================
echo Installation complete!
echo ============================================
echo.
echo Next steps:
echo 1. Start llama.cpp server: scripts\start-llamacpp-qwen35.bat
echo 2. Configure OpenCode for llama.cpp: scripts\configure-opencode.bat
echo 3. Run: opencode
echo.
echo Fallback path (if llama.cpp setup is problematic):
echo - Use scripts\configure-opencode-lmstudio.bat and LM Studio server on port 1234.
echo.
pause
BATCH

# Model copy script
cat > "${PACKAGE_DIR}/scripts/copy-models.bat" << 'BATCH'
@echo off
set SCRIPT_DIR=%~dp0
set PACKAGE_DIR=%SCRIPT_DIR%..
set LMSTUDIO_MODELS=%USERPROFILE%\.lmstudio\models

echo Copying models to %LMSTUDIO_MODELS%...

if not exist "%LMSTUDIO_MODELS%" mkdir "%LMSTUDIO_MODELS%"

xcopy "%PACKAGE_DIR%\models\*" "%LMSTUDIO_MODELS%\" /E /I /Y

echo Models copied successfully!
BATCH

# llama.cpp model copy script
cat > "${PACKAGE_DIR}/scripts/copy-qwen-llamacpp.bat" << BATCH
@echo off
set SCRIPT_DIR=%~dp0
set PACKAGE_DIR=%SCRIPT_DIR%..
set LLAMACPP_CACHE=%USERPROFILE%\.cache\llama.cpp

if not exist "%LLAMACPP_CACHE%" mkdir "%LLAMACPP_CACHE%"

if exist "%PACKAGE_DIR%\models-llamacpp\${LLAMACPP_MODEL_FILE}" (
    copy /Y "%PACKAGE_DIR%\models-llamacpp\${LLAMACPP_MODEL_FILE}" "%LLAMACPP_CACHE%\${LLAMACPP_MODEL_FILE}" >nul
    echo Copied ${LLAMACPP_MODEL_FILE} to %LLAMACPP_CACHE%
) else (
    echo Warning: %PACKAGE_DIR%\models-llamacpp\${LLAMACPP_MODEL_FILE} not found
)
BATCH

# llama.cpp server starter script for qwen35-a3b-local
cat > "${PACKAGE_DIR}/scripts/start-llamacpp-qwen35.bat" << BATCH
@echo off
set LLAMACPP_HOME=%USERPROFILE%\.local\llama.cpp
set MODEL_CACHE=%USERPROFILE%\.cache\llama.cpp
set MODEL_FILE=${LLAMACPP_MODEL_FILE}

set LLAMA_SERVER=
for /r "%LLAMACPP_HOME%" %%f in (llama-server.exe) do (
    set LLAMA_SERVER=%%f
    goto :found_server
)

:found_server
if "%LLAMA_SERVER%"=="" (
    echo Error: llama-server.exe not found under %LLAMACPP_HOME%
    echo Extract a llama-*-bin-win-*.zip into %LLAMACPP_HOME%
    pause
    exit /b 1
)

if not exist "%MODEL_CACHE%\%MODEL_FILE%" (
    echo Error: model not found at %MODEL_CACHE%\%MODEL_FILE%
    echo Run scripts\copy-qwen-llamacpp.bat first.
    pause
    exit /b 1
)

echo Starting llama.cpp with Qwen3.5-35B-A3B...
"%LLAMA_SERVER%" ^
  -m "%MODEL_CACHE%\%MODEL_FILE%" ^
  -c 131072 ^
  -ngl 99 ^
  -ctk q8_0 ^
  -ctv q8_0 ^
  -sm none ^
  -mg 0 ^
  -np 1 ^
  -fa on ^
  -b 512 ^
  -ub 128 ^
  --temp 0.6 ^
  --top-p 0.95 ^
  --top-k 20 ^
  --min-p 0.0 ^
  --host 127.0.0.1 ^
  --port 8080 ^
  --jinja
BATCH

# OpenCode config script (llama.cpp / qwen35-a3b-local)
cat > "${PACKAGE_DIR}/scripts/configure-opencode.bat" << 'BATCH'
@echo off
set CONFIG_DIR=%USERPROFILE%\.config\opencode
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

echo Creating OpenCode config for local llama.cpp...

(
echo {
echo   "$schema": "https://opencode.ai/config.json",
echo   "model": "llamacpp/qwen35-a3b-local",
echo   "provider": {
echo     "llamacpp": {
echo       "npm": "@ai-sdk/openai-compatible",
echo       "name": "Local llama.cpp",
echo       "options": {
echo         "baseURL": "http://127.0.0.1:8080/v1"
echo       },
echo       "models": {
echo         "qwen35-a3b-local": {
echo           "name": "Qwen3.5-35B-A3B UD-Q4_K_XL (local)",
echo           "limit": {
echo             "context": 131072,
echo             "output": 32000
echo           }
echo         }
echo       }
echo     }
echo   },
echo   "share": "disabled",
echo   "autoupdate": false,
echo   "experimental": {
echo     "openTelemetry": false
echo   },
echo   "tools": {
echo     "websearch": false
echo   },
echo   "disabled_providers": ["exa", "openai", "anthropic", "google", "mistral", "groq", "xai", "ollama"]
echo }
) > "%CONFIG_DIR%\opencode.json"

echo Config saved to %CONFIG_DIR%\opencode.json
echo.
echo Make sure llama.cpp server is running on port 8080!
pause
BATCH

# OpenCode LM Studio fallback config
cat > "${PACKAGE_DIR}/scripts/configure-opencode-lmstudio.bat" << 'BATCH'
@echo off
set CONFIG_DIR=%USERPROFILE%\.config\opencode
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

echo Creating OpenCode config for LM Studio fallback...

(
echo {
echo   "$schema": "https://opencode.ai/config.json",
echo   "model": "lmstudio/qwen35-a3b-local",
echo   "provider": {
echo     "lmstudio": {
echo       "npm": "@ai-sdk/openai-compatible",
echo       "name": "LM Studio",
echo       "options": {
echo         "baseURL": "http://127.0.0.1:1234/v1",
echo         "apiKey": "lm-studio"
echo       },
echo       "models": {
echo         "qwen35-a3b-local": {
echo           "name": "Qwen3.5-35B-A3B (LM Studio)",
echo           "limit": {
echo             "context": 131072,
echo             "output": 32000
echo           }
echo         }
echo       }
echo     }
echo   }
echo }
) > "%CONFIG_DIR%\opencode.json"

echo Config saved to %CONFIG_DIR%\opencode.json
echo.
echo Make sure LM Studio server is running on port 1234!
pause
BATCH

# Vibe config script
cat > "${PACKAGE_DIR}/scripts/configure-vibe.bat" << 'BATCH'
@echo off
set CONFIG_DIR=%USERPROFILE%\.vibe
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

echo Creating Vibe config for local LM Studio...

(
echo # Mistral Vibe config for local LM Studio
echo active_model = "local"
echo enable_update_checks = false
echo api_timeout = 720.0
echo.
echo [[providers]]
echo name = "lmstudio"
echo api_base = "http://127.0.0.1:1234/v1"
echo api_key_env_var = ""
echo api_style = "openai"
echo backend = "generic"
echo.
echo [[models]]
echo name = "GLM-4.7-Flash-Q4_K_M"
echo provider = "lmstudio"
echo alias = "local"
echo temperature = 0.15
) > "%CONFIG_DIR%\config.toml"

echo Config saved to %CONFIG_DIR%\config.toml
echo.
echo Make sure LM Studio server is running on port 1234!
pause
BATCH

# README
cat > "${PACKAGE_DIR}/README.txt" << 'README'
Offline AI Package for Windows
==============================

Contents:
---------
installers/     - Windows installers/binaries for LM Studio, OpenCode, llama.cpp, Vibe
models/         - Pre-downloaded GGUF models for LM Studio
models-llamacpp/ - Qwen3.5-35B-A3B GGUF for llama.cpp
scripts/        - Installation and configuration batch scripts
configs/        - Sample configuration files

Quick Start:
------------
1. Run scripts\install-all.bat as Administrator
2. Run scripts\start-llamacpp-qwen35.bat (starts API on port 8080)
3. Run scripts\configure-opencode.bat
4. Run: opencode

Models Included:
----------------
- Qwen3.5-35B-A3B UD-Q4_K_XL (18GB) - default for llama.cpp + OpenCode
- GLM-4.7-Flash (17GB) - MoE with MLA support
- gpt-oss-20b (12GB) - Good for tool calling
- gpt-oss-120b (70GB) - Large MoE model

System Requirements:
--------------------
- Windows 10/11 64-bit
- 16GB+ RAM (32GB+ recommended)
- NVIDIA GPU with 8GB+ VRAM (optional but recommended)
- Python 3.12+ (for Vibe only)

Manual Installation:
--------------------
1. Install OpenCode: copy installers\opencode-*.exe to %USERPROFILE%\.local\bin\opencode.exe
2. Install llama.cpp runtime: unzip installers\llama-*-bin-win-*.zip into %USERPROFILE%\.local\llama.cpp
3. Copy Qwen model: copy models-llamacpp\*.gguf to %USERPROFILE%\.cache\llama.cpp\
4. Start llama.cpp: run scripts\start-llamacpp-qwen35.bat
5. Configure OpenCode: run scripts\configure-opencode.bat
6. Install LM Studio/Vibe only if needed

Troubleshooting:
----------------
- If llama.cpp setup is problematic, use LM Studio fallback:
  - configure OpenCode with scripts\configure-opencode-lmstudio.bat
  - run LM Studio API server on port 1234
- If LM Studio doesn't detect GPU, update NVIDIA drivers
- If models don't appear, restart LM Studio
- For Vibe, ensure Python 3.12+ is installed

Created by devstral-infra
README

chmod +x "${PACKAGE_DIR}/scripts/"*.bat 2>/dev/null || true

# ============================================================
# 4. Create manifest
# ============================================================
echo ""
echo "[4/4] Creating manifest..."

cat > "${PACKAGE_DIR}/manifest.txt" << MANIFEST
Offline AI Package Manifest
Generated: $(date -Iseconds)
Host: $(hostname)

Versions:
- LM Studio: ${LMSTUDIO_VERSION}
- OpenCode: ${OPENCODE_VERSION}
- llama.cpp: ${LLAMACPP_VERSION} (${LLAMACPP_WINDOWS_FLAVOR})
- Mistral Vibe: ${VIBE_VERSION}

Models:
MANIFEST

find "${PACKAGE_DIR}/models" "${PACKAGE_DIR}/models-llamacpp" -name "*.gguf" -type f 2>/dev/null | while read -r f; do
    echo "- $(basename "$f"): $(du -h "$f" | cut -f1)" >> "${PACKAGE_DIR}/manifest.txt"
done

echo ""
echo "==========================================="
echo "Package created at: ${PACKAGE_DIR}"
echo ""
echo "Contents:"
du -sh "${PACKAGE_DIR}"/* 2>/dev/null | sort -h
echo ""
echo "Total size:"
du -sh "${PACKAGE_DIR}"
echo ""
echo "To copy to USB:"
echo "  cp -r ${PACKAGE_DIR} /media/usb/"
