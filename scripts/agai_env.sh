#!/usr/bin/env bash
# Source this file to target the shared AG-AI runtime layout on this host.

export AGAI_ROOT="${AGAI_ROOT:-/temp/AG-AI}"
export LLAMACPP_HOME="${LLAMACPP_HOME:-${AGAI_ROOT}/bin/devstral}"
export LLAMACPP_LIB_ROOT="${LLAMACPP_LIB_ROOT:-${AGAI_ROOT}/usr/lib/devstral/llama.cpp}"
export LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-${AGAI_ROOT}/data/devstral/llama.cpp/models}"
export DEVSTRAL_DATA_ROOT="${DEVSTRAL_DATA_ROOT:-${AGAI_ROOT}/data/devstral}"
export RUN_DIR="${RUN_DIR:-${DEVSTRAL_DATA_ROOT}/run}"
export LOG_DIR="${LOG_DIR:-${DEVSTRAL_DATA_ROOT}/logs}"

# Default large-model context for the 24 GB RTX 4090 host.
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-50000}"
