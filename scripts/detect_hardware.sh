#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

platform="$(detect_platform)"
gpu="$(detect_gpu)"
gpu_count="$(detect_gpu_count)"
vram_mb="$(detect_vram_mb)"
ram_mb="$(detect_ram_mb)"

echo "=== Hardware Detection ==="
echo "platform: ${platform}"
echo "gpu: ${gpu}"
echo "gpu_count: ${gpu_count}"
echo "vram_mb: ${vram_mb}"
echo "ram_mb: ${ram_mb}"
echo ""

echo "=== Viable Configurations ==="
echo "(Listed from most capable to least capable)"
echo ""

idx=1
while IFS='|' read -r model_size quant ctx desc; do
  if [[ -z "${model_size}" ]]; then
    continue
  fi
  model_id="$(model_id_from_config "${model_size}" "${quant}")"
  printf "[%d] %s\n" "${idx}" "${desc}"
  printf "    model: %s\n" "${model_id}"
  printf "    quantization: %s\n" "${quant}"
  printf "    max_context: %s tokens\n" "${ctx}"
  echo ""
  idx=$((idx + 1))
done < <(list_viable_configs "${vram_mb}" "${ram_mb}" "${platform}" "${gpu}")

if [[ "${idx}" -eq 1 ]]; then
  echo "No viable configurations found for your hardware."
  echo ""
  echo "Minimum requirements:"
  echo "- Mac: 16 GB unified memory"
  echo "- Linux with NVIDIA: 12 GB VRAM"
  echo "- Linux CPU-only: 24 GB RAM"
  echo ""
  echo "Consider using Ministral 3B or another smaller model."
  exit 1
fi

echo "=== Auto-Selected Configuration ==="
config="$(best_config "${vram_mb}" "${ram_mb}")"
model_size="$(echo "${config}" | cut -d'|' -f1)"
quant="$(echo "${config}" | cut -d'|' -f2)"
ctx="$(echo "${config}" | cut -d'|' -f3)"
desc="$(echo "${config}" | cut -d'|' -f4)"
model_id="$(model_id_from_config "${model_size}" "${quant}")"

echo "${desc}"
echo "- model: ${model_id}"
echo "- quantization: ${quant}"
echo "- max_context: ${ctx} tokens"
echo ""
echo "To override, set environment variables:"
echo "  DEVSTRAL_MODEL=<model-id>"
echo "  DEVSTRAL_MAX_MODEL_LEN=<context-length>"
echo "  DEVSTRAL_MODEL_SIZE=small|full"
