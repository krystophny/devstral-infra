#!/usr/bin/env bash
# Install llama.cpp into ${LLAMACPP_HOME} (default ~/.local/llama.cpp).
#
# Backend selection (set LLAMACPP_BACKEND to override, default auto):
#   prebuilt     fetch the upstream ggml-org release asset for this platform.
#                macOS gets macos-${ARCH}; Linux/Windows default to the portable
#                Vulkan build (upstream ships CUDA only for Windows).
#   cuda-source build llama.cpp from the matching git tag with -DGGML_CUDA=ON.
#                Auto-selected on Linux when nvidia-smi + nvcc + cmake + ninja +
#                git are all present; gets ~2x throughput vs Vulkan on NVIDIA
#                and removes the inter-token stalls that trigger opencode
#                ECONNRESETs.
#   auto         pick cuda-source on Linux with CUDA, else prebuilt.
#
# Env overrides:
#   LLAMACPP_HOME         target install dir (default ~/.local/llama.cpp)
#   LLAMACPP_TAG          pin to a specific release tag (default: latest)
#   LLAMACPP_BACKEND      auto | prebuilt | cuda-source (default auto)
#   LLAMACPP_FLAVOR       prebuilt asset override (e.g. ubuntu-vulkan-x64)
#   LLAMACPP_CMAKE_EXTRA  extra flags appended to cmake configure (cuda-source)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have curl || die "curl is required"
have python3 || die "python3 is required"

PLATFORM="$(detect_platform)"
ARCH="$(detect_arch)"
GPU="$(detect_gpu)"

BACKEND="${LLAMACPP_BACKEND:-auto}"
if [[ "${BACKEND}" == "auto" ]]; then
  if [[ "${PLATFORM}" == "linux" && "${GPU}" == "cuda" ]] \
      && have nvcc && have cmake && have ninja && have git; then
    BACKEND="cuda-source"
  else
    BACKEND="prebuilt"
  fi
fi

case "${BACKEND}" in
  prebuilt|cuda-source) ;;
  *) die "unknown LLAMACPP_BACKEND: ${BACKEND}" ;;
esac

API="https://api.github.com/repos/ggml-org/llama.cpp/releases"
if [[ -n "${LLAMACPP_TAG:-}" ]]; then
  release_url="${API}/tags/${LLAMACPP_TAG}"
else
  release_url="${API}/latest"
fi

echo "resolving llama.cpp release (${release_url})..."
release_json="$(curl -fsSL "${release_url}")"
TAG="$(printf '%s' "${release_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
echo "tag:     ${TAG}"
echo "backend: ${BACKEND}"

mkdir -p "${LLAMACPP_HOME}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

install_prebuilt() {
  have unzip || die "unzip is required for prebuilt install"
  have tar || die "tar is required for prebuilt install"

  local flavor="${LLAMACPP_FLAVOR:-}"
  if [[ -z "${flavor}" ]]; then
    case "${PLATFORM}" in
      mac)           flavor="macos-${ARCH}" ;;
      linux|wsl)     flavor="ubuntu-vulkan-${ARCH}" ;;
      windows)       flavor="win-vulkan-${ARCH}" ;;
      *) die "cannot infer llama.cpp release flavor for ${PLATFORM}" ;;
    esac
  fi

  local asset_url
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
' "${flavor}")" || die "no asset matching flavor '${flavor}' in release ${TAG}"

  local asset_name
  asset_name="$(basename "${asset_url}")"
  echo "flavor:  ${flavor}"
  echo "asset:   ${asset_name}"

  echo "downloading ${asset_url}..."
  curl -fsSL -o "${tmpdir}/pkg" "${asset_url}"
  mkdir -p "${tmpdir}/unpacked"
  case "${asset_name}" in
    *.zip)    unzip -q -o "${tmpdir}/pkg" -d "${tmpdir}/unpacked" ;;
    *.tar.gz) tar -xzf "${tmpdir}/pkg" -C "${tmpdir}/unpacked" ;;
    *) die "unknown archive format: ${asset_name}" ;;
  esac

  local binary_dir
  binary_dir="$(find "${tmpdir}/unpacked" -type f \( -name 'llama-server' -o -name 'llama-server.exe' \) -print -quit | xargs -I{} dirname {})"
  [[ -n "${binary_dir}" ]] || die "llama-server not found in downloaded archive"
  cp -R "${binary_dir}/." "${LLAMACPP_HOME}/"

  printf '%s\n' "${TAG}" > "${LLAMACPP_HOME}/VERSION"
}

