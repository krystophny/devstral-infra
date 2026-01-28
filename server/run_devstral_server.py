#!/usr/bin/env python3
"""Thin vLLM launcher with env-var configuration.

Reads DEVSTRAL_* environment variables and executes `vllm serve` with
the Mistral-recommended flags (tokenizer_mode, config_format, load_format,
tool-call support).
"""
import os
import subprocess
import sys

def main() -> None:
    model = os.environ.get(
        "DEVSTRAL_MODEL", "mistralai/Devstral-Small-2-24B-Instruct-2512"
    )
    host = os.environ.get("DEVSTRAL_HOST", "127.0.0.1")
    port = os.environ.get("DEVSTRAL_PORT", "8080")
    max_model_len = os.environ.get("DEVSTRAL_MAX_MODEL_LEN", "")
    extra_flags = os.environ.get("DEVSTRAL_EXTRA_FLAGS", "")

    cmd = [
        sys.executable, "-m", "vllm.entrypoints.openai.api_server",
        "--model", model,
        "--tokenizer_mode", "mistral",
        "--config_format", "mistral",
        "--load_format", "mistral",
        "--enable-auto-tool-choice",
        "--tool-call-parser", "mistral",
        "--host", host,
        "--port", port,
    ]

    if max_model_len:
        cmd.extend(["--max-model-len", max_model_len])

    if extra_flags:
        cmd.extend(extra_flags.split())

    os.execvp(cmd[0], cmd)

if __name__ == "__main__":
    main()
