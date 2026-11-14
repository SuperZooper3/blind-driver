"""Contract and recording checks that require no provider account or Godot window."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.ai_harness.agents import CohereAgent, validate_action
from tools.ai_harness.recap import export_metrics, summarize_runs
from tools.ai_harness.run import atomic_json, read_key


class HarnessContractTests(unittest.TestCase):
    def test_both_roles_have_keyboard_controls(self):
        for role, hold, tap in (("driver", ["W", "A"], ["H"]), ("navigator", ["B"], ["C"])):
            action = {"hold": hold, "tap": tap, "hold_sim_seconds": .6, "message": "test"}
            self.assertEqual(validate_action(action, role), action)
        for changes in ({"hold": ["W", "S"]}, {"hold": ["A", "D"]}, {"hold": ["M"]},
                        {"tap": ["H", "H"]}, {"hold_sim_seconds": float("nan")},
                        {"hold_sim_seconds": True}, {"message": "x"*241}, {"teleport": True}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_action({"hold": [], "tap": [], "hold_sim_seconds": .6, "message": "", **changes}, "driver")
        with self.assertRaises(ValueError):
            validate_action({"hold": ["B"], "tap": ["M"], "hold_sim_seconds": 1, "message": ""}, "navigator")

    def test_provider_receives_image_and_bounded_role_history(self):
        action = {"hold": ["W"], "tap": [], "hold_sim_seconds": 1, "message": "Driving"}
        response = {"message": {"content": [{"type": "text", "text": json.dumps(action)}]},
                    "usage": {"billed_units": {"input_tokens": 30, "output_tokens": 10}}}
        requests = []
        def fake_open(request, timeout):
            requests.append(json.loads(request.data))
            return io.BytesIO(json.dumps(response).encode())
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp)/"view.jpg"
            image.write_bytes(b"fake image")
            agent = CohereAgent("driver", "command-a-plus-05-2026", "fixture-key", "Driver prompt", 10, 512, 2)
            with patch("urllib.request.urlopen", fake_open):
                for _ in range(4):
                    answer, usage = agent.decide(image, {"frame": 3, "sim_time": 1, "held_keys": []}, [{"message": "Left"}])
            self.assertEqual(answer, action)
            self.assertEqual(usage["input_tokens"], 30)
            self.assertEqual(len(agent.history), 4)
            self.assertEqual(requests[-1]["thinking"], {"type": "disabled"})
            image_part = requests[0]["messages"][-1]["content"][-1]
            self.assertTrue(image_part["image_url"]["url"].startswith("data:image/jpeg;base64,"))
            self.assertNotIn("fixture-key", json.dumps(requests))
            self.assertNotIn("image_url", json.dumps(agent.history))

    def test_key_is_loaded_without_copying_it_into_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/".env"
            path.write_text("COHERE_API_KEY=fixture-only\n")
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(read_key(path), "fixture-only")
            atomic_json(Path(tmp)/"input.json", {"hold": ["W"]})
            self.assertEqual(json.loads((Path(tmp)/"input.json").read_text()), {"hold": ["W"]})

    def test_metrics_do_not_call_time_limit_a_failure_and_keep_speeds_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for speed in (5, 25):
                directory = root/str(speed)
                directory.mkdir()
                (directory/"manifest.json").write_text(json.dumps({"run_id": str(speed), "provider": "scripted", "label": "test",
                    "driver_model": "A", "navigator_model": "B", "speed": speed, "seed": 1, "course": "basic"}))
                (directory/"result.json").write_text(json.dumps({"reason": "time_limit", "requests": 2, "input_tokens": 0,
                    "output_tokens": 0, "terminated": False, "truncated": True, "valid_run": True, "errors": []}))
                frames = [{"active": True, "sim_time": t, "unix_time": t/(speed/100), "forward_progress_m": t*2,
                           "distance_m": t*3, "speed_kmh": 10, "capture_ms": 1, "fallback": t > 0} for t in range(3)]
                summary = export_metrics(directory, frames, [])
                self.assertFalse(summary["terminated"])
                self.assertEqual(summary["forward_progress_m"], 4)
                self.assertIsNone(summary["cost_usd"])
            summarize_runs(root)
            groups = json.loads((root/"benchmark.json").read_text())
            self.assertEqual({g["speed_percent"] for g in groups}, {5, 25})
            self.assertTrue((root/"runs.csv").exists())


if __name__ == "__main__":
    unittest.main()
