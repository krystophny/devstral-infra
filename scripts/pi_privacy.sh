#!/usr/bin/env bash
# Pin Pi Coding Agent telemetry/version-check opt-outs at user level.
# Idempotent: each run rewrites the marker-delimited shell block and the
# settings.json keys it owns.
set -euo pipefail

MARK_BEGIN='# >>> devstral-infra pi privacy >>>'
MARK_END='# <<< devstral-infra pi privacy <<<'

SHELL_BLOCK=$(cat <<'EOF'
# Disables Pi install/update telemetry and startup version checks. Managed by
# devstral-infra/scripts/pi_privacy.sh. Do not edit by hand.
export PI_TELEMETRY=0
export PI_SKIP_VERSION_CHECK=1
EOF
)

apply_shell_rc() {
  local target="$1"
  [[ -e "${target}" || "${target}" == "${HOME}/.profile" ]] || return 0
  [[ -e "${target}" ]] || : > "${target}"

  python3 - "${target}" "${MARK_BEGIN}" "${MARK_END}" "${SHELL_BLOCK}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
begin, end, body = sys.argv[2], sys.argv[3], sys.argv[4]
text = path.read_text() if path.exists() else ""
block = f"{begin}\n{body}\n{end}\n"
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    new = pre.rstrip() + ("\n\n" if pre.strip() else "") + block + post.lstrip()
else:
    new = text.rstrip() + ("\n\n" if text.strip() else "") + block
path.write_text(new)
PY
  echo "  updated: ${target}"
}

write_settings() {
  local dir="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
  local settings="${dir}/settings.json"
  mkdir -p "${dir}"
  python3 - "${settings}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text()) if path.exists() else {}
except json.JSONDecodeError:
    backup = path.with_suffix(path.suffix + ".devstral-infra.bak")
    backup.write_text(path.read_text())
    data = {}
data["enableInstallTelemetry"] = False
path.write_text(json.dumps(data, indent=2) + "\n")
PY
  echo "  wrote:   ${settings}"
}

echo "pinning Pi privacy env/settings for $(whoami) on $(uname -s)..."
apply_shell_rc "${HOME}/.profile"
[[ -e "${HOME}/.bashrc"   ]] && apply_shell_rc "${HOME}/.bashrc"   || true
[[ -e "${HOME}/.zshrc"    ]] && apply_shell_rc "${HOME}/.zshrc"    || true
[[ -e "${HOME}/.zprofile" ]] && apply_shell_rc "${HOME}/.zprofile" || true
write_settings

cat <<EOF
done. Start a new shell (or 'source ~/.profile') for the vars to take effect.
verify with: env | grep '^PI_'
EOF
