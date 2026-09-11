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
cd components/reachy_mini_conversation_app
python -m reachy_mini_conversation_app        # or the gradio UI for the simulator
```

**Full Hermes mode**

Edit the stack `.env` to set `AGENT_TRANSPORT=platform`, then install the plugin into the
Python environment used by your Hermes gateway:

```bash
pip install "hermes-reachy @ git+https://github.com/ai-ag2026/hermes-reachy"
./scripts/setup.sh --config-only
```

Setup prints a **gateway settings** block containing `REACHY_WS_PORT`, `REACHY_WS_HOST`,
`REACHY_WS_API_KEY_FILE` with the actual absolute key path, and `REACHY_ALLOWED_ROBOTS`.
Choose one of these gateway launch paths:

- **Normal service (systemd/launchd):** paste that block into `~/.hermes/.env` (or
  `$HERMES_HOME/.env` for a custom Hermes home), replacing stale entries. Remove any inline
  `REACHY_WS_API_KEY` there so the key file is used. For a new service, install it with
  `hermes gateway install`; then run `hermes gateway restart`. Service units do not inherit
  these settings from your interactive shell. Setup prints the block but **never writes your
  Hermes home**. The service user must be able to read the mode-600 key file.
- **Foreground:** save just the printed assignment lines to a private file such as
  `/absolute/private/path/reachy-gateway.env`, then source that file and run:

  ```bash
  set -a; source /absolute/private/path/reachy-gateway.env; set +a
  hermes gateway run
  ```

  Hermes loads its own `~/.hermes/.env` with precedence over the shell, so remove or align stale
  `REACHY_WS_*` entries there first, including any inline key. Source only the generated gateway
  assignment block; general dotenv files may contain unquoted spaces that are not shell syntax.
  Pasting the block into `~/.hermes/.env` also works for foreground runs, since Hermes loads it
  anyway; in that case, you can run `hermes gateway run` without sourcing a separate file.

As an alternative, the matching adapter accepts the settings in the Reachy platform's `extra`
block in Hermes `config.yaml`. Use **either the environment block or `extra`, not both**.
When `REACHY_WS_PORT` is in the gateway environment, Hermes' environment seeding overrides
`extra` host, port, and key-file settings. An inline `api_key` / `REACHY_WS_API_KEY` always beats
any key file. `allowed_robots` always prefers `REACHY_ALLOWED_ROBOTS` from the environment
over YAML (falling back to YAML when the environment value is empty). This behavior depends on the pending
[hermes-reachy auth version (PR #1)](https://github.com/ai-ag2026/hermes-reachy/pull/1):

```yaml
platforms:
  reachy:
    enabled: true
    extra:
      host: 127.0.0.1
      port: 8770
      api_key_file: /absolute/path/printed/by/setup/.reachy-api-key
      allowed_robots: [reachy]
