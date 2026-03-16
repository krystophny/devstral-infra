#!/usr/bin/env bash
# Setup llama.cpp for the local Qwen/OpenCode profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

LLAMACPP_VERSION="${LLAMACPP_VERSION:-latest}"
LLAMACPP_GIT_REF="${LLAMACPP_GIT_REF:-master}"
LLAMACPP_GIT_REMOTE_URL="${LLAMACPP_GIT_REMOTE_URL:-https://github.com/krystophny/llama.cpp}"
LLAMACPP_HOME_DIR="${LLAMACPP_HOME}"
LLAMACPP_BUILD_ROOT="${LLAMACPP_LIB_ROOT}"
LLAMACPP_SRC_DIR="${LLAMACPP_SRC_DIR:-}"

platform="$(detect_platform)"
gpu="$(detect_gpu)"

echo "=== Setting up llama.cpp ==="
echo "Platform: ${platform}"
echo "GPU: ${gpu}"
echo "Home: ${LLAMACPP_HOME_DIR}"

setup_release_binary() {
  local binary_suffix="" arch="" download_url="" extracted_dir="" version_info=""

  case "${platform}" in
    mac)
      arch="$(uname -m)"
      if [[ "${arch}" == "arm64" ]]; then
        binary_suffix="macos-arm64"
      else
        binary_suffix="macos-x64"
      fi
      ;;
    linux|wsl)
      binary_suffix="ubuntu-x64"
      ;;
    *)
      die "unsupported platform for release install: ${platform}"
      ;;
  esac

  if [[ "${LLAMACPP_VERSION}" == "latest" ]]; then
    echo "Fetching latest release..."
    LLAMACPP_VERSION="$(
      curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest |
        grep '"tag_name"' | sed 's/.*"tag_name": "\([^"]*\)".*/\1/'
    )"
  fi

  download_url="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMACPP_VERSION}/llama-${LLAMACPP_VERSION}-bin-${binary_suffix}.tar.gz"

  mkdir -p "${LLAMACPP_HOME_DIR}"
  cd "${LLAMACPP_HOME_DIR}"

  echo "Downloading from ${download_url}..."
  curl -L -o "llama-${LLAMACPP_VERSION}.tar.gz" "${download_url}"
  tar xzf "llama-${LLAMACPP_VERSION}.tar.gz"

  extracted_dir="$(find . -maxdepth 1 -type d -name "llama-*" | head -1)"
  if [[ -z "${extracted_dir}" ]]; then
    die "failed to find extracted llama.cpp directory"
  fi

  ln -sf "${extracted_dir}/llama-server" "${LLAMACPP_HOME_DIR}/llama-server"
  ln -sf "${extracted_dir}/llama-cli" "${LLAMACPP_HOME_DIR}/llama-cli"

  if [[ ! -x "${LLAMACPP_HOME_DIR}/llama-server" ]]; then
    die "llama-server not found or not executable"
  fi

  version_info="$("${LLAMACPP_HOME_DIR}/llama-server" --version 2>&1 | grep "version:" || echo "unknown")"

  cat <<EOF
OK (llama.cpp installed)
- Directory: ${LLAMACPP_HOME_DIR}
- Binary: ${binary_suffix}
- ${version_info}
EOF
}

