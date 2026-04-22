#!/usr/bin/env bash
# Fetch the latest ggml-org/llama.cpp release build for this platform and
# unpack it into ${LLAMACPP_HOME} (default ~/.local/llama.cpp).
#
# The upstream GitHub Actions pipeline builds these zips from master on every
# tag, so "latest release" is effectively "latest git master".
#
# Env overrides:
#   LLAMACPP_HOME     target install dir (default ~/.local/llama.cpp)
#   LLAMACPP_TAG      pin to a specific release tag (default: latest)
#   LLAMACPP_FLAVOR   override backend asset (e.g. ubuntu-x64-cuda, win-x64-vulkan, macos-arm64)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have curl || die "curl is required"
have unzip || die "unzip is required"
have tar || die "tar is required"
have python3 || die "python3 is required"

PLATFORM="$(detect_platform)"
ARCH="$(detect_arch)"
# Upstream ggml-org ships Vulkan as the portable non-Mac backend; it runs on
# NVIDIA, Intel Arc, and AMD with their stock Vulkan drivers. CUDA-specific
# builds are only provided for Windows.
FLAVOR="${LLAMACPP_FLAVOR:-}"
if [[ -z "${FLAVOR}" ]]; then
  case "${PLATFORM}" in
    mac)           FLAVOR="macos-${ARCH}" ;;
    linux|wsl)     FLAVOR="ubuntu-vulkan-${ARCH}" ;;
    windows)       FLAVOR="win-vulkan-${ARCH}" ;;
    *) die "cannot infer llama.cpp release flavor for ${PLATFORM}" ;;
  esac
fi

API="https://api.github.com/repos/ggml-org/llama.cpp/releases"
if [[ -n "${LLAMACPP_TAG:-}" ]]; then
  release_url="${API}/tags/${LLAMACPP_TAG}"
else
  release_url="${API}/latest"
fi

echo "resolving llama.cpp release (${release_url})..."
release_json="$(curl -fsSL "${release_url}")"

TAG="$(printf '%s' "${release_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
asset_url="$(printf '%s' "${release_json}" | python3 -c '
import json, re, sys
flavor = sys.argv[1]
data = json.load(sys.stdin)
pat = re.compile(rf"llama-.*-bin-{re.escape(flavor)}\.(zip|tar\.gz)$")
for asset in data["assets"]:
    if pat.search(asset["name"]):
        print(asset["browser_download_url"])
        sys.exit(0)
sys.exit(1)
' "${FLAVOR}")" || die "no asset matching flavor '${FLAVOR}' in release ${TAG}"

asset_name="$(basename "${asset_url}")"
echo "tag: ${TAG}"
echo "asset: ${asset_name}"

mkdir -p "${LLAMACPP_HOME}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

echo "downloading ${asset_url}..."
curl -fsSL -o "${tmpdir}/pkg" "${asset_url}"
echo "unpacking into ${LLAMACPP_HOME}..."
mkdir -p "${tmpdir}/unpacked"
case "${asset_name}" in
  *.zip)    unzip -q -o "${tmpdir}/pkg" -d "${tmpdir}/unpacked" ;;
  *.tar.gz) tar -xzf "${tmpdir}/pkg" -C "${tmpdir}/unpacked" ;;
  *) die "unknown archive format: ${asset_name}" ;;
esac

binary_dir="$(find "${tmpdir}/unpacked" -type f \( -name 'llama-server' -o -name 'llama-server.exe' \) -print -quit | xargs -I{} dirname {})"
[[ -n "${binary_dir}" ]] || die "llama-server not found in downloaded archive"
cp -R "${binary_dir}/." "${LLAMACPP_HOME}/"

printf '%s\n' "${TAG}" > "${LLAMACPP_HOME}/VERSION"

server="${LLAMACPP_HOME}/llama-server"
[[ "${PLATFORM}" == "windows" ]] && server="${LLAMACPP_HOME}/llama-server.exe"
chmod +x "${server}" 2>/dev/null || true

echo "installed llama.cpp ${TAG} at ${LLAMACPP_HOME}"
if [[ -x "${server}" ]]; then
  "${server}" --version 2>&1 | head -5 || true
fi
