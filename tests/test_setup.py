"""Run only setup's configuration phase, with all destinations in a temporary home."""
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import unittest


SETUP = Path(__file__).resolve().parents[1] / "scripts/setup.sh"


class SetupTest(unittest.TestCase):
    def test_sandboxed_configuration(self):
        for custom in (False, True):
            with self.subTest(custom_key=custom), tempfile.TemporaryDirectory() as temp:
                home = Path(temp).resolve()
                stack = home / "stack with spaces"
                key = home / "private key" if custom else stack / ".reachy-api-key"
                env = {"PATH": os.environ["PATH"], "HOME": str(home),
                       "REACHY_STACK_DIR": str(stack)}
                if custom:
                    env.update(REACHY_SHARED_API_KEY_FILE=str(key), REACHY_WS_PORT="9880")
                    key.write_text("existing-key\n")
                    key.chmod(0o644)
                    stack.mkdir()
                    (stack / ".env").write_text(
                        "AGENT_TRANSPORT=platform\nUNRELATED=keep-me\n"
                        "REACHY_WS_API_KEY=stale\nAGENT_PLATFORM_API_KEY=stale\n"
                        "AGENT_PLATFORM_API_KEY_FILE=old\nAGENT_PLATFORM_API_KEY_FILE=old\n"
                    )

                def run():
                    return subprocess.run(
                        ["bash", str(SETUP), "--config-only"], env=env,
                        cwd=home, check=True, capture_output=True, text=True,
                    )

                first = run()
                secret = key.read_bytes()
                config = (stack / ".env").read_bytes()
                self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
                self.assertNotIn(secret.decode().strip(), first.stdout + first.stderr)
                if custom:
                    self.assertEqual(secret, b"existing-key\n")
                    self.assertIn(b"UNRELATED=keep-me\n", config)
                else:
                    self.assertRegex(secret.decode(), r"^[0-9a-f]{64}\n$")
                # Source the generated config just as both quickstart shells do.
                result = subprocess.run(
                    ["bash", "-c", 'set -a; source "$1"; '
                     'printf "%s\\n" "$REACHY_WS_API_KEY_FILE" "$AGENT_PLATFORM_API_KEY_FILE" '
                     '"$REACHY_WS_HOST" "$AGENT_PLATFORM_WS_URL" '
                     '"$REACHY_WS_API_KEY" "$AGENT_PLATFORM_API_KEY"', "bash", str(stack / ".env")],
                    env=env, cwd=home, check=True, capture_output=True, text=True,
                )
                port = "9880" if custom else "8770"
                self.assertEqual(result.stdout.splitlines(), [str(key), str(key), "127.0.0.1",
                                 f"ws://127.0.0.1:{port}/robot/reachy", "", ""])
                # The recorded custom path and port must survive without overrides.
                env.pop("REACHY_SHARED_API_KEY_FILE", None)
                env.pop("REACHY_WS_PORT", None)
                run()
                self.assertEqual(key.read_bytes(), secret)
                self.assertEqual((stack / ".env").read_bytes(), config)
                names = [shlex.split(line)[0].split("=", 1)[0] for line in config.decode().splitlines()
                         if line and not line.startswith("#")]
                self.assertEqual(len(names), len(set(names)))
                self.assertFalse((stack / "components").exists())
                self.assertFalse((home / ".hermes").exists())


if __name__ == "__main__":
    unittest.main()