setup_cuda_from_source() {
  local ref="" checkout_ref="" commit="" install_root="" build_dir="" prefix_dir="" server_bin="" cli_bin=""

  for dep in git cmake python3 c++ nvcc; do
    have "${dep}" || die "missing required build dependency: ${dep}"
  done
  have ninja || warn "ninja not found in PATH; cmake will use its default generator"

  if [[ -z "${LLAMACPP_SRC_DIR}" ]]; then
    if [[ -n "${AGAI_ROOT}" ]]; then
      LLAMACPP_SRC_DIR="${AGAI_ROOT}/src/llama.cpp"
    else
      LLAMACPP_SRC_DIR="${HOME}/.local/src/llama.cpp"
    fi
  fi

  mkdir -p "$(dirname "${LLAMACPP_SRC_DIR}")" "${LLAMACPP_BUILD_ROOT}" "${LLAMACPP_HOME_DIR}"

  if [[ -d "${LLAMACPP_SRC_DIR}/.git" ]]; then
    echo "Refreshing source checkout in ${LLAMACPP_SRC_DIR}..."
    current_remote="$(git -C "${LLAMACPP_SRC_DIR}" remote get-url origin 2>/dev/null || true)"
    if [[ -n "${current_remote}" && "${current_remote}" != "${LLAMACPP_GIT_REMOTE_URL}" ]]; then
      git -C "${LLAMACPP_SRC_DIR}" remote set-url origin "${LLAMACPP_GIT_REMOTE_URL}"
    fi
    git -C "${LLAMACPP_SRC_DIR}" fetch --tags origin
  else
    echo "Cloning llama.cpp into ${LLAMACPP_SRC_DIR}..."
    git clone "${LLAMACPP_GIT_REMOTE_URL}" "${LLAMACPP_SRC_DIR}"
  fi

  ref="${LLAMACPP_GIT_REF}"
  if [[ -n "${LLAMACPP_VERSION}" && "${LLAMACPP_VERSION}" != "latest" && "${LLAMACPP_GIT_REF}" == "master" ]]; then
    ref="${LLAMACPP_VERSION}"
  fi

  checkout_ref="${ref}"
  if git -C "${LLAMACPP_SRC_DIR}" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
    checkout_ref="origin/${ref}"
  fi

  echo "Checking out ${checkout_ref}..."
  git -C "${LLAMACPP_SRC_DIR}" checkout --detach "${checkout_ref}"
  commit="$(git -C "${LLAMACPP_SRC_DIR}" rev-parse --short HEAD)"

  install_root="${LLAMACPP_BUILD_ROOT}/${commit}"
  build_dir="${install_root}/build"
  prefix_dir="${install_root}/install"

  echo "Building CUDA runtime into ${install_root}..."
  cmake_args=(
    -S "${LLAMACPP_SRC_DIR}"
    -B "${build_dir}"
    -DGGML_CUDA=ON
    -DGGML_BUILD_TESTS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${prefix_dir}"
  )
  if [[ -n "${CMAKE_GENERATOR:-}" ]]; then
    cmake_args+=(-G "${CMAKE_GENERATOR}")
  elif have ninja; then
    cmake_args+=(-G Ninja)
  fi
  cmake "${cmake_args[@]}"

  cmake --build "${build_dir}" --target llama-server llama-cli
  if ! cmake --install "${build_dir}"; then
    warn "cmake install failed; using build tree artifacts directly"
  fi

  server_bin="${prefix_dir}/bin/llama-server"
  cli_bin="${prefix_dir}/bin/llama-cli"
  if [[ ! -x "${server_bin}" ]]; then
    server_bin="${build_dir}/bin/llama-server"
  fi
  if [[ ! -x "${cli_bin}" ]]; then
    cli_bin="${build_dir}/bin/llama-cli"
  fi

  [[ -x "${server_bin}" ]] || die "failed to build llama-server"
  [[ -x "${cli_bin}" ]] || die "failed to build llama-cli"

  ln -sfn "${server_bin}" "${LLAMACPP_HOME_DIR}/llama-server"
  ln -sfn "${cli_bin}" "${LLAMACPP_HOME_DIR}/llama-cli"

  cat <<EOF
OK (llama.cpp CUDA build installed)
- Source: ${LLAMACPP_SRC_DIR}
- Remote: ${LLAMACPP_GIT_REMOTE_URL}
- Ref: ${checkout_ref}
- Commit: ${commit}
- Install root: ${install_root}
- Server: ${server_bin}
- CLI: ${cli_bin}
EOF
}

case "${platform}" in
  linux|wsl)
    if [[ "${gpu}" == "cuda" ]]; then
      setup_cuda_from_source
    else
      setup_release_binary
    fi
    ;;
  mac)
    setup_release_binary
    ;;
  *)
    die "unsupported platform: ${platform}"
    ;;
esac

cat <<EOF

Next:
- Start server: scripts/server_start_llamacpp.sh
- Configure OpenCode: scripts/opencode_set_llamacpp.sh
- Configure Aider: scripts/aider_set_llamacpp.sh
- Configure Qwen Code: scripts/qwencode_set_llamacpp.sh
EOF
