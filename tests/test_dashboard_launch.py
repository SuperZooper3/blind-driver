"""Dashboard launch settings, configuration-file credentials, and scoped controls."""
import json
import os
from pathlib import Path
import tempfile
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer
import urllib.error
import urllib.request

from tools.ai_harness.__main__ import main
from tools.ai_harness.controls import RunController, new_run_command, restart_command
from tools.ai_harness.dashboard import handler_for
from tools.ai_harness.run import atomic_json


class DashboardLaunchTests(unittest.TestCase):
    def test_new_uses_defaults_and_repeat_preserves_old_overrides(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "old-run"
            directory.mkdir()
            config = Path(tmp) / ".env"
            atomic_json(directory / "manifest.json", {"provider": "cohere", "driver_model": "c4ai-aya-vision-32b",
                "navigator_model": "c4ai-aya-vision-32b", "sim_seconds": 12, "max_requests": 18,
                "max_tokens": 100000, "env_file": "/obsolete/.env", "memory_every": 3})
            for command, model, seconds, tokens, requests in (
                (new_run_command(directory.parent, config), "command-a-vision-07-2025", 60, 200000, 100),
                (restart_command(directory, config), "c4ai-aya-vision-32b", 12, 100000, 18)):
                with patch("sys.argv", ["ai_harness", *command[3:]]), patch("tools.ai_harness.__main__.run_episode") as run:
                    main()
                args = run.call_args.args[0]
                self.assertEqual(args.driver_model, model)
                self.assertEqual(args.navigator_model, model)
                self.assertEqual((args.sim_seconds, args.max_tokens, args.max_requests), (seconds, tokens, requests))
                self.assertEqual(args.env_file, str(config))

    def test_configuration_file_enables_launch_and_is_read_again(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            config = Path(tmp) / ".env"
            controller = RunController(Path(tmp) / "runs", config)
            self.assertFalse(controller.state(None)["can_new"])
            config.write_text("COHERE_API_KEY=fixture-secret\n")
            self.assertTrue(controller.state(None)["can_new"])
            self.assertNotIn("fixture-secret", json.dumps(controller.state(None)))
            self.assertNotIn("COHERE_API_KEY", os.environ)
            config.write_text("COHERE_API_KEY=\n")
            self.assertFalse(controller.state(None)["can_new"])
            with patch.dict(os.environ, {"COHERE_API_KEY": "fixture-env"}):
                self.assertTrue(controller.state(None)["can_new"])

    def test_empty_folder_launch_passes_file_path_and_no_key_in_command(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            root = Path(tmp) / "runs"
            config = Path(tmp) / ".env"
            config.write_text("COHERE_API_KEY=fixture-secret\n")
            controller = RunController(root, config)
            def launch(command, **kwargs):
                self.assertIn(str(config.resolve()), command)
                self.assertNotIn("fixture-secret", str(command))
                self.assertNotIn("COHERE_API_KEY", kwargs["env"])
                (root / "new-run").mkdir()
                atomic_json(root / "new-run/manifest.json", {"run_id": "new-run"})
                return SimpleNamespace(poll=lambda: None)
            with patch("tools.ai_harness.controls.subprocess.Popen", side_effect=launch):
                controller._complete("new", None)
            self.assertEqual(controller.error, "")
            self.assertEqual(controller.selected, root / "new-run")
            self.assertFalse(controller.busy)

    def test_new_run_endpoint_handles_empty_folder_and_rejects_stale_or_cross_origin(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            root = Path(tmp) / "runs"
            root.mkdir()
            config = Path(tmp) / ".env"
            config.write_text("COHERE_API_KEY=fixture-secret\n")
            controller = RunController(root, config)
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(root, True, controller))
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                with urllib.request.urlopen(base + "/state") as response:
                    state = json.load(response)
                rebound = urllib.request.Request(base + "/state", headers={"Host": "rebind.example"})
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(rebound)
                self.assertEqual(error.exception.code, 403)
                error.exception.close()
                self.assertTrue(state["waiting"])
                self.assertTrue(state["controls"]["can_new"])
                self.assertGreaterEqual(state["dashboard_prototype"], 6)
                self.assertNotIn("fixture-secret", json.dumps(state))
                for origin, run_id, expected in (("http://outside.invalid", "", 403), (base, "stale", 409), (base, "", 202)):
                    request = urllib.request.Request(base + "/control", data=json.dumps({"action": "new", "run_id": run_id}).encode(),
                        headers={"Origin": origin, "X-Control-Token": state["control_token"], "Content-Type": "application/json"})
                    if expected == 202:
                        with patch.object(controller, "_complete") as complete:
                            with urllib.request.urlopen(request) as response:
                                self.assertEqual(response.status, expected)
                        complete.assert_called_once_with("new", None)
                    else:
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            urllib.request.urlopen(request)
                        self.assertEqual(error.exception.code, expected)
                        error.exception.close()
                with self.assertRaisesRegex(ValueError, "cannot new"):
                    controller.request("new", None, "")
            finally:
                server.shutdown()
                server.server_close()
                worker.join()

    def test_serve_accepts_explicit_configuration_file(self):
        with patch("sys.argv", ["ai_harness", "serve", "/tmp/runs", "--latest", "--env-file", "/tmp/config.env"]), \
             patch("tools.ai_harness.dashboard.serve") as serve:
            main()
        serve.assert_called_once_with(Path("/tmp/runs"), True, 8766, "/tmp/config.env")


if __name__ == "__main__":
    unittest.main()
