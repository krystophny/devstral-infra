#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${REPO_ROOT}/.run"
# shellcheck disable=SC2034  # used by scripts that source this file
HF_HOME_DIR="${REPO_ROOT}/.hf"
VENV_DIR="${REPO_ROOT}/.venv"

mkdir -p "${RUN_DIR}"

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

detect_platform() {
  local uname_s
  uname_s="$(uname -s)"

  case "${uname_s}" in
    Darwin)
      echo "mac"
      ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    *)
      die "unsupported platform: ${uname_s}"
      ;;
  esac
}

detect_vram_mb() {
  local platform
  platform="$(detect_platform)"

  case "${platform}" in
    mac)
      local bytes
      bytes="$(sysctl -n hw.memsize)"
      local total_mb=$(( bytes / 1048576 ))
      echo $(( total_mb * 75 / 100 ))
      ;;
    linux|wsl)
      if have nvidia-smi; then
        local total_vram=0
        while IFS= read -r line; do
          line="$(echo "${line}" | tr -d ' ')"
          if [[ -n "${line}" && "${line}" =~ ^[0-9]+$ ]]; then
            total_vram=$(( total_vram + line ))
          fi
        done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
        if [[ "${total_vram}" -gt 0 ]]; then
          echo "${total_vram}"
          return 0
        fi
      fi
      echo "0"
      ;;
  esac
}

detect_ram_mb() {
  local platform
  platform="$(detect_platform)"

  case "${platform}" in
    mac)
      local bytes
      bytes="$(sysctl -n hw.memsize)"
      echo $(( bytes / 1048576 ))
      ;;
    linux|wsl)
      local mem_kb
      mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
      echo $(( mem_kb / 1024 ))
      ;;
  esac
}

detect_gpu_count() {
  local platform
  platform="$(detect_platform)"

  case "${platform}" in
    mac)
      echo "1"
      ;;
    linux|wsl)
      if have nvidia-smi; then
        nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' '
      else
        echo "0"
      fi
      ;;
  esac
}

detect_gpu() {
  local platform
  platform="$(detect_platform)"

  case "${platform}" in
    mac)
      echo "metal"
      ;;
    linux|wsl)
      if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        echo "cuda"
      else
        echo "cpu"
      fi
      ;;
  esac
}

model_memory_requirements() {
  local quant="${1:-Q4_K_M}"
  local model_size="${2:-24B}"

  case "${model_size}" in
    123B)
      case "${quant}" in
        BF16)    echo "250000" ;;
        Q8_0)    echo "133000" ;;
        Q6_K)    echo "103000" ;;
        Q5_K_M)  echo "88300" ;;
        Q4_K_M)  echo "74900" ;;
        Q4_K_S)  echo "71200" ;;
        IQ4_XS)  echo "67100" ;;
        Q3_K_M)  echo "60600" ;;
        *)       echo "74900" ;;
      esac
      ;;
    24B)
      case "${quant}" in
        BF16)    echo "47200" ;;
        Q8_0)    echo "25100" ;;
        Q6_K)    echo "19300" ;;
        Q5_K_M)  echo "16800" ;;
        Q4_K_M)  echo "14300" ;;
        Q4_K_S)  echo "13500" ;;
        IQ4_XS)  echo "12800" ;;
        Q3_K_M)  echo "11500" ;;
        *)       echo "14300" ;;
      esac
      ;;
  esac
}

context_memory_overhead() {
  local ctx="${1:-32768}"
  local model_size="${2:-24B}"

  case "${model_size}" in
    123B)
      case "${ctx}" in
        8192)    echo "2000" ;;
        32768)   echo "8000" ;;
        57344)   echo "16000" ;;
        131072)  echo "49000" ;;
        262144)  echo "96000" ;;
        *)       echo "8000" ;;
      esac
      ;;
    24B)
      case "${ctx}" in
        8192)    echo "1000" ;;
        32768)   echo "5000" ;;
        57344)   echo "9000" ;;
        131072)  echo "20000" ;;
        262144)  echo "40000" ;;
        *)       echo "5000" ;;
      esac
      ;;
  esac
}

