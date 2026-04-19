#!/usr/bin/env bash
# Source this file to target the shared AG-AI runtime layout on this host.

export AGAI_ROOT="${AGAI_ROOT:-/temp/AG-AI}"
export LLAMACPP_HOME="${LLAMACPP_HOME:-${AGAI_ROOT}/bin/llama.cpp}"
export LLAMACPP_LIB_ROOT="${LLAMACPP_LIB_ROOT:-${AGAI_ROOT}/usr/lib/llama.cpp}"
export LLAMACPP_DATA_ROOT="${LLAMACPP_DATA_ROOT:-${AGAI_ROOT}/data/llama.cpp}"
export LLAMACPP_CACHE_ROOT="${LLAMACPP_CACHE_ROOT:-${LLAMACPP_DATA_ROOT}/models}"
export LLAMA_CACHE="${LLAMA_CACHE:-${LLAMACPP_CACHE_ROOT}}"
export RUN_DIR="${RUN_DIR:-${LLAMACPP_DATA_ROOT}/run}"
export LOG_DIR="${LOG_DIR:-${LLAMACPP_DATA_ROOT}/logs}"
export HF_HOME_DIR="${HF_HOME_DIR:-${LLAMACPP_DATA_ROOT}/hf}"

# Default tuned Qwen 3.6 profile for the 24 GB RTX 4090 host.
export LLAMACPP_MODEL_ALIAS="${LLAMACPP_MODEL_ALIAS:-qwen3.6-35b-a3b-q4km}"
export LLAMACPP_CONTEXT="${LLAMACPP_CONTEXT:-131072}"
export LLAMACPP_BATCH="${LLAMACPP_BATCH:-256}"
export LLAMACPP_UBATCH="${LLAMACPP_UBATCH:-64}"
export LLAMACPP_EXTRA_FLAGS="${LLAMACPP_EXTRA_FLAGS:---n-cpu-moe 8 -ctk q8_0 -ctv q8_0}"
