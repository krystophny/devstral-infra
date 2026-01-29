#!/usr/bin/env bash
# Create offline installation package for Windows
# Includes: LM Studio, OpenCode, Mistral Vibe, and all models
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${1:-${HOME}/offline-ai-package}"
MODELS_DIR="${HOME}/.lmstudio/models"

# Versions
LMSTUDIO_VERSION="0.4.0-18"
OPENCODE_VERSION="1.1.35"
VIBE_VERSION="2.0.1"

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
echo "[2/4] Copying LM Studio models..."

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

echo [1/4] Installing LM Studio...
if exist "%PACKAGE_DIR%\installers\LM-Studio-*-x64.exe" (
    for %%f in ("%PACKAGE_DIR%\installers\LM-Studio-*-x64.exe") do (
        echo Installing %%f...
        start /wait "" "%%f" /S
    )
) else (
    echo LM Studio installer not found!
)

echo.
echo [2/4] Installing OpenCode...
if exist "%PACKAGE_DIR%\installers\opencode-*-windows-amd64.exe" (
    for %%f in ("%PACKAGE_DIR%\installers\opencode-*-windows-amd64.exe") do (
        copy "%%f" "%USERPROFILE%\.local\bin\opencode.exe" >nul 2>&1
        if not exist "%USERPROFILE%\.local\bin" mkdir "%USERPROFILE%\.local\bin"
        copy "%%f" "%USERPROFILE%\.local\bin\opencode.exe"
        echo OpenCode copied to %USERPROFILE%\.local\bin\opencode.exe
    )
) else (
    echo OpenCode installer not found!
)

echo.
echo [3/4] Installing Mistral Vibe...
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
echo [4/4] Copying models to LM Studio...
call "%SCRIPT_DIR%\copy-models.bat"

echo.
echo ============================================
echo Installation complete!
echo ============================================
echo.
echo Next steps:
echo 1. Open LM Studio and load a model
echo 2. Start the LM Studio server (Developer tab)
echo 3. Run: opencode (or vibe)
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

# OpenCode config script
cat > "${PACKAGE_DIR}/scripts/configure-opencode.bat" << 'BATCH'
@echo off
set CONFIG_DIR=%USERPROFILE%\.config\opencode
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

echo Creating OpenCode config for local LM Studio...

(
echo {
echo   "model": "lmstudio/gpt-oss-20b",
echo   "provider": {
echo     "lmstudio": {
echo       "name": "LM Studio",
echo       "kind": "openai",
echo       "baseURL": "http://127.0.0.1:1234/v1",
echo       "apiKey": "lm-studio"
echo     }
echo   },
echo   "autoupdate": {"enabled": false},
echo   "telemetry": {"enabled": false}
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
installers/     - Windows installers for LM Studio, OpenCode, Vibe
models/         - Pre-downloaded GGUF models for LM Studio
scripts/        - Installation and configuration batch scripts
configs/        - Sample configuration files

Quick Start:
------------
1. Run scripts\install-all.bat as Administrator
2. Open LM Studio and go to Developer tab
3. Click "Start Server" (runs on port 1234)
4. Open terminal and run: opencode

Models Included:
----------------
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
1. Install LM Studio: Run installers\LM-Studio-*.exe
2. Copy models: xcopy models\* %USERPROFILE%\.lmstudio\models\ /E
3. Install OpenCode: Copy installers\opencode-*.exe to PATH
4. Install Vibe: pip install installers\mistral_vibe-*.whl

Troubleshooting:
----------------
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
- Mistral Vibe: ${VIBE_VERSION}

Models:
MANIFEST

find "${PACKAGE_DIR}/models" -name "*.gguf" -type f 2>/dev/null | while read -r f; do
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