```

Remove a stale inline `api_key` from that block as well. Use the actual absolute key path printed
by setup. Restart the gateway service after changing its config.

Start the voice app from the stack directory in another terminal:

```bash
cd components/reachy_mini_conversation_app
python -m reachy_mini_conversation_app
```

The app loads `.env` by searching upward from its working directory; a component-local `.env`
takes precedence over the stack file. Its dotenv loader overrides shell values. Edit the `.env`
that it will actually find. For a fully environment-configured launch, the public fork supports
`REACHY_MINI_SKIP_DOTENV=1`; supply all required app settings yourself in that case.
See the [app loader](https://github.com/ai-ag2026/reachy_mini_conversation_app/blob/local-agent-backend/src/reachy_mini_conversation_app/config.py#L342),
[Hermes env loader](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/env_loader.py),
and [service generation](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/gateway.py)
for configuration precedence.

Setup creates a cryptographically random shared key in `.reachy-api-key` in the stack directory
(mode `600`, ignored by Git). The voice `.env` gets `AGENT_PLATFORM_API_KEY_FILE`; the printed
gateway block gets `REACHY_WS_API_KEY_FILE`, both with the same absolute path. The client sends
the key in its first `hello` frame; the adapter closes unauthenticated connections with code `1008`.

Re-running setup keeps the existing key and reports changes to managed assignments. It deletes
inline `REACHY_WS_API_KEY` / `AGENT_PLATFORM_API_KEY` entries from the stack `.env` with a notice;
it never prints their contents. Also remove stale inline keys from the app's launch environment or
component-local `.env`. Choose another key location with
`REACHY_SHARED_API_KEY_FILE=/absolute/private/path/reachy-key ./scripts/setup.sh` (keep custom
key files outside Git). Relative paths resolve against the stack directory; spaces are supported,
but quotes, backslashes, dollar signs, backticks, and newlines are rejected. Setup warns before
tightening an existing key's permissions and reports permission failures without a traceback.
Subsequent runs reuse the path recorded in `.env`. To rotate, delete the gateway's key file and
re-run setup on the gateway machine. Copy the new key to voice machines before rerunning setup
there. Restart **the gateway SERVICE** (`hermes gateway restart`) **and the voice app**.
For a foreground gateway, stop and relaunch `hermes gateway run`.

The stack stores gateway defaults under `STACK_REACHY_WS_HOST=127.0.0.1`,
`STACK_REACHY_WS_PORT=8770`, and `STACK_REACHY_ALLOWED_ROBOTS=reachy`. These names do not enable
the plugin when an HTTP-mode user loads the stack `.env`. Setup migrates old gateway `REACHY_*`
assignments to these names / the printed block. Environment overrides win, followed by stack-local
names, then legacy names. For key paths, `REACHY_SHARED_API_KEY_FILE` wins, then
`AGENT_PLATFORM_API_KEY_FILE`, then legacy `REACHY_WS_API_KEY_FILE`. Setup reports conflicts and
which setting won; conflicting paths and ports are shown, never key contents. The stack `.env`
no longer configures the gateway; apply the printed block on the gateway machine.
The corresponding `REACHY_WS_HOST`, `REACHY_WS_PORT`, and `REACHY_ALLOWED_ROBOTS` environment
overrides are also accepted by setup, as is `AGENT_PLATFORM_ROBOT_ID` (default `reachy`).
Ports must be integers from 1 through 65535 without leading zeros. Robot IDs allow letters,
digits, underscores, dots, and hyphens; allowlists contain these IDs separated by commas without
whitespace. Hosts must be IP addresses or RFC 1123 hostnames. Brackets around IPv6 addresses
are stripped before storing and printing the bind host (for example, `[::1]` becomes `::1`). Setup warns if the client
robot ID is absent from the allowlist.

Setup generates `ws://127.0.0.1:<port>/robot/<id>` for an absent/empty URL. It updates an existing
`ws://127.0.0.1:<port>/robot/<id>` or `ws://localhost:<port>/robot/<id>` URL only when its port
matches the stored `STACK_REACHY_WS_PORT` (or legacy `REACHY_WS_PORT`) **or the template
default `8770`**, and its ID matches the stored `AGENT_PLATFORM_ROBOT_ID` (default `reachy`), before any
environment overrides. For example, `REACHY_WS_PORT=9880 ./scripts/setup.sh --config-only`
updates a matching URL and records the new port. Copying the template and changing only
`STACK_REACHY_WS_PORT` to `9000` also updates the template URL from `8770` to `9000`.
A tunnel URL using another non-matching local port,
such as `18770`, is preserved with a notice, as are other custom URLs. A kept loopback URL with
a different port prints a mismatch warning: this is expected only for an SSH tunnel. Loopback
URLs still allow setup to generate a missing local key. If this is a tunnel to a remote gateway,
replace that local key with a copy of the gateway's key before connecting.
`AGENT_TRANSPORT=http` is preserved on reruns.
`./scripts/setup.sh --config-only` skips cloning and installing. `REACHY_STACK_DIR=/temporary/stack`
relocates generated configuration, the default key, **and `components/` in a normal run**.

For a voice app on **another machine**, direct LAN access requires `REACHY_WS_HOST=0.0.0.0`
in the gateway's own config (use `STACK_REACHY_WS_HOST=0.0.0.0` to generate that snippet), plus
a securely transferred copy of the key on the voice machine (mode `600`). Edit the voice
machine's `.env`: set `AGENT_PLATFORM_API_KEY_FILE` to the local copy's absolute path and
`AGENT_PLATFORM_WS_URL=ws://<gateway-host>:8770/robot/reachy`. Setup preserves that remote URL
and key path on reruns. Only a URL with a non-loopback host requires the copied key to exist;
setup exits with copy instructions rather than generating a mismatched local key. For a genuinely remote
URL, the printed gateway block is labeled for the gateway machine; use its local key path there.
**`ws://` is plaintext on the LAN**, including the key. Prefer an SSH tunnel:
keep the gateway bound to loopback, run `ssh -N -L 8770:127.0.0.1:8770 user@gateway-host` on the
voice machine, and use the loopback client URL with the copied key.

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
