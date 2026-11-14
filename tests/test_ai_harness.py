"""Contract and recording checks that require no provider account or Godot window."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.ai_harness.agents import CohereAgent, validate_action
from tools.ai_harness.recap import export_metrics, summarize_runs, simulation_timeline
from tools.ai_harness.run import atomic_json, read_key
from tools.ai_harness.monitor import ConsoleMonitor, EventTail


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

    def test_aya_uses_image_api_without_command_only_options(self):
        action = {"hold": [], "tap": ["M"], "hold_sim_seconds": 1, "message": "Checking map"}
        response = {"message": {"content": [{"type": "text", "text": json.dumps(action)}]}}
        def fake_open(request, timeout):
            body = json.loads(request.data)
            self.assertEqual(body["model"], "c4ai-aya-vision-32b")
            self.assertNotIn("thinking", body)
            self.assertNotIn("response_format", body)
            content = body["messages"][-1]["content"]
            self.assertEqual(content[1]["type"], "image_url")
            self.assertIn("Navigate", content[0]["text"])
            self.assertIn("Return ONLY the JSON", content[-1]["text"])
            return io.BytesIO(json.dumps(response).encode())
        with tempfile.TemporaryDirectory() as tmp, patch("urllib.request.urlopen", fake_open):
            image = Path(tmp)/"view.jpg"
            image.write_bytes(b"image")
            agent = CohereAgent("navigator", "c4ai-aya-vision-32b", "fixture-key", "Navigate", 10, 512, 2)
            self.assertEqual(agent.decide(image, {}, [])[0], action)

    def test_normal_video_uses_simulation_clock_including_stalls(self):
        for speed in (5, 25, 100):
            rows = [{"sim_time": t, "unix_time": 100 + t/(speed/100)} for t in (0, 1, 2)]
            duration, mapping = simulation_timeline(rows)
            self.assertEqual(duration, 2)
            self.assertAlmostEqual(mapping(.5), 100 + .5/(speed/100))
        duration, mapping = simulation_timeline([
            {"sim_time": 0, "unix_time": 100}, {"sim_time": 1, "unix_time": 104},
            {"sim_time": 1, "unix_time": 109}, {"sim_time": 2, "unix_time": 113}])
        self.assertEqual(duration, 2)
        self.assertEqual(mapping(1.5), 111)

    def test_live_terminal_tails_partial_writes_and_separates_response_from_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"events.jsonl"
            tail = EventTail(path)
            self.assertEqual(tail.read(), [])
            path.write_bytes(b'{"event":"message"')
            self.assertEqual(tail.read(), [])
            with path.open("ab") as stream:
                stream.write(b'}\n{"event":"request"}\n')
            self.assertEqual([e["event"] for e in tail.read()], ["message", "request"])
            self.assertEqual(tail.read(), [])
        output = io.StringIO()
        monitor = ConsoleMonitor(Path("fixture"), {"created_unix": 100, "speed": 25, "sim_seconds": 30,
            "provider": "cohere", "driver_model": "Aya", "navigator_model": "Aya"}, output)
        monitor.event({"event": "request", "role": "navigator", "unix_time": 101, "request_id": 1,
            "observation": {"frame": 2, "sim_time": .25}})
        monitor.event({"event": "response", "role": "navigator", "unix_time": 103, "latency_seconds": 2,
            "action": {"hold": [], "tap": ["M"], "hold_sim_seconds": 1, "message": "Turn left"}})
        self.assertNotIn("Turn left", output.getvalue())
        monitor.event({"event": "message", "role": "navigator", "to": "driver", "unix_time": 103.1,
            "sim_time": .775, "message": "Turn left\x1b[2J\nnow"})
        text = output.getvalue()
        self.assertIn("NAVIGATOR → DRIVER: Turn left", text)
        self.assertIn("awaiting game acknowledgment", text)
        self.assertNotIn("\x1b", text)

    def test_cli_defaults_to_aya_and_normal_motion(self):
        from tools.ai_harness.__main__ import main
        with patch("sys.argv", ["ai_harness", "run", "--provider", "cohere"]), \
             patch("tools.ai_harness.__main__.run_episode") as run:
            main()
            args = run.call_args.args[0]
            self.assertEqual(args.driver_model, "c4ai-aya-vision-32b")
            self.assertEqual(args.navigator_model, "c4ai-aya-vision-32b")
            self.assertEqual(args.speed, 25)
            self.assertIsNone(args.review_speed)

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
                # Stop/cleanup overhead must not make a 100% simulation appear
                # slower. Use the game's own start/end timestamps for its clock.
                (directory/"driver").mkdir()
                (directory/"driver"/"input_events.jsonl").write_text(
                    json.dumps({"event":"started", "unix_time":10})+"\n"+
                    json.dumps({"event":"finished", "unix_time":10+2/(speed/100)})+"\n")
                summary = export_metrics(directory, frames, [{"event":"episode_started","unix_time":9},
                    {"event":"episode_finished","unix_time":20+2/(speed/100)}])
                self.assertAlmostEqual(summary["effective_speed_percent"], speed)
            summarize_runs(root)
            groups = json.loads((root/"benchmark.json").read_text())
            self.assertEqual({g["speed_percent"] for g in groups}, {5, 25})
            self.assertTrue((root/"runs.csv").exists())


if __name__ == "__main__":
    unittest.main()
