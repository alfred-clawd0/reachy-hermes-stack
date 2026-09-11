"""Sandboxed configuration regressions; install python-dotenv to run these tests."""
import io
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest

from dotenv import dotenv_values

SETUP = Path(__file__).resolve().parents[1] / "scripts/setup.sh"
TEMPLATE = SETUP.parents[1] / ".env.example"


class SetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.stack = self.home / "stack with spaces"
        self.stack.mkdir()
        self.config = self.stack / ".env"
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.home),
                    "REACHY_STACK_DIR": str(self.stack)}

    def run_setup(self, success=True):
        result = subprocess.run(["bash", str(SETUP), "--config-only"], env=self.env,
                                cwd=self.home, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse((self.stack / "components").exists())
        self.assertFalse((self.home / ".hermes").exists())
        return result

    def test_configuration_scenarios(self):
        old = subprocess.check_output(["git", "show", "9f4bc57:.env.example"],
                                      cwd=SETUP.parents[1], text=True)
        scenarios = {
            "default": TEMPLATE.read_text(),
            "custom_key": "AGENT_TRANSPORT=http\nREACHY_WS_HOST=0.0.0.0\n",
            "remote": "AGENT_TRANSPORT=http\nAGENT_PLATFORM_WS_URL=wss://gateway.example/voice\n",
            "remote_fragment": "AGENT_TRANSPORT=http\nAGENT_PLATFORM_WS_URL=wss://gateway.example/voice#fragment\n",
            "old_template_remote": old + "\nAGENT_PLATFORM_WS_URL=ws://gateway:8770/robot/reachy\n"
                                   "REACHY_WS_HOST=0.0.0.0\nREACHY_WS_PORT=9880\n",
            "localhost": "AGENT_PLATFORM_WS_URL=ws://localhost:1234/robot/old\n",
        }
        for scenario, initial in scenarios.items():
            with self.subTest(scenario=scenario):
                self.env = {"PATH": os.environ["PATH"], "HOME": str(self.home),
                            "REACHY_STACK_DIR": str(self.stack)}
                key = self.stack / ".reachy-api-key"
                key.unlink(missing_ok=True)
                if scenario == "custom_key":
                    key = self.home / "private key"
                    key.write_text("existing-key\n")
                    key.chmod(0o644)
                    self.env.update(REACHY_SHARED_API_KEY_FILE=str(key), REACHY_WS_PORT="9880")
                self.config.write_text(initial + "\nAGENT_PLATFORM_API_KEY=stale-secret\n"
                                       "REACHY_WS_API_KEY=stale-secret\n"
                                       "UNRELATED=unquoted spaces\n")
                first = self.run_setup()
                secret = key.read_bytes()
                config = self.config.read_bytes()
                data = dotenv_values(self.config)
                gateway = dotenv_values(stream=io.StringIO(first.stdout.split(
                    "--- gateway settings ---\n")[1].split("--- end gateway settings ---")[0]))
                self.assertEqual(data["AGENT_PLATFORM_API_KEY_FILE"], str(key))
                self.assertEqual(gateway["REACHY_WS_API_KEY_FILE"], str(key))
                self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
                self.assertNotIn(secret.decode().strip(), first.stdout + first.stderr)
                self.assertNotIn("stale-secret", first.stdout + first.stderr)
                for name in ("AGENT_PLATFORM_API_KEY", "REACHY_WS_API_KEY"):
                    self.assertNotIn(name, data)
                    self.assertIn(f"cleared inline {name}; using key file {key}", first.stdout)
                self.assertFalse(any(name.startswith("REACHY_WS_") for name in data))
                self.assertEqual(data["UNRELATED"], "unquoted spaces")
                expected_port = "9880" if scenario in {"custom_key", "old_template_remote"} else "8770"
                self.assertEqual(gateway["REACHY_WS_PORT"], expected_port)
                self.assertEqual(gateway["REACHY_WS_HOST"], "0.0.0.0" if scenario in
                                 {"custom_key", "old_template_remote"} else "127.0.0.1")
                if scenario == "custom_key":
                    self.assertEqual(secret, b"existing-key\n")
                    self.assertIn("tightening existing key file permissions", first.stdout)
                else:
                    self.assertRegex(secret.decode(), r"^[0-9a-f]{64}\n$")
                if "remote" in scenario:
                    self.assertEqual(data["AGENT_PLATFORM_WS_URL"],
                                     dotenv_values(stream=io.StringIO(initial))["AGENT_PLATFORM_WS_URL"])
                    self.assertIn("Preserved custom AGENT_PLATFORM_WS_URL", first.stdout)
                else:
                    self.assertEqual(data["AGENT_PLATFORM_WS_URL"],
                                     f"ws://127.0.0.1:{expected_port}/robot/reachy")
                if scenario != "localhost":
                    self.assertEqual(data["AGENT_TRANSPORT"], "http")
                self.env.pop("REACHY_SHARED_API_KEY_FILE", None)
                self.env.pop("REACHY_WS_PORT", None)
                self.run_setup()
                self.assertEqual(key.read_bytes(), secret)
                self.assertEqual(self.config.read_bytes(), config)
                names = re.findall(r"^([A-Z_]+)=", config.decode(), re.M)
                self.assertEqual(len(names), len(set(names)))

    def test_invalid_inputs(self):
        cases = [("REACHY_SHARED_API_KEY_FILE", str(self.home / ("bad" + char)), "shared key path")
                 for char in ("'", '"', "\\", "$", "`", "\n")]
        cases += [("REACHY_WS_PORT", port, "PORT") for port in ("0", "65536", "abc", "1.5")]
        cases += [("AGENT_PLATFORM_ROBOT_ID", robot, "AGENT_PLATFORM_ROBOT_ID")
                  for robot in ("with space", "a/b", "bad?", "\n")]
        for name, value, error in cases:
            with self.subTest(name=name, value=repr(value)):
                self.config.write_text("AGENT_TRANSPORT=http\n")
                self.env[name] = value
                result = self.run_setup(success=False)
                self.assertIn(error, result.stderr)
                self.assertEqual(self.config.read_text(), "AGENT_TRANSPORT=http\n")
                self.assertFalse((self.stack / ".reachy-api-key").exists())
                del self.env[name]
        for name in ("AGENT_PLATFORM_API_KEY_FILE", "AGENT_PLATFORM_WS_URL", "REACHY_WS_HOST",
                     "STACK_REACHY_WS_PORT", "AGENT_PLATFORM_ROBOT_ID"):
            with self.subTest(unbalanced=name):
                self.config.write_text(f'{name}="unbalanced\n')
                result = self.run_setup(success=False)
                self.assertIn(f"Invalid quoting in {name}", result.stderr)

    def test_dotenv_key_path_rejections(self):
        for raw in (r"/tmp/bad\path", "'/tmp/bad$path'", "'/tmp/bad`path'", "'/tmp/bad\"path'"):
            with self.subTest(raw=raw):
                self.config.write_text(f"AGENT_PLATFORM_API_KEY_FILE={raw}\n")
                result = self.run_setup(success=False)
                self.assertIn("Invalid shared key path", result.stderr)
                self.assertFalse((self.stack / ".reachy-api-key").exists())

    def test_changes_duplicates_and_robot_override(self):
        self.config.write_text("AGENT_PLATFORM_ROBOT_ID=old\n"
                               "AGENT_PLATFORM_WS_URL=ws://127.0.0.1:8770/robot/old\n"
                               "AGENT_PLATFORM_WS_URL=ws://127.0.0.1:8770/robot/old\n")
        self.env.update(AGENT_PLATFORM_ROBOT_ID="new-id", REACHY_WS_PORT="9999")
        result = self.run_setup()
        self.assertIn("Updated AGENT_PLATFORM_ROBOT_ID", result.stdout)
        self.assertIn("Updated AGENT_PLATFORM_WS_URL", result.stdout)
        self.assertIn("Removed duplicate AGENT_PLATFORM_WS_URL", result.stdout)
        self.assertIn("not in REACHY_ALLOWED_ROBOTS", result.stdout)
        self.assertEqual(dotenv_values(self.config)["AGENT_PLATFORM_WS_URL"],
                         "ws://127.0.0.1:9999/robot/new-id")

    def test_symlinked_env(self):
        target = self.home / "actual.env"
        target.write_text("AGENT_TRANSPORT=http\n")
        self.config.symlink_to(target)
        self.run_setup()
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertIn("AGENT_PLATFORM_API_KEY_FILE", dotenv_values(target))

    def test_key_permission_error(self):
        # Run the actual embedded program with only the filesystem permission failure injected.
        program = SETUP.read_text().split("<<'PY_CONFIG'\n")[1].split("\nPY_CONFIG")[0]
        injection = "from pathlib import Path\ndef denied(*args):\n    raise PermissionError()\nPath.chmod = denied\n"
        result = subprocess.run([sys.executable, "-c", injection + program, str(self.stack), str(TEMPLATE)],
                                env=self.env, cwd=self.home, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Permission denied accessing or securing shared key file", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
