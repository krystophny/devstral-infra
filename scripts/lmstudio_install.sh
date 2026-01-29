#!/usr/bin/env bash
# Install LM Studio AppImage for Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LMSTUDIO_VERSION="${LMSTUDIO_VERSION:-0.4.0-18}"
LMSTUDIO_DIR="${LMSTUDIO_DIR:-${HOME}/.local/opt/lm-studio}"
LMSTUDIO_URL="https://installers.lmstudio.ai/linux/x64/${LMSTUDIO_VERSION}/LM-Studio-${LMSTUDIO_VERSION}-x64.AppImage"

echo "Installing LM Studio ${LMSTUDIO_VERSION}..."

# Create directories
mkdir -p "${LMSTUDIO_DIR}"
mkdir -p "${HOME}/.local/bin"
mkdir -p "${HOME}/.local/share/applications"

# Download AppImage if not present
APPIMAGE_PATH="${LMSTUDIO_DIR}/lm-studio.AppImage"
if [[ ! -f "${APPIMAGE_PATH}" ]]; then
    echo "Downloading LM Studio AppImage (~1GB)..."
    curl -L -o "${APPIMAGE_PATH}" "${LMSTUDIO_URL}"
    chmod +x "${APPIMAGE_PATH}"
else
    echo "LM Studio AppImage already exists at ${APPIMAGE_PATH}"
fi

# Create symlink
ln -sf "${APPIMAGE_PATH}" "${HOME}/.local/bin/lm-studio"

# Extract AppImage to get lms CLI
SQUASHFS_DIR="${LMSTUDIO_DIR}/squashfs-root"
if [[ ! -d "${SQUASHFS_DIR}" ]]; then
    echo "Extracting AppImage for CLI access..."
    cd "${LMSTUDIO_DIR}"
    "${APPIMAGE_PATH}" --appimage-extract >/dev/null 2>&1 || true
fi

# Fix chrome-sandbox permissions if needed
if [[ -f "${SQUASHFS_DIR}/chrome-sandbox" ]]; then
    echo "Note: chrome-sandbox may need root permissions for some features"
    echo "Run: sudo chown root:root ${SQUASHFS_DIR}/chrome-sandbox && sudo chmod 4755 ${SQUASHFS_DIR}/chrome-sandbox"
fi

# Link lms CLI (may be at different paths depending on version)
LMS_PATH=""
for path in "${SQUASHFS_DIR}/resources/app/.webpack/lms" "${SQUASHFS_DIR}/resources/bin/lms" "${HOME}/.lmstudio/bin/lms"; do
    if [[ -f "${path}" ]]; then
        LMS_PATH="${path}"
        break
    fi
done

if [[ -n "${LMS_PATH}" ]]; then
    ln -sf "${LMS_PATH}" "${HOME}/.local/bin/lms"
    echo "lms CLI linked to ~/.local/bin/lms (from ${LMS_PATH})"
else
    echo "Note: lms CLI will be available after first LM Studio launch"
fi

# Create desktop entry
cat > "${HOME}/.local/share/applications/lm-studio.desktop" << DESKTOP
[Desktop Entry]
Name=LM Studio
Comment=Local LLM inference with OpenAI-compatible API
Exec=${APPIMAGE_PATH}
Icon=lm-studio
Type=Application
Categories=Development;Science;
Terminal=false
DESKTOP

# Ensure ~/.local/bin is in PATH
if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
    echo ""
    echo "Add to your shell profile:"
    echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi

echo ""
echo "LM Studio installed successfully!"
echo ""
echo "Commands:"
echo "  lm-studio          # Launch GUI"
echo "  lms --help         # CLI tool"
echo "  lms get <model>    # Download model"
echo "  lms server start   # Start API server"
echo ""
echo "Next steps:"
echo "  scripts/lmstudio_download_models.sh  # Download recommended models"
