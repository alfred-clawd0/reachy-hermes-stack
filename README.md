# reachy-hermes-stack

**Give a [Hermes](https://github.com/NousResearch/hermes-agent) agent — or any OpenAI-compatible
model — a [Reachy Mini](https://www.pollen-robotics.com/reachy-mini/) body.** Speech in, speech out,
expressive movement, and (in full mode) memory, tools, and proactive delivery.

This is the umbrella / quickstart that wires three open components into one running robot. It bundles
nothing itself — it clones, installs, and configures the parts, so you can rebuild the whole setup in
a few commands.

## Components

| Repo | Role |
|------|------|
| [`reachy_mini_conversation_app`](https://github.com/ai-ag2026/reachy_mini_conversation_app) (fork, branch `local-agent-backend`) | **Body app** — runs on/near the robot: mic, VAD, STT, TTS, speaker, camera, motion. |
| [`reachy-hermes-agent`](https://github.com/ai-ag2026/reachy-hermes-agent) | **Brain-side runtime** — the voice pipeline / body policies the body app uses (`pip install reachy-hermes-agent`). |
| [`hermes-reachy`](https://github.com/ai-ag2026/hermes-reachy) | **Agent plugin** — gives the Hermes gateway a `reachy` channel + `reachy_body` tool (full mode only). |

You also bring **STT**, **TTS**, and a **brain** (any OpenAI-compatible endpoints). Nothing here ships
real endpoints — everything is `.env`-driven with `127.0.0.1` placeholders.

## Two modes

```
HTTP mode (simplest) — works with ANY OpenAI-compatible agent:

   robot voice app ──HTTP /chat/completions──▶  your agent (LLM)
        │  local STT ◀──┐  local TTS ──▶ speaker
        └───────────────┘
   AGENT_TRANSPORT=http


Full Hermes mode (our setup) — memory, tools, proactive delivery, body control:

   robot voice app ──WebSocket──▶  hermes-agent gateway + hermes-reachy plugin
        │                              │  (reachy channel + reachy_body tool)
        │  local STT / TTS             ▼
        └──────────────         drives body via reachy_body
   AGENT_TRANSPORT=platform
```

In HTTP mode you don't need hermes-agent at all — the body app talks to any `/chat/completions`
backend. In full mode the body app connects to the gateway's `reachy` WebSocket (served by the
`hermes-reachy` plugin), and the agent can see the robot as a channel, remember across turns, run
tools, and drive the body.

## Quickstart

```bash
git clone https://github.com/ai-ag2026/reachy-hermes-stack
cd reachy-hermes-stack
./scripts/setup.sh          # clones + installs components, configures .env and shared key
# Edit .env: point STT/TTS/brain at your endpoints. Keep the generated key-file paths.
```

Then, depending on mode:

**HTTP mode**

```bash
# .env: BACKEND_PROVIDER=local, AGENT_TRANSPORT=http, AGENT_BASE_URL=<your OpenAI-compatible agent>
set -a; source .env; set +a
cd components/reachy_mini_conversation_app
python -m reachy_mini_conversation_app        # or the gradio UI for the simulator
```

**Full Hermes mode**

```bash
# 1) Edit the generated .env: set AGENT_TRANSPORT=platform.
# 2) Brain: install the plugin in the Python environment used by your Hermes gateway.
pip install "hermes-reachy @ git+https://github.com/ai-ag2026/hermes-reachy"
# From the stack directory, load .env BEFORE starting the gateway in this shell:
set -a; source .env; set +a
# Start your Hermes gateway with its usual command.

# 3) Body: in a second shell, from the stack directory:
set -a; source .env; set +a
cd components/reachy_mini_conversation_app
python -m reachy_mini_conversation_app
```

Setup creates a cryptographically random shared key in `.reachy-api-key` in the stack directory
(mode `600`, ignored by Git). It writes the same absolute path into `.env` as
`REACHY_WS_API_KEY_FILE` for the gateway/plugin and `AGENT_PLATFORM_API_KEY_FILE` for the
voice app. Both processes must load this configuration: setting only the gateway variable leaves
the client unauthenticated. The client sends the key in its first `hello` frame; the adapter closes
unauthenticated connections with code `1008`.

Re-running setup keeps the existing key and updates managed settings without duplicate entries.
It clears inline `REACHY_WS_API_KEY` / `AGENT_PLATFORM_API_KEY` entries in `.env` so they cannot
override the shared file. To choose another key location, run
`REACHY_SHARED_API_KEY_FILE=/absolute/private/path/reachy-key ./scripts/setup.sh` (keep custom
key files outside Git). Relative paths resolve against the stack directory. Subsequent runs reuse
the path recorded in `.env`. To rotate the key, delete that key file, re-run setup, and restart
**both** the gateway and voice app.

The default gateway bind is `REACHY_WS_HOST=127.0.0.1`, port `8770`, and the client URL is
`ws://127.0.0.1:8770/robot/reachy`; the default allowed robot and client robot ID are `reachy`.
Set `REACHY_WS_PORT` in `.env` (or the setup environment) to change the port; setup regenerates
the loopback client URL to match. For configuration only, without cloning or installing, use
`./scripts/setup.sh --config-only`. `REACHY_STACK_DIR=/temporary/stack` directs all generated
configuration and the default key there, which is useful for sandbox verification.

For a voice app on **another machine**, direct LAN access requires
`REACHY_WS_HOST=0.0.0.0` on the gateway and a securely transferred copy of the key on the voice
machine (also mode `600`). Set that machine's `AGENT_PLATFORM_API_KEY_FILE` to its local copy's
absolute path and `AGENT_PLATFORM_WS_URL=ws://<gateway-host>:8770/robot/reachy` in the voice
process environment, after loading any stack `.env`. **`ws://` is plaintext on the LAN**, including
the key. Prefer an SSH tunnel: keep the gateway bound to loopback, run
`ssh -N -L 8770:127.0.0.1:8770 user@gateway-host` on the voice machine, and use the loopback
client URL with the copied key.

This requires matching versions of **hermes-reachy** and **reachy_mini_conversation_app** that
support the authenticated `hello` and the respective key-file variables. Their coordinated auth
PRs are in flight; use revisions containing both changes before trying full mode.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the data flow, the WebSocket protocol, and
what runs where.

## What runs where

| Piece | Where | Notes |
|-------|-------|-------|
| Body app | on/near the robot | needs the Reachy daemon (`REACHY_DAEMON_BASE_URL`) |
| STT / TTS | your choice | any OpenAI-compatible endpoints; run locally or remote |
| Brain | your choice | any `/chat/completions` (HTTP mode) or a hermes-agent gateway (full mode) |
| `hermes-reachy` plugin | in the hermes-agent gateway | full mode only |

No robot? The body app runs against the **MuJoCo simulator** — see the body app's README.

## License

MIT.
