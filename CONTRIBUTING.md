# Contributing to reachy-hermes-stack

This is the umbrella / quickstart. Most changes belong in the component repos:

- Body app behavior → [`reachy_mini_conversation_app`](https://github.com/ai-ag2026/reachy_mini_conversation_app)
- Voice pipeline / runtime → [`reachy-hermes-agent`](https://github.com/ai-ag2026/reachy-hermes-agent)
- Gateway channel / body tool → [`hermes-reachy`](https://github.com/ai-ag2026/hermes-reachy)

Open changes here for: the quickstart, `setup.sh`, the consolidated `.env.example`, the architecture
docs, or a new deployment recipe. Keep it honest — don't add a one-command path that doesn't actually
run end to end. No hardcoded hosts, ports, ids, or secrets: everything stays `.env`-driven.

Small, reviewable PRs with conventional commit subjects (`feat:`, `fix:`, `docs:`).
