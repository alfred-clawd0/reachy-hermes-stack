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
./scripts/setup.sh          # clones + installs the components, scaffolds .env
cp .env.example .env        # then edit: point STT/TTS/brain at your endpoints
```

Then, depending on mode:

**HTTP mode**

```bash
# .env: BACKEND_PROVIDER=local, AGENT_TRANSPORT=http, AGENT_BASE_URL=<your OpenAI-compatible agent>
cd components/reachy_mini_conversation_app
python -m reachy_mini_conversation_app        # or the gradio UI for the simulator
```

**Full Hermes mode**

```bash
# 1) Brain: install the plugin into your hermes-agent, set REACHY_WS_PORT=8770, start the gateway.
pip install "hermes-reachy @ git+https://github.com/ai-ag2026/hermes-reachy"
# 2) Body: .env AGENT_TRANSPORT=platform, AGENT_PLATFORM_WS_URL=ws://<gateway-host>:8770/robot/reachy
cd components/reachy_mini_conversation_app
python -m reachy_mini_conversation_app
```

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
