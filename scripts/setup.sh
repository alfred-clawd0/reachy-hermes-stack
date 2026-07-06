#!/usr/bin/env bash
# reachy-hermes-stack setup — clone + install the components, scaffold .env.
# Idempotent: safe to re-run. Nothing here contacts a robot or starts a service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

if [ ! -f "$ROOT/.env" ]; then
  say "scaffold .env from .env.example"
  cp "$ROOT/.env.example" "$ROOT/.env"
  echo "  Created .env — edit it: point STT/TTS/brain at your endpoints."
else
  echo "  .env already exists — leaving it untouched."
fi

say "done"
cat <<'EOF'
Next:
  1. Edit .env — choose HTTP or full-Hermes mode and set your STT/TTS/brain endpoints.
  2. HTTP mode:  cd components/reachy_mini_conversation_app && python -m reachy_mini_conversation_app
  3. Full mode:  install hermes-reachy into your hermes-agent gateway (REACHY_WS_PORT),
                 set AGENT_TRANSPORT=platform, then start the body app.
See docs/ARCHITECTURE.md for the full picture.
EOF
