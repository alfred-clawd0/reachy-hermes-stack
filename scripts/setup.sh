#!/usr/bin/env bash
# reachy-hermes-stack setup — clone + install the components, scaffold .env.
# Idempotent: safe to re-run. Nothing here contacts a robot or starts a service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/.env.example"
ROOT="${REACHY_STACK_DIR:-$ROOT}"
CONFIG_ONLY=false
case "${1:-}" in
  --config-only) CONFIG_ONLY=true ;;
  "") ;;
  *) echo "Usage: $0 [--config-only]" >&2; exit 2 ;;
esac
COMPONENTS="$ROOT/components"
ORG="https://github.com/ai-ag2026"

FORK="reachy_mini_conversation_app"
FORK_BRANCH="local-agent-backend"
AGENT_MODULE="reachy-hermes-agent"
PLUGIN="hermes-reachy"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

clone_or_update() {
  local name="$1" branch="${2:-}"
  local dir="$COMPONENTS/$name"
  if [ -d "$dir/.git" ]; then
    say "update $name"
    git -C "$dir" pull --ff-only || echo "  (skipped pull: local changes or offline)"
  else
    say "clone $name"
    if [ -n "$branch" ]; then
      git clone --branch "$branch" "$ORG/$name.git" "$dir"
    else
      git clone "$ORG/$name.git" "$dir"
    fi
  fi
}

if [ "$CONFIG_ONLY" = false ]; then
  mkdir -p "$COMPONENTS"
  clone_or_update "$FORK" "$FORK_BRANCH"
  clone_or_update "$AGENT_MODULE"
  clone_or_update "$PLUGIN"

  say "install Python packages (editable)"
  PIP="${PIP:-python3 -m pip}"
  if $PIP --version >/dev/null 2>&1; then
    $PIP install -e "$COMPONENTS/$AGENT_MODULE" || echo "  (reachy-hermes-agent install failed — install manually)"
    $PIP install -e "$COMPONENTS/$PLUGIN" || echo "  (hermes-reachy install failed — install manually)"
    echo "  Body app deps: cd components/$FORK && pip install -e .  (heavy: reachy-mini, gradio, aiortc)"
  else
    echo "  pip not found — install the packages manually (see README)."
  fi
fi

say "configure shared WebSocket key and .env"
# Use Python for random generation and dotenv editing without evaluating .env as code.
python3 - "$ROOT" "$TEMPLATE" <<'PY_CONFIG'
import os
from pathlib import Path
import re
import secrets
import shlex
import sys

os.umask(0o077)
root = Path(sys.argv[1]).expanduser().resolve()
root.mkdir(parents=True, exist_ok=True)
env_file = root / ".env"
lines = (env_file if env_file.exists() else Path(sys.argv[2])).read_text().splitlines()
assignment = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")
values = {}
read_settings = {"REACHY_WS_API_KEY_FILE", "REACHY_WS_HOST", "REACHY_WS_PORT",
                 "REACHY_ALLOWED_ROBOTS", "AGENT_PLATFORM_ROBOT_ID"}
for line in lines:
    match = assignment.match(line)
    if match and match[1] in read_settings:
        parts = shlex.split(match[2], comments=True)
        values[match[1]] = " ".join(parts)

key_path = Path(os.environ.get("REACHY_SHARED_API_KEY_FILE")
                or values.get("REACHY_WS_API_KEY_FILE") or ".reachy-api-key").expanduser()
if not key_path.is_absolute():
    key_path = root / key_path
key_path = key_path.resolve()
key_path.parent.mkdir(parents=True, exist_ok=True)
try:
    # Exclusive creation prevents re-runs (or concurrent setup) from rotating a key.
    with key_path.open("x") as key_file:
        key_file.write(secrets.token_hex(32) + "\n")
except FileExistsError:
    pass
key_path.chmod(0o600)
if not key_path.read_text().strip():
    raise SystemExit("Shared key file is empty; remove it and run setup again.")

host = os.environ.get("REACHY_WS_HOST") or values.get("REACHY_WS_HOST") or "127.0.0.1"
port = os.environ.get("REACHY_WS_PORT") or values.get("REACHY_WS_PORT") or "8770"
robot = values.get("AGENT_PLATFORM_ROBOT_ID") or "reachy"
updates = {
    "REACHY_WS_API_KEY_FILE": str(key_path),
    "AGENT_PLATFORM_API_KEY_FILE": str(key_path),
    # Inline keys take precedence in the components: clear stale overrides.
    "REACHY_WS_API_KEY": "",
    "AGENT_PLATFORM_API_KEY": "",
    "REACHY_WS_HOST": host,
    "REACHY_WS_PORT": port,
    "REACHY_ALLOWED_ROBOTS": values.get("REACHY_ALLOWED_ROBOTS") or "reachy",
    "AGENT_PLATFORM_ROBOT_ID": robot,
    "AGENT_PLATFORM_WS_URL": f"ws://127.0.0.1:{port}/robot/{robot}",
}
# Preserve unrelated settings/comments; collapse managed duplicates on every run.
output = []
remaining = dict(updates)
for line in lines:
    match = assignment.match(line)
    name = match[1] if match else None
    if name in updates:
        if name in remaining:
            output.append(f"{name}={shlex.quote(remaining.pop(name))}")
    else:
        output.append(line)
output.extend(f"{name}={shlex.quote(value)}" for name, value in remaining.items())
with env_file.open("w") as config:
    config.write("\n".join(output) + "\n")
env_file.chmod(0o600)
print(f"Configured {env_file}; shared key file: {key_path} (mode 600).")
PY_CONFIG

say "done"
cat <<'EOF'
Next:
  1. Edit .env — choose HTTP or full-Hermes mode and set your STT/TTS/brain endpoints.
  2. HTTP mode:  cd components/reachy_mini_conversation_app && python -m reachy_mini_conversation_app
  3. Full mode:  install hermes-reachy into your hermes-agent gateway, set
                 AGENT_TRANSPORT=platform, and load .env for BOTH processes (see README).
See docs/ARCHITECTURE.md for the full picture.
EOF
