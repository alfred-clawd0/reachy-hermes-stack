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
        old = (Path(__file__).parent / "fixtures/env.example.9f4bc57").read_text()
        scenarios = {
            "default": TEMPLATE.read_text(),
            "custom_key": "AGENT_TRANSPORT=http\nREACHY_WS_HOST=0.0.0.0\n",
            "remote": "AGENT_TRANSPORT=http\nAGENT_PLATFORM_WS_URL=wss://gateway.example/voice\n",
            "remote_fragment": "AGENT_TRANSPORT=http\nAGENT_PLATFORM_WS_URL=wss://gateway.example/voice#fragment\n",
            "old_template_remote": old + "\nAGENT_PLATFORM_WS_URL=ws://gateway:8770/robot/reachy\n"
                                   "REACHY_WS_HOST=0.0.0.0\nREACHY_WS_PORT=9880\n",
            "localhost": "AGENT_PLATFORM_WS_URL=ws://localhost:8770/robot/reachy\n",
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
                if "remote" in scenario:
                    key.write_text("a" * 64 + "\n")  # Copy supplied by the gateway, never generated locally.
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
        cases += [("REACHY_WS_PORT", port, "PORT") for port in ("0", "65536", "abc", "1.5", "08770")]
        cases += [("AGENT_PLATFORM_ROBOT_ID", robot, "AGENT_PLATFORM_ROBOT_ID")
                  for robot in ("with space", "a/b", "bad?", "\n")]
        cases += [("REACHY_WS_HOST", host, "HOST")
                  for host in ("bad'host", "bad\nhost", "[not-ipv6]", "bad host", "-", ":::::")]
        cases += [("STACK_REACHY_ALLOWED_ROBOTS", ids, "ALLOWED_ROBOTS")
                  for ids in ("reachy\nother", "reachy,", "reachy, bad", "reachy,bad/id")]
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

    def test_migration_conflicts(self):
        key = self.home / "copied key"
        key.write_text("never-print-this-key")
        cases = [
            (f"REACHY_WS_API_KEY_FILE={self.home / 'old-key'}\nAGENT_PLATFORM_API_KEY_FILE='{key}'\n",
             [str(self.home / "old-key"), str(key), "AGENT_PLATFORM_API_KEY_FILE", "won"]),
            ("STACK_REACHY_WS_PORT=8770\nREACHY_WS_PORT=9880\n",
             ["REACHY_WS_PORT='9880' discarded", "STACK_REACHY_WS_PORT (stack .env)='8770' won"]),
            ("STACK_REACHY_WS_HOST=127.0.0.1\nREACHY_WS_HOST=0.0.0.0\n",
             ["REACHY_WS_HOST discarded", "STACK_REACHY_WS_HOST (stack .env) won"]),
        ]
        for initial, messages in cases:
            with self.subTest(initial=initial):
                self.config.write_text(initial)
                result = self.run_setup()
                for message in messages:
                    self.assertIn(message, result.stdout)
                self.assertIn("moved to the gateway block below; the stack .env no longer configures the gateway",
                              result.stdout)
                self.assertNotIn("never-print-this-key", result.stdout + result.stderr)

    def test_loopback_url_ownership(self):
        key = self.stack / ".reachy-api-key"
        key.write_text("copied-gateway-key")
        for local_port, robot, regenerate in (("18770", "reachy", False), ("8770", "other", False),
                                             ("8770", "reachy", True)):
            with self.subTest(port=local_port, robot=robot):
                url = f"ws://127.0.0.1:{local_port}/robot/{robot}"
                self.config.write_text(f"STACK_REACHY_WS_PORT=8770\nAGENT_PLATFORM_ROBOT_ID=reachy\n"
                                       f"AGENT_PLATFORM_WS_URL={url}\n")
                self.env["REACHY_WS_PORT"] = "9880"
                first = self.run_setup()
                expected = "ws://127.0.0.1:9880/robot/reachy" if regenerate else url
                self.assertEqual(dotenv_values(self.config)["AGENT_PLATFORM_WS_URL"], expected)
                self.assertEqual("Preserved custom AGENT_PLATFORM_WS_URL" in first.stdout, not regenerate)
                self.env.pop("REACHY_WS_PORT")
                self.run_setup()
                self.assertEqual(dotenv_values(self.config)["AGENT_PLATFORM_WS_URL"], expected)
                self.assertEqual(key.read_text(), "copied-gateway-key")

    def test_missing_remote_key(self):
        for url in ("ws://gateway:8770/robot/reachy", "ws://127.0.0.1:18770/robot/reachy"):
            with self.subTest(url=url):
                key = self.home / "copied" / "gateway-key"
                self.config.write_text(f"AGENT_PLATFORM_WS_URL={url}\nAGENT_PLATFORM_API_KEY_FILE={key}\n")
                initial = self.config.read_bytes()
                result = self.run_setup(success=False)
                self.assertIn(f"copy the gateway's key file to {key} (mode 600) and rerun", result.stderr)
                self.assertFalse(key.exists())
                self.assertEqual(self.config.read_bytes(), initial)
                key.parent.mkdir(exist_ok=True)
                key.write_text("gateway-key-copy")
                result = self.run_setup()
                self.assertEqual("For the gateway machine, not this one" in result.stdout, "gateway:" in url)
                self.assertEqual(key.read_text(), "gateway-key-copy")
                key.unlink()

    def test_valid_hosts(self):
        for host in ("robot.local", "::1", "[::1]"):
            with self.subTest(host=host):
                self.config.write_text("AGENT_TRANSPORT=http\n")
                self.env.update(REACHY_WS_HOST=host, STACK_REACHY_ALLOWED_ROBOTS="reachy,robot-2")
                result = self.run_setup()
                data = dotenv_values(self.config)
                gateway = dotenv_values(stream=io.StringIO(result.stdout.split(
                    "--- gateway settings ---\n")[1].split("--- end gateway settings ---")[0]))
                self.assertEqual(data["STACK_REACHY_WS_HOST"], host.strip("[]"))
                self.assertEqual(gateway["REACHY_WS_HOST"], host.strip("[]"))
                self.assertEqual(data["STACK_REACHY_ALLOWED_ROBOTS"], "reachy,robot-2")

    def test_invalid_filesystem_targets(self):
        for kind in ("dangling_env", "key_directory"):
            with self.subTest(kind=kind):
                if kind == "dangling_env":
                    self.config.symlink_to(self.home / "missing-parent" / "target.env")
                    result = self.run_setup(success=False)
                    self.assertIn("Dangling .env symlink", result.stderr)
                    self.assertTrue(self.config.is_symlink())
                    self.config.unlink()
                else:
                    key = self.stack / ".reachy-api-key"
                    key.mkdir()
                    mode = key.stat().st_mode
                    result = self.run_setup(success=False)
                    self.assertIn("Shared key path must be a regular file", result.stderr)
                    self.assertEqual(key.stat().st_mode, mode)
                self.assertFalse(self.config.exists())

    def test_atomic_write_failure_cleanup(self):
        self.config.write_text("AGENT_TRANSPORT=http\n")
        program = SETUP.read_text().split("<<'PY_CONFIG'\n")[1].split("\nPY_CONFIG")[0]
        injection = """import tempfile
original = tempfile.NamedTemporaryFile
class FailedWrite:
    def __init__(self, *args, **kwargs):
        self.file = original(*args, **kwargs)
        self.name = self.file.name
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.file.close()
    def write(self, value):
        raise OSError('simulated disk full')
tempfile.NamedTemporaryFile = FailedWrite
"""
        result = subprocess.run([sys.executable, "-c", injection + program, str(self.stack), str(TEMPLATE)],
                                env=self.env, cwd=self.home, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot configure Reachy stack: simulated disk full", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.config.read_text(), "AGENT_TRANSPORT=http\n")
        self.assertEqual({path.name for path in self.stack.iterdir()}, {".env"})

    def test_legacy_equivalent_key_paths(self):
        for value in (".reachy-api-key", "~/stack with spaces/.reachy-api-key"):
            with self.subTest(path=value):
                self.config.write_text(f"REACHY_WS_API_KEY_FILE='{value}'\n")
                result = self.run_setup()
                self.assertNotIn("Conflict:", result.stdout)
                self.assertEqual(dotenv_values(self.config)["AGENT_PLATFORM_API_KEY_FILE"],
                                 str(self.stack / ".reachy-api-key"))

    def test_kept_loopback_port_notice(self):
        key = self.stack / ".reachy-api-key"
        key.write_text("copied-key")
        self.config.write_text("STACK_REACHY_WS_PORT=9000\n"
                               "AGENT_PLATFORM_WS_URL=ws://127.0.0.1:8770/robot/reachy\n")
        result = self.run_setup()
        self.assertIn("voice URL port 8770 != gateway port 9000 (expected only for an SSH tunnel)", result.stdout)
        self.assertNotIn("For the gateway machine, not this one", result.stdout)
        self.assertEqual(dotenv_values(self.config)["AGENT_PLATFORM_WS_URL"],
                         "ws://127.0.0.1:8770/robot/reachy")

    def test_key_path_errors(self):
        for kind in ("empty_remote", "parent_file"):
            with self.subTest(kind=kind):
                key = self.home / "invalid-key"
                key.write_text("")
                path = key if kind == "empty_remote" else key / "child"
                self.config.write_text(f"AGENT_PLATFORM_API_KEY_FILE={path}\n"
                                       "AGENT_PLATFORM_WS_URL=ws://gateway:8770/robot/reachy\n")
                result = self.run_setup(success=False)
                message = "re-copy the gateway's key" if kind == "empty_remote" else "Shared key path parent is a regular file"
                self.assertIn(message, result.stderr)
                self.assertEqual(key.read_text(), "")

    def test_failed_config_replace_removes_new_key(self):
        self.config.write_text("AGENT_TRANSPORT=http\n")
        program = SETUP.read_text().split("<<'PY_CONFIG'\n")[1].split("\nPY_CONFIG")[0]
        injection = "import os\ndef denied(*args):\n    raise PermissionError()\nos.replace = denied\n"
        result = subprocess.run([sys.executable, "-c", injection + program, str(self.stack), str(TEMPLATE)],
                                env=self.env, cwd=self.home, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot write stack configuration", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.config.read_text(), "AGENT_TRANSPORT=http\n")
        self.assertEqual({path.name for path in self.stack.iterdir()}, {".env"})

    def test_key_permission_error(self):
        # Run the actual embedded program with only the filesystem permission failure injected.
        program = SETUP.read_text().split("<<'PY_CONFIG'\n")[1].split("\nPY_CONFIG")[0]
        injection = "from pathlib import Path\noriginal = Path.chmod\ndef denied(path, *args):\n    if path.name == '.reachy-api-key':\n        raise PermissionError()\n    return original(path, *args)\nPath.chmod = denied\n"
        result = subprocess.run([sys.executable, "-c", injection + program, str(self.stack), str(TEMPLATE)],
                                env=self.env, cwd=self.home, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Permission denied accessing or securing shared key file", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
