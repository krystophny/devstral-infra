# devstral-infra (local MLX server for Vibe)

This repo sets up a local OpenAI-compatible server for:

- `mlx-community/Devstral-2-123B-Instruct-2512-6bit`
- Target: Mac Studio (M3 Ultra, 256GB unified memory)
- Prompt budget: **128k tokens** (hard limit via `DEVSTRAL_MAX_PROMPT_TOKENS=131072`)

## Setup

```bash
chmod +x scripts/*.sh server/*.py
scripts/setup.sh
```

Notes:
- Uses `python3.12` and creates `./.venv`
- Uses `HF_HOME=./.hf` so model downloads stay inside the repo

## Start / stop the server

Start (defaults: host `127.0.0.1`, port `8080`):

```bash
scripts/server_start.sh
```

Stop:

```bash
scripts/server_stop.sh
```

Override defaults (examples):

```bash
DEVSTRAL_PORT=8080 DEVSTRAL_MAX_TOKENS=2048 scripts/server_start.sh
DEVSTRAL_MAX_PROMPT_TOKENS=131072 scripts/server_start.sh
```

Sanity check:

```bash
curl -s http://127.0.0.1:8080/v1/models | python -m json.tool | head
curl -s http://127.0.0.1:8080/v1/chat/completions \\
  -H 'Content-Type: application/json' \\
  -d '{"model":"mlx-community/Devstral-2-123B-Instruct-2512-6bit","messages":[{"role":"user","content":"Say ok"}]}' \\
  | python -m json.tool | head
```

## Make Vibe use local by default (and undo)

Set:

```bash
scripts/vibe_set_local.sh
```

Unset (restore from backup):

```bash
scripts/vibe_unset_local.sh
```

By default these scripts edit `~/.vibe/config.toml` and:
- set `active_model = "local"`
- ensure a provider named `mlx-local` points at `http://127.0.0.1:8080/v1`
- ensure the `"local"` model uses `mlx-community/Devstral-2-123B-Instruct-2512-6bit`

Override with:

```bash
VIBE_CONFIG_PATH=/path/to/config.toml scripts/vibe_set_local.sh
```

Override model/provider/url:

```bash
VIBE_LOCAL_MODEL_ID=mlx-community/Devstral-2-123B-Instruct-2512-6bit \
VIBE_LOCAL_PROVIDER_NAME=mlx-local \
VIBE_LOCAL_API_BASE=http://127.0.0.1:8080/v1 \
scripts/vibe_set_local.sh
```

## Teardown (remove local env + caches)

```bash
scripts/teardown.sh
```
