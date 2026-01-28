# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Local OpenAI-compatible MLX server for running Devstral-2-123B on Apple Silicon (Mac Studio M3 Ultra, 256GB). Integrates with Vibe by configuring it to use the local server.

## Commands

```bash
# Initial setup (creates .venv with python3.12, installs mlx/mlx-lm)
scripts/setup.sh

# Start server (host 127.0.0.1, port 8080)
scripts/server_start.sh

# Stop server
scripts/server_stop.sh

# Configure Vibe to use local server (edits ~/.vibe/config.toml)
scripts/vibe_set_local.sh

# Restore original Vibe config from backup
scripts/vibe_unset_local.sh

# Remove .venv, .hf, .run directories
scripts/teardown.sh
```

## Environment Variables

Server configuration (pass to `server_start.sh`):
- `DEVSTRAL_MODEL` - model ID (default: `mlx-community/Devstral-2-123B-Instruct-2512-6bit`)
- `DEVSTRAL_HOST` - bind address (default: `127.0.0.1`)
- `DEVSTRAL_PORT` - port (default: `8080`)
- `DEVSTRAL_MAX_TOKENS` - max output tokens (default: `1024`)
- `DEVSTRAL_MAX_PROMPT_TOKENS` - prompt budget hard limit (default: `200000`)

Vibe configuration (pass to `vibe_set_local.sh`):
- `VIBE_CONFIG_PATH` - path to config.toml (default: `~/.vibe/config.toml`)
- `VIBE_LOCAL_MODEL_ID`, `VIBE_LOCAL_PROVIDER_NAME`, `VIBE_LOCAL_API_BASE`

## Architecture

- `scripts/_common.sh` - shared bash functions and paths (REPO_ROOT, RUN_DIR, HF_HOME_DIR, VENV_DIR)
- `server/run_devstral_mlx_server.py` - thin wrapper around `mlx_lm.server` that adds prompt length enforcement via `DEVSTRAL_MAX_PROMPT_TOKENS`
- Server state stored in `.run/` (pid, port, log files)
- Model cache stored in `.hf/` (local HF_HOME)