install_cuda_source() {
  [[ "${PLATFORM}" == "linux" || "${PLATFORM}" == "wsl" ]] \
    || die "cuda-source backend only supported on Linux/WSL (got ${PLATFORM})"
  have nvcc || die "nvcc not found in PATH; install the CUDA toolkit (e.g. /opt/cuda/bin)"
  have cmake || die "cmake is required for cuda-source backend"
  have ninja || die "ninja is required for cuda-source backend"
  have git || die "git is required for cuda-source backend"

  local src="${tmpdir}/llama.cpp"
  local build="${tmpdir}/build"
  local install="${tmpdir}/install"

  echo "cloning ggml-org/llama.cpp @ ${TAG}..."
  git clone --depth 1 --branch "${TAG}" \
    https://github.com/ggml-org/llama.cpp.git "${src}" 2>&1 | tail -2

  export CUDACXX="${CUDACXX:-$(command -v nvcc)}"
  echo "configuring (GGML_CUDA=ON, native arch)..."
  # shellcheck disable=SC2086
  cmake -S "${src}" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${install}" \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_CUDA=ON \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    ${LLAMACPP_CMAKE_EXTRA:-} >"${tmpdir}/cmake-configure.log" 2>&1 \
      || { tail -40 "${tmpdir}/cmake-configure.log" >&2; die "cmake configure failed"; }

  echo "building (this takes a few minutes)..."
  cmake --build "${build}" -j"$(nproc)" >"${tmpdir}/cmake-build.log" 2>&1 \
    || { tail -40 "${tmpdir}/cmake-build.log" >&2; die "cmake build failed"; }

  echo "installing..."
  cmake --install "${build}" >"${tmpdir}/cmake-install.log" 2>&1 \
    || { tail -40 "${tmpdir}/cmake-install.log" >&2; die "cmake install failed"; }

  # Flatten bin/ and lib/ into LLAMACPP_HOME so the layout matches the prebuilt
  # release asset that server_start_llamacpp.sh expects (flat directory with
  # llama-server next to all .so files). Wipe the previous install first so old
  # backend libraries (e.g. libggml-vulkan.so) don't linger.
  find "${LLAMACPP_HOME}" -mindepth 1 -maxdepth 1 \
    \( -name 'llama-*' -o -name 'lib*.so*' -o -name 'VERSION' \) -exec rm -rf {} +

  cp "${install}/bin/llama-server" "${LLAMACPP_HOME}/"
  # Copy every shared library and its symlinks. Install ships them under lib/.
  local libdir="${install}/lib"
  [[ -d "${libdir}" ]] || libdir="${install}/lib64"
  [[ -d "${libdir}" ]] || die "neither ${install}/lib nor ${install}/lib64 exists"
  find "${libdir}" -maxdepth 1 \( -name 'lib*.so' -o -name 'lib*.so.*' \) \
    -exec cp -P {} "${LLAMACPP_HOME}/" \;

  printf '%s+cuda\n' "${TAG}" > "${LLAMACPP_HOME}/VERSION"
}

case "${BACKEND}" in
  prebuilt)    install_prebuilt ;;
  cuda-source) install_cuda_source ;;
esac

server="${LLAMACPP_HOME}/llama-server"
[[ "${PLATFORM}" == "windows" ]] && server="${LLAMACPP_HOME}/llama-server.exe"
chmod +x "${server}" 2>/dev/null || true

echo "installed llama.cpp $(cat "${LLAMACPP_HOME}/VERSION") at ${LLAMACPP_HOME}"
if [[ -x "${server}" ]]; then
  LD_LIBRARY_PATH="${LLAMACPP_HOME}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${server}" --version 2>&1 | head -5 || true
fi
