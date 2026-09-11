# Contributing to reachy-hermes-stack

This is the umbrella / quickstart. Most changes belong in the component repos:

- Body app behavior → [`reachy_mini_conversation_app`](https://github.com/ai-ag2026/reachy_mini_conversation_app)
- Voice pipeline / runtime → [`reachy-hermes-agent`](https://github.com/ai-ag2026/reachy-hermes-agent)
- Gateway channel / body tool → [`hermes-reachy`](https://github.com/ai-ag2026/hermes-reachy)

Open changes here for: the quickstart, `setup.sh`, the consolidated `.env.example`, the architecture
docs, or a new deployment recipe. Keep it honest — don't add a one-command path that doesn't actually
run end to end. No hardcoded hosts, ports, ids, or secrets: everything stays `.env`-driven.

Small, reviewable PRs with conventional commit subjects (`feat:`, `fix:`, `docs:`).

## Tests

Install ShellCheck first (for example, `brew install shellcheck` on macOS).
Use a virtual environment, then run from the repository root:

```bash
python3 -m venv /tmp/reachy-stack-tests-venv
source /tmp/reachy-stack-tests-venv/bin/activate
python -m pip install python-dotenv
python -m unittest discover -s tests -p 'test_setup.py' -v
bash -n scripts/setup.sh
shellcheck scripts/*.sh
git diff --check
```

Tests run only the configuration phase with temporary HOME, stack, key, and configuration paths.
They do not install components or access a real Hermes home. The legacy-template fixture is
checked in, so the suite also works in shallow clones and source archives.
