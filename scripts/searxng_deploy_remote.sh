#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

REMOTE_HOST="${SEARXNG_REMOTE_HOST:-192.168.1.1}"
REMOTE_DIR="${SEARXNG_REMOTE_DIR:-/home/user/services/searxng-local}"
LAN_HOST="${SEARXNG_LAN_HOST:-192.168.1.1}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
INSTANCE_NAME="${SEARXNG_INSTANCE_NAME:-SearXNG LAN}"
BASE_URL="${SEARXNG_BASE_URL:-http://${LAN_HOST}:${SEARXNG_PORT}}"
ENABLE_GOOGLE="${SEARXNG_ENABLE_GOOGLE:-true}"

COMPOSE_TEMPLATE="${REPO_ROOT}/deploy/searxng/compose.yaml"
SETTINGS_TEMPLATE="${REPO_ROOT}/deploy/searxng/settings.yml.template"
LIMITER_TEMPLATE="${REPO_ROOT}/deploy/searxng/limiter.toml"
FAVICONS_TEMPLATE="${REPO_ROOT}/deploy/searxng/favicons.toml"
[[ -f "${COMPOSE_TEMPLATE}" ]] || die "missing ${COMPOSE_TEMPLATE}"
[[ -f "${SETTINGS_TEMPLATE}" ]] || die "missing ${SETTINGS_TEMPLATE}"
[[ -f "${LIMITER_TEMPLATE}" ]] || die "missing ${LIMITER_TEMPLATE}"
[[ -f "${FAVICONS_TEMPLATE}" ]] || die "missing ${FAVICONS_TEMPLATE}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

python3 - "${SETTINGS_TEMPLATE}" "${TMPDIR}/settings.yml" "${INSTANCE_NAME}" "${BASE_URL}" "${SECRET_KEY}" "${ENABLE_GOOGLE}" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text()
enable_google = sys.argv[6].strip().lower() in {"1", "true", "yes", "on"}
use_default_settings_block = "use_default_settings: {}"
if not enable_google:
    use_default_settings_block = "\n".join(
        [
            "use_default_settings:",
            "  engines:",
            "    remove:",
            "      - google",
            "      - google images",
            "      - google news",
            "      - google scholar",
            "      - google videos",
        ]
    )
rendered = (
    src.replace("__USE_DEFAULT_SETTINGS_BLOCK__", use_default_settings_block)
       .replace("__INSTANCE_NAME__", sys.argv[3])
       .replace("__SEARXNG_BASE_URL__", sys.argv[4])
       .replace("__SEARXNG_SECRET__", sys.argv[5])
)
pathlib.Path(sys.argv[2]).write_text(rendered)
PY

cat > "${TMPDIR}/.env" <<EOF
SEARXNG_PORT=${SEARXNG_PORT}
EOF

cp "${COMPOSE_TEMPLATE}" "${TMPDIR}/compose.yaml"
cp "${LIMITER_TEMPLATE}" "${TMPDIR}/limiter.toml"
cp "${FAVICONS_TEMPLATE}" "${TMPDIR}/favicons.toml"

ssh "${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"
REMOTE_TMP_DIR="/tmp/searxng-deploy-$$"
ssh "${REMOTE_HOST}" "rm -rf '${REMOTE_TMP_DIR}' && mkdir -p '${REMOTE_TMP_DIR}'"
scp "${TMPDIR}/compose.yaml" "${TMPDIR}/settings.yml" "${TMPDIR}/.env" \
  "${TMPDIR}/limiter.toml" "${TMPDIR}/favicons.toml" \
  "${REMOTE_HOST}:${REMOTE_TMP_DIR}/"

ssh "${REMOTE_HOST}" "
set -euo pipefail
sudo install -d -m 0755 '${REMOTE_DIR}'
sudo install -m 0644 '${REMOTE_TMP_DIR}/compose.yaml' '${REMOTE_DIR}/compose.yaml'
sudo install -m 0644 '${REMOTE_TMP_DIR}/settings.yml' '${REMOTE_DIR}/settings.yml'
sudo install -m 0644 '${REMOTE_TMP_DIR}/.env' '${REMOTE_DIR}/.env'
sudo install -m 0644 '${REMOTE_TMP_DIR}/limiter.toml' '${REMOTE_DIR}/limiter.toml'
sudo install -m 0644 '${REMOTE_TMP_DIR}/favicons.toml' '${REMOTE_DIR}/favicons.toml'
rm -rf '${REMOTE_TMP_DIR}'
cd '${REMOTE_DIR}'
docker compose pull
docker compose up -d
"

python3 - "${BASE_URL}" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

url = sys.argv[1].rstrip("/") + "/search?q=searxng&format=json"
deadline = time.time() + 90
last_error = None
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
        print(f"search endpoint ok: {len(payload.get('results', []))} results")
        raise SystemExit(0)
    except Exception as exc:
        last_error = exc
        time.sleep(2)
raise SystemExit(f"SearXNG did not become ready: {last_error}")
PY

echo "Deployed SearXNG:"
echo "- host: ${REMOTE_HOST}"
echo "- lan_url: ${BASE_URL}"
echo "- remote_dir: ${REMOTE_DIR}"
echo "- google_enabled: ${ENABLE_GOOGLE}"