list_viable_configs() {
  local vram_mb="${1}"
  local ram_mb="${2}"
  local platform="${3}"
  local gpu="${4}"

  local configs=()

  if [[ "${platform}" == "mac" ]]; then
    local usable="${vram_mb}"

    if [[ "${usable}" -ge 170000 ]]; then
      configs+=("123B|Q4_K_M|262144|Devstral 2 123B Q4, full 262K context")
    fi
    if [[ "${usable}" -ge 123000 ]]; then
      configs+=("123B|Q4_K_M|131072|Devstral 2 123B Q4, 131K context")
    fi
    if [[ "${usable}" -ge 103000 ]]; then
      configs+=("123B|Q4_K_M|32768|Devstral 2 123B Q4, 32K context")
      configs+=("123B|Q6_K|32768|Devstral 2 123B Q6 (higher quality), 32K context")
    fi
    if [[ "${usable}" -ge 82000 ]]; then
      configs+=("123B|Q4_K_M|8192|Devstral 2 123B Q4, 8K context")
    fi
    if [[ "${usable}" -ge 55000 ]]; then
      configs+=("24B|Q4_K_M|262144|Devstral Small 24B Q4, full 262K context")
      configs+=("24B|Q8_0|131072|Devstral Small 24B Q8 (highest quality), 131K context")
    fi
    if [[ "${usable}" -ge 35000 ]]; then
      configs+=("24B|Q4_K_M|131072|Devstral Small 24B Q4, 131K context")
      configs+=("24B|Q8_0|32768|Devstral Small 24B Q8, 32K context")
    fi
    if [[ "${usable}" -ge 24000 ]]; then
      configs+=("24B|Q4_K_M|57344|Devstral Small 24B Q4, 57K context")
    fi
    if [[ "${usable}" -ge 20000 ]]; then
      configs+=("24B|Q4_K_M|32768|Devstral Small 24B Q4, 32K context")
    fi
    if [[ "${usable}" -ge 16000 ]]; then
      configs+=("24B|Q4_K_M|8192|Devstral Small 24B Q4, 8K context")
    fi
  elif [[ "${gpu}" == "cuda" ]]; then
    local usable="${vram_mb}"

    if [[ "${usable}" -ge 192000 ]]; then
      configs+=("123B|Q4_K_M|262144|Devstral 2 123B Q4, full 262K (multi-GPU)")
    fi
    if [[ "${usable}" -ge 155000 ]]; then
      configs+=("123B|Q8_0|32768|Devstral 2 123B Q8, 32K (multi-GPU, highest quality)")
    fi
    if [[ "${usable}" -ge 96000 ]]; then
      configs+=("123B|Q4_K_M|32768|Devstral 2 123B Q4, 32K (multi-GPU, e.g. 4x24GB)")
    fi
    if [[ "${usable}" -ge 80000 ]]; then
      configs+=("123B|IQ4_XS|8192|Devstral 2 123B IQ4 (aggressive quant), 8K context")
    fi
    if [[ "${usable}" -ge 48000 ]]; then
      configs+=("24B|Q4_K_M|262144|Devstral Small 24B Q4, full 262K context")
      configs+=("24B|Q8_0|131072|Devstral Small 24B Q8, 131K context")
    fi
    if [[ "${usable}" -ge 24000 ]]; then
      configs+=("24B|Q4_K_M|57344|Devstral Small 24B Q4, 57K context")
      configs+=("24B|Q8_0|32768|Devstral Small 24B Q8, 32K context")
    fi
    if [[ "${usable}" -ge 16000 ]]; then
      configs+=("24B|Q4_K_M|32768|Devstral Small 24B Q4, 32K context")
    fi
    if [[ "${usable}" -ge 12000 ]]; then
      configs+=("24B|Q4_K_M|8192|Devstral Small 24B Q4, 8K context")
    fi
  else
    local usable="${ram_mb}"
    warn "CPU-only mode detected. Performance will be limited."

    if [[ "${usable}" -ge 32000 ]]; then
      configs+=("24B|Q4_K_M|8192|Devstral Small 24B Q4, 8K context (CPU - slow)")
    fi
    if [[ "${usable}" -ge 24000 ]]; then
      configs+=("24B|Q3_K_M|8192|Devstral Small 24B Q3, 8K context (CPU - slow)")
    fi
  fi

  printf '%s\n' "${configs[@]}"
}

best_config() {
  local vram_mb="${1:-}"
  local ram_mb="${2:-}"

  if [[ -z "${vram_mb}" ]]; then
    vram_mb="$(detect_vram_mb)"
  fi
  if [[ -z "${ram_mb}" ]]; then
    ram_mb="$(detect_ram_mb)"
  fi

  local platform gpu
  platform="$(detect_platform)"
  gpu="$(detect_gpu)"

  local first_config
  first_config="$(list_viable_configs "${vram_mb}" "${ram_mb}" "${platform}" "${gpu}" | head -1)"

  if [[ -z "${first_config}" ]]; then
    die "insufficient memory (VRAM: ${vram_mb} MB, RAM: ${ram_mb} MB). Minimum 16 GB GPU memory required."
  fi

  echo "${first_config}"
}

model_id_from_config() {
  local model_size="${1}"
  local quant="${2}"

  case "${model_size}" in
    123B)
      echo "mistralai/Devstral-2-123B-Instruct-2512"
      ;;
    24B)
      echo "mistralai/Devstral-Small-2-24B-Instruct-2512"
      ;;
    *)
      die "unknown model size: ${model_size}"
      ;;
  esac
}

