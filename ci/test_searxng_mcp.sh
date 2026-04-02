#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

test_codex_config() {
  echo "TEST: Codex SearXNG MCP config generation"
  local home_dir="${TMPDIR}/home-codex"
  local config_dir="${home_dir}/.codex"
  local config_path="${config_dir}/config.toml"
  mkdir -p "${config_dir}"
  cat > "${config_path}" <<'EOF'
model = "gpt-5.4"

[mcp_servers.tabura]
url = "http://127.0.0.1:9420/mcp"
EOF

  HOME="${home_dir}" \
  CODEX_CONFIG_PATH="${config_path}" \
  SEARXNG_BASE_URL="http://192.168.1.1:8888" \
  bash "${REPO_ROOT}/scripts/codex_set_searxng.sh" >/dev/null

  if grep -q '\[mcp_servers.searxng\]' "${config_path}" && \
     grep -q 'command = "python3"' "${config_path}" && \
     grep -q 'server/searxng_mcp.py' "${config_path}" && \
     grep -q 'SEARXNG_BASE_URL = "http://192.168.1.1:8888"' "${config_path}" && \
     grep -q '\[mcp_servers.tabura\]' "${config_path}"; then
    echo "PASS: Codex config includes the repo-owned SearXNG MCP block"
  else
    echo "FAIL: Codex config missing expected SearXNG MCP fields"
    cat "${config_path}"
    return 1
  fi
}

test_claude_config() {
  echo "TEST: Claude Code SearXNG MCP config generation"
  local home_dir="${TMPDIR}/home-claude"
  local config_dir="${home_dir}/.claude"
  local config_path="${config_dir}/settings.json"
  mkdir -p "${config_dir}"
  cat > "${config_path}" <<'EOF'
{
  "mcpServers": {
    "helpy": {
      "type": "http",
      "url": "http://127.0.0.1:8090/mcp"
    }
  }
}
EOF

  HOME="${home_dir}" \
  CLAUDE_SETTINGS_PATH="${config_path}" \
  SEARXNG_BASE_URL="http://192.168.1.1:8888" \
  bash "${REPO_ROOT}/scripts/claude_set_searxng.sh" >/dev/null

  python3 - "${config_path}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
server = data["mcpServers"]["searxng"]
assert server["type"] == "stdio"
assert server["command"] == "python3"
assert server["env"]["SEARXNG_BASE_URL"] == "http://192.168.1.1:8888"
assert "server/searxng_mcp.py" in server["args"][0]
assert "helpy" in data["mcpServers"]
print("PASS: Claude config includes the repo-owned SearXNG MCP block")
PY
}

test_opencode_config() {
  echo "TEST: OpenCode SearXNG MCP config generation"
  local home_dir="${TMPDIR}/home-opencode"
  local config_path="${TMPDIR}/opencode.json"
  mkdir -p "${home_dir}"
  cat > "${config_path}" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llamacpp/qwen3.5-9b"
}
EOF

  HOME="${home_dir}" \
  OPENCODE_CONFIG_PATH="${config_path}" \
  SEARXNG_BASE_URL="http://192.168.1.1:8888" \
  bash "${REPO_ROOT}/scripts/opencode_set_searxng.sh" >/dev/null

  python3 - "${config_path}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
server = data["mcp"]["searxng"]
assert server["type"] == "local"
assert server["command"][0] == "python3"
assert server["environment"]["SEARXNG_BASE_URL"] == "http://192.168.1.1:8888"
assert "server/searxng_mcp.py" in server["command"][1]
assert server["enabled"] is True
print("PASS: OpenCode config includes the repo-owned SearXNG MCP block")
PY
}

