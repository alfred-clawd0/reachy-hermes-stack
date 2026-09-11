# Architecture

The stack splits cleanly into a **body** (the robot) and a **brain** (an agent), joined by one of two
transports. Speech and motion always stay on the body; the brain only ever exchanges *text* (plus body
*tool calls* in full mode).

## Data flow

```
  ┌──────────────────────── BODY (on / near the robot) ────────────────────────┐
  │  mic ─▶ VAD ─▶ STT ─▶  [ text ]  ─▶  transport  ─▶  BRAIN                    │
  │                                                       │                     │
  │  speaker ◀─ TTS ◀─ [ streamed text ] ◀─ transport ◀───┘                     │
  │  camera, motors, antennas, aliveness  ◀─ reachy_body tool (full mode)       │
  └────────────────────────────────────────────────────────────────────────────┘

  reachy_mini_conversation_app  (body app; uses reachy-hermes-agent for the voice pipeline)
```

STT, VAD, TTS, half-duplex/barge-in, and bounded motion all live on the body. This keeps the real-time
audio loop local and the transport light.

## Transports

### HTTP mode (`AGENT_TRANSPORT=http`)
The body app POSTs each completed user turn to `AGENT_BASE_URL/chat/completions` and streams the reply
back into TTS. The brain is **any** OpenAI-compatible endpoint — no hermes-agent required. Stateless per
turn; the body app manages the conversation window.

### Full Hermes mode (`AGENT_TRANSPORT=platform`)
The body app opens a persistent WebSocket to the gateway's `reachy` channel (served by the
`hermes-reachy` plugin) at `AGENT_PLATFORM_WS_URL` (default `ws://127.0.0.1:8770/robot/reachy`). Now:

- the agent sees the robot as a **channel** (memory across turns, tools, proactive / cron delivery);
- the agent can call the **`reachy_body`** tool to emote / dance / look / stop / toggle head-tracking / chirp.

## WebSocket protocol (full mode)

The body app is the client. Frames are JSON. The first frame must be an authenticated `hello`,
sent within 10 seconds of connection. The gateway rejects missing/invalid authentication with
WebSocket close code `1008`. This requires the matching
[hermes-reachy auth version](https://github.com/alfred-clawd0/hermes-reachy/tree/ws-auth-hardening).

```
inbound  (app → gateway):  {"type":"hello","robot_id":"reachy","api_key":"<shared key>"}
                           {"type":"stt","text":"...","turn_id":"t1","robot_id":"reachy"}
                           {"type":"interrupt","text":"...","robot_id":"reachy"}
                           {"type":"tool_result","tool_call_id":"...","result":{...}}
outbound (gateway → app):  {"type":"say","kind":"stream","message_id":"m1","content":"...","final":false,"turn_id":"t1"}
                           {"type":"typing","robot_id":"reachy"}
                           {"type":"turn_end","robot_id":"reachy","outcome":"..."}
                           {"type":"tool_call","tool_call_id":"...","action":"emote","params":{"emotion":"happy"}}
```

Replies stream as progressive `say` edits (same `message_id`, growing `content`); the app diffs and
speaks new clauses. `turn_id` distinguishes an interactive reply (`origin=turn`) from an unsolicited
proactive delivery (`origin=proactive`). An inbound frame arriving mid-generation cancels the current
turn — that is how barge-in maps onto the channel model.

## Components

| Component | Repo | Provides |
|-----------|------|----------|
| Body app | [`reachy_mini_conversation_app`](https://github.com/alfred-clawd0/reachy_mini_conversation_app) (fork) | mic/STT/TTS/speaker/camera/motion, `local` backend, both transports |
| Voice runtime | [`reachy-hermes-agent`](https://github.com/alfred-clawd0/reachy-hermes-agent) | STT front-end, semantic barge-in, streaming TTS, body/vision policies, neutral runtime primitives |
| Agent plugin | [`hermes-reachy`](https://github.com/alfred-clawd0/hermes-reachy) | the gateway-side `reachy` channel + `reachy_body` tool (full mode) |

## Safety

Body actions are advisory: the body app owns the client-side allowlist and bounded execution
(antennas / body-yaw preserved, clamped deltas). Vision is one-shot and never persists raw frames. The
transport never drives motors directly.
