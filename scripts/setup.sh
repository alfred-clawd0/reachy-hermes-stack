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
import stat
import sys
import tempfile

os.umask(0o077)
root = Path(sys.argv[1]).expanduser().resolve()
root.mkdir(parents=True, exist_ok=True)
env_file = (root / ".env").resolve()
lines = (env_file if env_file.exists() else Path(sys.argv[2])).read_text().splitlines()
assignment = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")
migrations = {"REACHY_WS_HOST": "STACK_REACHY_WS_HOST",
              "REACHY_WS_PORT": "STACK_REACHY_WS_PORT",
              "REACHY_ALLOWED_ROBOTS": "STACK_REACHY_ALLOWED_ROBOTS"}
inline = {"REACHY_WS_API_KEY", "AGENT_PLATFORM_API_KEY"}
removed = set(migrations) | inline | {"REACHY_WS_API_KEY_FILE"}
managed = removed | set(migrations.values()) | {
    "AGENT_PLATFORM_API_KEY_FILE", "AGENT_PLATFORM_ROBOT_ID", "AGENT_PLATFORM_WS_URL"}
values = {}
original_lines = {}
for line in lines:
    match = assignment.match(line)
    if match and match[1] in managed:
        try:
            parts = shlex.split(match[2], comments=True)
        except ValueError:
            raise SystemExit(f"Invalid quoting in {match[1]}; fix that assignment and rerun setup.")
        if match[1].endswith("API_KEY_FILE") and "\\" in match[2]:
            raise SystemExit(f"Invalid shared key path in {match[1]}: backslash is not supported.")
        values[match[1]] = " ".join(parts)
        if match[1] == "AGENT_PLATFORM_WS_URL" and not match[2].lstrip().startswith(("'", '\"')):
            # Dotenv only treats a whitespace-prefixed # as an unquoted comment.
            values[match[1]] = re.split(r"\s+#", match[2].strip(), maxsplit=1)[0]
        original_lines[match[1]] = line


def setting(old, default):
    new = migrations[old]
    return os.environ.get(old) or os.environ.get(new) or values.get(new) or values.get(old) or default


host = setting("REACHY_WS_HOST", "127.0.0.1")
port = setting("REACHY_WS_PORT", "8770")
if not re.fullmatch(r"[0-9]{1,5}", port) or not 1 <= int(port) <= 65535:
    raise SystemExit("Invalid REACHY_WS_PORT / STACK_REACHY_WS_PORT: expected integer 1-65535.")
robot = os.environ.get("AGENT_PLATFORM_ROBOT_ID") or values.get("AGENT_PLATFORM_ROBOT_ID") or "reachy"
if not re.fullmatch(r"[A-Za-z0-9_.-]+", robot):
    raise SystemExit("Invalid AGENT_PLATFORM_ROBOT_ID: expected [A-Za-z0-9_.-]+.")
allowed = setting("REACHY_ALLOWED_ROBOTS", "reachy")
if robot not in {item.strip() for item in allowed.split(",")}:
    print("Warning: AGENT_PLATFORM_ROBOT_ID is not in REACHY_ALLOWED_ROBOTS.")

raw_path = (os.environ.get("REACHY_SHARED_API_KEY_FILE")
            or values.get("AGENT_PLATFORM_API_KEY_FILE")
            or values.get("REACHY_WS_API_KEY_FILE") or ".reachy-api-key")


def validate_path(value):
    if any(char in value for char in "\"'\\$`\n\r"):
        raise SystemExit("Invalid shared key path: quotes, backslash, dollar sign, backtick, "
                         "and newline are not supported; spaces are allowed.")


validate_path(raw_path)
key_path = Path(raw_path).expanduser()
if not key_path.is_absolute():
    key_path = root / key_path