test_mcp_server() {
  echo "TEST: SearXNG MCP adapter search and fetch"
  local port_file="${TMPDIR}/mock-port"
  cat > "${TMPDIR}/mock_searxng.py" <<'PY'
import json
import pathlib
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

pathlib.Path(sys.argv[1]).write_text(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/search":
            body = json.dumps({
                "results": [{
                    "title": "Rust Example",
                    "url": "https://example.com/rust",
                    "engine": "duckduckgo",
                    "content": "Rust search result snippet"
                }]
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/page":
            body = b"<html><head><title>Example Page</title></head><body><main><h1>Heading</h1><p>Readable text for fetch testing.</p></main></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *_args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
PY

  python3 "${TMPDIR}/mock_searxng.py" "${port_file}" "0" &
  local server_pid=$!
  trap 'kill ${server_pid} 2>/dev/null || true; rm -rf "${TMPDIR}"' EXIT

  local port=""
  for _ in $(seq 1 20); do
    if [[ -s "${port_file}" ]]; then
      port="$(cat "${port_file}")"
      break
    fi
    sleep 0.2
  done
  [[ -n "${port}" ]] || { echo "FAIL: mock SearXNG server did not start"; return 1; }

  python3 - "${REPO_ROOT}/server/searxng_mcp.py" "http://127.0.0.1:${port}" <<'PY'
import json
import subprocess
import sys

script_path = sys.argv[1]
base_url = sys.argv[2]

proc = subprocess.Popen(
    ["python3", script_path, "--base-url", base_url],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)

def call(message):
    payload = json.dumps(message).encode("utf-8")
    proc.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii"))
    proc.stdin.write(payload)
    proc.stdin.flush()

    headers = {}
    while True:
        line = proc.stdout.readline()
        if line in (b"\r\n", b"\n"):
            break
        name, _, value = line.decode("utf-8").partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers["content-length"])
    body = proc.stdout.read(length)
    return json.loads(body.decode("utf-8"))

init = call({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
assert init["result"]["serverInfo"]["name"] == "searxng-mcp"
tools = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
names = {tool["name"] for tool in tools["result"]["tools"]}
assert {"searxng_search", "searxng_fetch"} <= names
search = call({
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {"name": "searxng_search", "arguments": {"query": "rust", "limit": 1}},
})
search_text = search["result"]["content"][0]["text"]
assert "Rust Example" in search_text
assert "duckduckgo" in search_text
fetch = call({
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
        "name": "searxng_fetch",
        "arguments": {"url": f"{base_url}/page", "max_chars": 500},
    },
})
fetch_text = fetch["result"]["content"][0]["text"]
assert "Example Page" in fetch_text
assert "Readable text for fetch testing." in fetch_text
proc.terminate()
proc.wait(timeout=5)
print("PASS: SearXNG MCP adapter answers initialize, list, search, and fetch")
PY

  kill "${server_pid}" 2>/dev/null || true
  trap 'rm -rf "${TMPDIR}"' EXIT
}

test_settings_template_render() {
  echo "TEST: SearXNG settings template render"
  python3 - "${REPO_ROOT}/deploy/searxng/settings.yml.template" <<'PY'
import pathlib
import sys

template = pathlib.Path(sys.argv[1]).read_text()

def render(enable_google: bool):
    block = "use_default_settings: {}"
    if not enable_google:
        block = "\n".join([
            "use_default_settings:",
            "  engines:",
            "    remove:",
            "      - google",
            "      - google images",
            "      - google news",
            "      - google scholar",
            "      - google videos",
        ])
    text = (
        template.replace("__USE_DEFAULT_SETTINGS_BLOCK__", block)
        .replace("__INSTANCE_NAME__", "Test Instance")
        .replace("__SEARXNG_BASE_URL__", "http://192.168.1.1:8888")
        .replace("__SEARXNG_SECRET__", "secret")
    )
    return text

cfg_google = render(True)
assert "use_default_settings: {}" in cfg_google
assert "__USE_DEFAULT_SETTINGS_BLOCK__" not in cfg_google
cfg_no_google = render(False)
assert "use_default_settings:\n  engines:\n    remove:" in cfg_no_google
assert "      - google videos" in cfg_no_google
print("PASS: settings template renders valid YAML with and without Google")
PY
}

run_test() {
  local name="$1"
  if "${name}"; then
    echo ""
  else
    FAILED=1
    echo ""
  fi
}

run_test test_codex_config
run_test test_claude_config
run_test test_opencode_config
run_test test_mcp_server
run_test test_settings_template_render

exit "${FAILED}"