auto_config() {
  local mem_mb="${1:-}"

  if [[ -n "${DEVSTRAL_MODEL:-}" && -n "${DEVSTRAL_MAX_MODEL_LEN:-}" ]]; then
    echo "${DEVSTRAL_MODEL}|${DEVSTRAL_MAX_MODEL_LEN}|"
    return 0
  fi

  local vram_mb ram_mb
  vram_mb="$(detect_vram_mb)"
  ram_mb="$(detect_ram_mb)"

  if [[ -n "${mem_mb}" ]]; then
    vram_mb="${mem_mb}"
  fi

  local config
  config="$(best_config "${vram_mb}" "${ram_mb}")"

  local model_size quant ctx
  model_size="$(echo "${config}" | cut -d'|' -f1)"
  quant="$(echo "${config}" | cut -d'|' -f2)"
  ctx="$(echo "${config}" | cut -d'|' -f3)"

  local model_id extra_flags=""
  model_id="$(model_id_from_config "${model_size}" "${quant}")"

  if [[ -n "${DEVSTRAL_MODEL:-}" ]]; then
    model_id="${DEVSTRAL_MODEL}"
  fi
  if [[ -n "${DEVSTRAL_MODEL_SIZE:-}" ]]; then
    case "${DEVSTRAL_MODEL_SIZE}" in
      small) model_id="mistralai/Devstral-Small-2-24B-Instruct-2512" ;;
      full)  model_id="mistralai/Devstral-2-123B-Instruct-2512" ;;
      *)     die "unknown DEVSTRAL_MODEL_SIZE: ${DEVSTRAL_MODEL_SIZE} (use small or full)" ;;
    esac
  fi
  if [[ -n "${DEVSTRAL_MAX_PROMPT_TOKENS:-}" ]]; then
    ctx="${DEVSTRAL_MAX_PROMPT_TOKENS}"
  fi
  if [[ -n "${DEVSTRAL_MAX_MODEL_LEN:-}" ]]; then
    ctx="${DEVSTRAL_MAX_MODEL_LEN}"
  fi

  local gpu gpu_count
  gpu="$(detect_gpu)"
  gpu_count="$(detect_gpu_count)"
  if [[ "${gpu}" == "cuda" && "${gpu_count}" -gt 1 ]]; then
    extra_flags="--tensor-parallel-size ${gpu_count}"
  fi

  echo "${model_id}|${ctx}|${extra_flags}"
}

default_model() {
  local config
  config="$(auto_config "${1:-}")"
  echo "${config}" | cut -d'|' -f1
}

default_max_model_len() {
  local config
  config="$(auto_config "${1:-}")"
  echo "${config}" | cut -d'|' -f2
}

ensure_python_venv() {
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    return 0
  fi

  local platform
  platform="$(detect_platform)"

  case "${platform}" in
    mac)
      if have python3.12; then
        python3.12 -m venv "${VENV_DIR}"
      elif have /opt/homebrew/bin/python3.12; then
        /opt/homebrew/bin/python3.12 -m venv "${VENV_DIR}"
      else
        die "python3.12 not found (required for vllm-metal on macOS). Install via: brew install python@3.12"
      fi
      ;;
    linux|wsl)
      local py=""
      for v in python3.12 python3.11 python3; do
        if have "${v}"; then
          py="${v}"
          break
        fi
      done
      if [[ -z "${py}" ]]; then
        die "python3 (3.11+) not found. Install via your package manager."
      fi
      "${py}" -m venv "${VENV_DIR}"
      ;;
  esac
}

activate_venv() {
  # shellcheck disable=SC1090,SC1091
  source "${VENV_DIR}/bin/activate"
}

server_pid_file() {
  echo "${RUN_DIR}/server.pid"
}

server_log_file() {
  echo "${RUN_DIR}/server.log"
}

server_port_file() {
  echo "${RUN_DIR}/server.port"
}

legacy_pid_file() {
  echo "${RUN_DIR}/mlx-server.pid"
}

legacy_port_file() {
  echo "${RUN_DIR}/mlx-server.port"
}

migrate_legacy_pid() {
  local legacy new
  legacy="$(legacy_pid_file)"
  new="$(server_pid_file)"
  if [[ -f "${legacy}" && ! -f "${new}" ]]; then
    mv "${legacy}" "${new}"
  fi
  legacy="$(legacy_port_file)"
  new="$(server_port_file)"
  if [[ -f "${legacy}" && ! -f "${new}" ]]; then
    mv "${legacy}" "${new}"
  fi
  rm -f "$(legacy_pid_file)" "$(legacy_port_file)"
}
