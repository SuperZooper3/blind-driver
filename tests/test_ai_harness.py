"""Contract and recording checks that require no provider account or Godot window."""
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from threading import Thread
from unittest.mock import patch

from tools.ai_harness.agents import CohereAgent, validate_action
from tools.ai_harness.recap import export_metrics, summarize_runs, simulation_timeline
from tools.ai_harness.run import atomic_json, read_key
from tools.ai_harness.monitor import ConsoleMonitor, EventTail


class HarnessContractTests(unittest.TestCase):
    def test_both_roles_have_keyboard_controls(self):
        for role, hold, tap in (("driver", ["W", "A"], ["H"]), ("navigator", ["B"], ["C"])):
            action = {"hold": hold, "tap": tap, "message": "test"}
            self.assertEqual(validate_action(action, role), action)
        for changes in ({"hold": ["W", "S"]}, {"hold": ["A", "D"]}, {"hold": ["M"]},
                        {"tap": ["H", "H"]}, {"hold_sim_seconds": float("nan")},
                        {"hold_sim_seconds": True}, {"message": "x"*241}, {"teleport": True}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_action({"hold": [], "tap": [], "message": "", **changes}, "driver")
        with self.assertRaises(ValueError):
            validate_action({"hold": ["B"], "tap": ["M"], "message": ""}, "navigator")

    def test_provider_receives_image_and_bounded_role_history(self):
        action = {"hold": ["W"], "tap": [], "message": "Driving"}
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
            self.assertEqual(len(agent.history), 2)
            self.assertEqual(len(requests[-1]["messages"]), 1)
            self.assertEqual(requests[-1]["thinking"], {"type": "disabled"})
            image_part = next(p for p in requests[0]["messages"][-1]["content"] if p["type"] == "image_url")
            self.assertTrue(image_part["image_url"]["url"].startswith("data:image/jpeg;base64,"))
            self.assertNotIn("fixture-key", json.dumps(requests))
            self.assertNotIn("image_url", json.dumps(agent.history))

    def test_cleanup_preserves_outputs_and_failed_exports_keep_frames(self):
        from tools.ai_harness.cleanup import cleanup_frames
        from tools.ai_harness.recap import build_recap
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/"recorded-run"
            root.mkdir()
            (root/"manifest.json").write_text(json.dumps({"run_id":root.name}))
            for role in ("driver", "navigator"):
                (root/role/"frames").mkdir(parents=True)
                (root/role/"frames/0000000.jpg").write_bytes(b"raw frame")
                (root/role/"frames.jsonl").write_text(json.dumps({"image":"frames/0000000.jpg"})+"\n")
            with self.assertRaises(ValueError):
                cleanup_frames(root)
            self.assertTrue((root/"driver/frames/0000000.jpg").exists())
            for name in ("result.json", "summary.json", "recap.jpg", "recap.mp4"):
                (root/name).write_bytes(b"retained output")
            with patch("tools.ai_harness.cleanup.subprocess.run", return_value=SimpleNamespace(stdout='{"streams":[{"width":1920,"height":1080}],"format":{"duration":"1.0"}}')):
                result = cleanup_frames(root)
            self.assertEqual(result["files_removed"], 2)
            self.assertFalse((root/"driver/frames").exists())
            self.assertTrue((root/"driver/frames.jsonl").exists())
            with self.assertRaisesRegex(ValueError, "saved recap is unchanged"):
                build_recap(root)
            self.assertEqual((root/"recap.mp4").read_bytes(), b"retained output")

    def test_score_penalties_use_game_seconds_and_separate_failure(self):
        from tools.ai_harness.scoring import score_frame
        row = {"forward_progress_m": 300, "impact_events": 2, "offroad_sim_seconds": 5,
               "part_health": [1, 0], "run_state": "driving"}
        score = score_frame(row)
        self.assertEqual(score["score"], 190)
        self.assertEqual(score["penalty_failure"], 0)
        self.assertEqual(score_frame({**row, "run_state": "game_over"})["score"], 90)
        self.assertEqual(score_frame({**row, "speed_percent": 5}), score)

    def test_recaps_overlap_other_actions_and_do_not_mutate_provider_history(self):
        from concurrent.futures import ThreadPoolExecutor
        from threading import Event
        from tools.ai_harness.memory import WorkingMemory, RateBudget
        memory = WorkingMemory(1)
        memory.record({"sim_time": 1}, [{"message": "Tree ahead"}],
                      {"hold": [], "tap": [], "message": "Braking", "notes": "Speed zero; check obstruction"}, 1.1)
        entered, release = Event(), Event()
        class Agent:
            def summarize(self, previous, turns):
                entered.set()
                release.wait(3)
                return turns[0]["action"]["notes"], {"input_tokens": 8}
        with ThreadPoolExecutor(max_workers=2) as pool:
            memory.start(pool, Agent(), 4)
            self.assertTrue(entered.wait(1))
            other_action = pool.submit(lambda: "other agent action completed")
            self.assertEqual(other_action.result(timeout=1), "other agent action completed")
            self.assertEqual(memory.recap["through_turn"], 0)
            memory.turns[0]["action"]["notes"] = "changed after dispatch"
            release.set()
            recap, usage = memory.finish()
            self.assertEqual(recap, {"text": "Speed zero; check obstruction", "through_turn": 1})
            self.assertEqual(usage["input_tokens"], 8)
        clock = [0]
        budget = RateBudget(60, lambda: clock[0])
        self.assertTrue(budget.take(2))
        self.assertFalse(budget.take())
        clock[0] = 1
        self.assertTrue(budget.take())
        clock[0] = 3
        self.assertTrue(budget.take(2))

    def test_summary_is_text_only_and_current_actions_keep_exactly_one_image(self):
        requests = []
        action = {"hold": [], "tap": [], "message": "Stopped", "notes": "Check the road"}
        def fake_open(request, timeout):
            body = json.loads(request.data)
            requests.append(body)
            content = json.dumps(action) if isinstance(body["messages"][-1]["content"], list) else "Observed a stop."
            return io.BytesIO(json.dumps({"message": {"content": [{"type": "text", "text": content}]}}).encode())
        with tempfile.TemporaryDirectory() as tmp, patch("urllib.request.urlopen", fake_open):
            image = Path(tmp)/"current.jpg"
            image.write_bytes(b"current-only")
            agent = CohereAgent("driver", "c4ai-aya-vision-32b", "fixture-key", "Drive", 10, 512, 32)
            agent.decide(image, {}, [{"message": "Tree ahead"}])
            original = json.dumps(agent.history)
            text, _ = agent.summarize({}, [{"turn": 1, "action": action}])
            self.assertEqual(original, json.dumps(agent.history))
            agent.decide(image, {"working_memory": {"text": text, "through_turn": 1},
                "coordination": {"recent_dialogue": [{"role": "navigator", "message": "Tree ahead"}]}}, [])
        self.assertNotIn("image_url", json.dumps(requests[1]))
        image_count = sum(p.get("type") == "image_url" for m in requests[-1]["messages"]
                          if isinstance(m["content"], list) for p in m["content"])
        self.assertEqual(image_count, 1)
        self.assertIn("Tree ahead", json.dumps(requests[-1]))
        self.assertIn("Observed a stop", json.dumps(requests[-1]))

    def test_key_is_loaded_without_copying_it_into_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/".env"
            path.write_text("COHERE_API_KEY=fixture-only\n")
            with patch.dict("os.environ", {}, clear=True):
                self.assertEqual(read_key(path), "fixture-only")
            atomic_json(Path(tmp)/"input.json", {"hold": ["W"]})
            self.assertEqual(json.loads((Path(tmp)/"input.json").read_text()), {"hold": ["W"]})

    def test_aya_uses_image_api_without_command_only_options(self):
        action = {"hold": [], "tap": ["M"], "message": "Checking map"}
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
            "action": {"hold": [], "tap": ["M"], "message": "Turn left"}})
        self.assertNotIn("Turn left", output.getvalue())
        monitor.event({"event": "message", "role": "navigator", "to": "driver", "unix_time": 103.1,
            "sim_time": .775, "message": "Turn left\x1b[2J\nnow"})
        text = output.getvalue()
        self.assertIn("NAVIGATOR → DRIVER: Turn left", text)
        self.assertIn("awaiting game acknowledgment", text)
        self.assertIn("until next instruction", text)
        self.assertNotIn("\x1b", text)

    def test_cli_defaults_to_command_a_and_normal_motion(self):
        from tools.ai_harness.__main__ import main
        with patch("sys.argv", ["ai_harness", "run", "--provider", "cohere"]), \
             patch("tools.ai_harness.__main__.run_episode") as run:
            main()
            args = run.call_args.args[0]
            self.assertEqual(args.driver_model, "command-a-plus-05-2026")
            self.assertEqual(args.navigator_model, "command-a-plus-05-2026")
            self.assertEqual(args.memory_every, 0)
            self.assertEqual(args.sim_seconds, 60)
            self.assertEqual(args.max_requests, 200)
            self.assertEqual(args.max_tokens, 200000)
            self.assertEqual(args.speed, 5)
            self.assertEqual(args.history_turns, 2)
            self.assertEqual(args.decision_interval_sim, .6)
            self.assertEqual(args.thinking_tokens, 512)
            self.assertGreaterEqual(args.max_output_tokens, args.thinking_tokens + 1024)
            self.assertIsNone(args.review_speed)

    def test_local_viewer_exposes_only_spectator_data_and_frame_paths(self):
        from tools.ai_harness.dashboard import handler_for
        from tools.ai_harness.controls import RunController
        import time
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'manifest.json').write_text(json.dumps({'run_id':'fixture', 'secret':'private-fixture'}))
            (root/'driver/frames').mkdir(parents=True)
            (root/'driver/frames/1.jpg').write_bytes(b'jpeg-fixture')
            atomic_json(root/'driver/latest.json', {'image':'frames/1.jpg','held':['W'], 'secret':'private-fixture'})
            controller = RunController()
            server = ThreadingHTTPServer(('127.0.0.1',0),handler_for(root,False,controller))
            worker = Thread(target=server.serve_forever,daemon=True)
            worker.start()
            base = f'http://127.0.0.1:{server.server_port}'
            try:
                with urllib.request.urlopen(base+'/state') as response:
                    body=response.read().decode()
                    self.assertNotIn('private-fixture',body)
                    self.assertEqual(json.loads(body)['seats']['driver']['held'],['W'])
                    token = json.loads(body)['control_token']
                atomic_json(root/'runner.json', {'phase':'running','heartbeat':time.time()})
                for origin, run_id, expected in (('http://outside.invalid','fixture',403),(base,'wrong-run',409),(base,'fixture',202)):
                    request = urllib.request.Request(base+'/control',data=json.dumps({'action':'stop','run_id':run_id}).encode(),
                        headers={'Origin':origin,'X-Control-Token':token,'Content-Type':'application/json'})
                    if expected == 202:
                        with patch.object(controller, '_complete'):
                            with urllib.request.urlopen(request) as response:
                                self.assertEqual(response.status,202)
                        self.assertEqual(json.loads((root/'control.json').read_text())['run_id'],'fixture')
                    else:
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            urllib.request.urlopen(request)
                        self.assertEqual(error.exception.code,expected)
                        error.exception.close()
                with urllib.request.urlopen(base+'/image/driver') as response:
                    self.assertEqual(response.read(),b'jpeg-fixture')
                atomic_json(root/'driver/latest.json', {'image':'../manifest.json'})
                for route in ('/manifest.json','/image/driver','/../manifest.json'):
                    with self.subTest(route=route), self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(base+route)
                    self.assertEqual(error.exception.code,404)
                    error.exception.close()
            finally:
                server.shutdown()
                server.server_close()
                worker.join()

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
