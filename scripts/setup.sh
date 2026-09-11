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
import ipaddress
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import sys
import tempfile
from urllib.parse import urlsplit

def configure():
    os.umask(0o077)
    root = Path(sys.argv[1]).expanduser().resolve()
    env_link = root / ".env"
    if env_link.is_symlink() and not env_link.exists():
        raise OSError("Dangling .env symlink; create its target or repair the link before rerunning setup.")
    env_file = env_link.resolve()
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
    line_values = {}
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
            line_values[line] = values[match[1]]


    sources = {}


    def setting(old, default):
        new = migrations[old]
        for mapping, name, location in ((os.environ, old, "environment"), (os.environ, new, "environment"),
                                        (values, new, "stack .env"), (values, old, "stack .env")):
            if mapping.get(name):
                sources[old] = f"{name} ({location})"
                return mapping[name]
        sources[old] = "default"
        return default


    host = setting("REACHY_WS_HOST", "127.0.0.1")
    bracketed = host.startswith("[") and host.endswith("]")
    if bracketed:
        host = host[1:-1]
    try:
        address = ipaddress.ip_address(host)
        if bracketed and address.version != 6:
            raise ValueError("Brackets require IPv6")
        host = str(address)
    except ValueError:
        label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
        if bracketed or len(host) > 253 or not re.fullmatch(rf"{label}(?:\.{label})*\.?", host):
            raise SystemExit("Invalid REACHY_WS_HOST / STACK_REACHY_WS_HOST: expected IP address or RFC 1123 hostname.")
    port = setting("REACHY_WS_PORT", "8770")
    if not re.fullmatch(r"[1-9][0-9]{0,4}", port) or not 1 <= int(port) <= 65535:
        raise SystemExit("Invalid REACHY_WS_PORT / STACK_REACHY_WS_PORT: expected integer 1-65535 without leading zeros.")
    robot = os.environ.get("AGENT_PLATFORM_ROBOT_ID") or values.get("AGENT_PLATFORM_ROBOT_ID") or "reachy"
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", robot):
        raise SystemExit("Invalid AGENT_PLATFORM_ROBOT_ID: expected [A-Za-z0-9_.-]+.")
    allowed = setting("REACHY_ALLOWED_ROBOTS", "reachy")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*", allowed):
        raise SystemExit("Invalid STACK_REACHY_ALLOWED_ROBOTS / REACHY_ALLOWED_ROBOTS: "
                         "expected comma-separated IDs matching [A-Za-z0-9_.-]+ (no whitespace).")
    if robot not in set(allowed.split(",")):
        print("Warning: AGENT_PLATFORM_ROBOT_ID is not in REACHY_ALLOWED_ROBOTS.")

    url = values.get("AGENT_PLATFORM_WS_URL", "")
    previous_port = values.get("STACK_REACHY_WS_PORT") or values.get("REACHY_WS_PORT") or "8770"
    previous_robot = values.get("AGENT_PLATFORM_ROBOT_ID") or "reachy"
    loopback = re.fullmatch(r"ws://(?:127\.0\.0\.1|localhost):([0-9]+)/robot/([A-Za-z0-9_.-]+)", url)
    preserve_url = bool(url) and not (loopback and loopback[1] == previous_port and loopback[2] == previous_robot)
    if preserve_url:
        print("Preserved custom AGENT_PLATFORM_WS_URL; edit the voice machine's .env to change it.")
        if loopback and loopback[1] != port:
            print(f"voice URL port {loopback[1]} != gateway port {port} (expected only for an SSH tunnel)")
    else:
        url = f"ws://127.0.0.1:{port}/robot/{robot}"

    raw_path = (os.environ.get("REACHY_SHARED_API_KEY_FILE")
                or values.get("AGENT_PLATFORM_API_KEY_FILE")
                or values.get("REACHY_WS_API_KEY_FILE") or ".reachy-api-key")


    def validate_path(value):
        if any(char in value for char in "\"'\\$`\n\r"):
            raise SystemExit("Invalid shared key path: quotes, backslash, dollar sign, backtick, "
                             "and newline are not supported; spaces are allowed.")


    def resolve_key_path(value):
        path = Path(value).expanduser()
        return (path if path.is_absolute() else root / path).resolve()

    validate_path(raw_path)
    key_path = resolve_key_path(raw_path)
    validate_path(str(key_path))
    try:
        for parent in key_path.parents:
            if parent.exists() and not parent.is_dir():
                raise OSError(f"Shared key path parent is a regular file: {parent}")
        if preserve_url and not key_path.is_file():
            raise SystemExit(f"AGENT_PLATFORM_WS_URL is custom/remote; copy the gateway's key file to {key_path} (mode 600) and rerun")
        if key_path.exists():
            if not key_path.is_file():
                raise OSError("Shared key path must be a regular file, not a directory or special file.")
            if not key_path.read_text().strip():
                if preserve_url:
                    raise SystemExit("Shared key file is empty; re-copy the gateway's key and rerun.")
                raise SystemExit("Shared key file is empty; remove it and run setup again.")
    except PermissionError:
        raise SystemExit("Permission denied accessing shared key file; use a readable file owned by your user.")

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
                kept = str(key_path) if name == "REACHY_WS_API_KEY_FILE" else updates[migrations[name]]
                old = line_values[line]
                comparable = str(resolve_key_path(old)) if name == "REACHY_WS_API_KEY_FILE" and old else old
                if comparable != kept:
                    if name == "REACHY_WS_API_KEY_FILE":
                        winner = ("REACHY_SHARED_API_KEY_FILE (environment)" if os.environ.get("REACHY_SHARED_API_KEY_FILE")
                                  else "AGENT_PLATFORM_API_KEY_FILE" if values.get("AGENT_PLATFORM_API_KEY_FILE")
                                  else "resolved REACHY_WS_API_KEY_FILE")
                        print(f"Conflict: {name}={old!r} discarded; {winner}={kept!r} won.")
                    elif name == "REACHY_WS_PORT":
                        print(f"Conflict: {name}={old!r} discarded; {sources[name]}={kept!r} won.")
                    else:
                        print(f"Conflict: {name} discarded; {sources[name]} won.")
                print(f"{name} moved to the gateway block below; the stack .env no longer configures the gateway.")
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
    temp_path = None
    created_key = False
    committed = False
    try:
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=env_file.parent, delete=False) as config:
            temp_path = Path(config.name)
            config.write("\n".join(output) + "\n")
        temp_path.chmod(0o600)
        # Prepare the entire config before creating or changing the shared key.
        try:
            key_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                with key_path.open("x") as key_file:
                    created_key = True
                    key_file.write(secrets.token_hex(32) + "\n")
            except FileExistsError:
                if stat.S_IMODE(key_path.stat().st_mode) != 0o600:
                    print(f"Warning: tightening existing key file permissions to 600: {key_path}", flush=True)
            key_path.chmod(0o600)
        except PermissionError:
            raise SystemExit("Permission denied accessing or securing shared key file; "
                             "use a file owned by your user or ask its owner to fix permissions.")
        os.replace(temp_path, env_file)
        committed = True
    except PermissionError:
        raise SystemExit(f"Cannot write stack configuration at {env_file}; check directory ownership and permissions.")
    finally:
        if created_key and not committed:
            key_path.unlink(missing_ok=True)
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)
    print(f"Configured {env_file}; shared key file: {key_path} (mode 600).")
    print("Full Hermes mode ONLY: paste these lines into ~/.hermes/.env (or your HERMES_HOME/.env).")
    print("Replace stale entries and remove inline REACHY_WS_API_KEY there; setup does not edit that file.")
    if preserve_url and urlsplit(url).hostname not in {"127.0.0.1", "localhost", "::1"}:
        print("For the gateway machine, not this one: use its local key-file path when applying this block.")
    print("--- gateway settings ---")
    for name, value in {"REACHY_WS_PORT": port, "REACHY_WS_HOST": host,
                        "REACHY_WS_API_KEY_FILE": str(key_path), "REACHY_ALLOWED_ROBOTS": allowed}.items():
        print(f"{name}={shlex.quote(value)}")
    print("--- end gateway settings ---")
    print("Then restart the gateway SERVICE: hermes gateway restart; also restart the voice app.")


try:
    configure()
except OSError as exc:
    raise SystemExit(f"Cannot configure Reachy stack: {exc}")

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