key_path = key_path.resolve()
validate_path(str(key_path))
try:
    key_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with key_path.open("x") as key_file:
            key_file.write(secrets.token_hex(32) + "\n")
    except FileExistsError:
        if stat.S_IMODE(key_path.stat().st_mode) != 0o600:
            print(f"Warning: tightening existing key file permissions to 600: {key_path}", flush=True)
    key_path.chmod(0o600)
    if not key_path.read_text().strip():
        raise SystemExit("Shared key file is empty; remove it and run setup again.")
except PermissionError:
    raise SystemExit("Permission denied accessing or securing shared key file; "
                     "use a file owned by your user or ask its owner to fix permissions.")

url = values.get("AGENT_PLATFORM_WS_URL", "")
preserve_url = False
if not url or re.fullmatch(r"ws://(?:127\.0\.0\.1|localhost):[0-9]+/robot/[A-Za-z0-9_.-]+", url):
    url = f"ws://127.0.0.1:{port}/robot/{robot}"
else:
    preserve_url = True
    print("Preserved custom AGENT_PLATFORM_WS_URL; edit the voice machine's .env to change it.")
updates = {
    "AGENT_PLATFORM_API_KEY_FILE": str(key_path),
    "STACK_REACHY_WS_HOST": host,
    "STACK_REACHY_WS_PORT": port,
    "STACK_REACHY_ALLOWED_ROBOTS": allowed,
    "AGENT_PLATFORM_ROBOT_ID": robot,
    "AGENT_PLATFORM_WS_URL": url,
}
# Report every changed/removed assignment without disclosing inline credentials.
output = []
remaining = dict(updates)
for line in lines:
    match = assignment.match(line)
    name = match[1] if match else None
    if name in removed:
        if name in inline:
            print(f"cleared inline {name}; using key file {key_path}")
        else:
            print(f"Removed {name} from stack .env; retained in gateway snippet / stack settings.")
    elif name in updates:
        if name in remaining:
            replacement = (original_lines[name] if name == "AGENT_PLATFORM_WS_URL" and preserve_url
                           else f"{name}={shlex.quote(updates[name])}")
            if line != replacement:
                print(f"Updated {name} in stack .env.")
            output.append(replacement)
            remaining.pop(name)
        else:
            print(f"Removed duplicate {name} from stack .env.")
    else:
        output.append(line)
output.extend(f"{name}={shlex.quote(value)}" for name, value in remaining.items())
# Replace the resolved target atomically, preserving a .env symlink if present.
with tempfile.NamedTemporaryFile(mode="w", dir=env_file.parent, delete=False) as config:
    temp_path = Path(config.name)
    config.write("\n".join(output) + "\n")
try:
    temp_path.chmod(0o600)
    os.replace(temp_path, env_file)
finally:
    temp_path.unlink(missing_ok=True)
print(f"Configured {env_file}; shared key file: {key_path} (mode 600).")
print("Full Hermes mode ONLY: paste these lines into ~/.hermes/.env (or your HERMES_HOME/.env).")
print("Replace stale entries and remove inline REACHY_WS_API_KEY there; setup does not edit that file.")
print("--- gateway settings ---")
for name, value in {"REACHY_WS_PORT": port, "REACHY_WS_HOST": host,
                    "REACHY_WS_API_KEY_FILE": str(key_path), "REACHY_ALLOWED_ROBOTS": allowed}.items():
    print(f"{name}={shlex.quote(value)}")
print("--- end gateway settings ---")
print("Then restart the gateway SERVICE: hermes gateway restart; also restart the voice app.")

PY_CONFIG

say "done"
cat <<'EOF'
Next:
  1. Edit .env — choose HTTP or full-Hermes mode and set your STT/TTS/brain endpoints.
  2. HTTP mode:  cd components/reachy_mini_conversation_app && python -m reachy_mini_conversation_app
  3. Full mode:  install hermes-reachy into your hermes-agent gateway, set
                 AGENT_TRANSPORT=platform, and apply the gateway settings above (see README).
See docs/ARCHITECTURE.md for the full picture.
EOF
