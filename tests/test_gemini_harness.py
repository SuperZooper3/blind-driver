"""Gemini protocol, one-way control, quota and dashboard regressions."""
from copy import deepcopy
from concurrent.futures import Future
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from test_concurrent_agents import Fixture, action
from tools.ai_harness.__main__ import main
from tools.ai_harness.agents import InvalidModelResponse, validate_action
from tools.ai_harness.controls import RunController, new_run_command, restart_command
from tools.ai_harness.gemini import (CONTROLS, DRIVER_MODEL, NAVIGATOR_MODEL, GeminiAPIError,
    GeminiClient, GeminiDecisionAgent, GeminiNavigatorAgent, api_error, gemini_prompt, token_usage)
from tools.ai_harness.memory import InputTokenWindow
from tools.ai_harness.run import atomic_json, read_key


def decision(choice="accelerate_left"):
    return {"answers": {"controls": {"type": "choice", "choice": choice, "confidence": .9},
                        "headlights": {"type": "choice", "choice": "unchanged", "confidence": .99}},
            "usage": {"total_input_tokens": 2000, "total_output_tokens": 0, "total_tokens": 2000}}


class GeminiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.image = Path(self.temp.name) / "frame.jpg"
        self.image.write_bytes(b"current-frame-fixture")

    def agent(self, cls, role):
        return cls(role, DRIVER_MODEL if role == "driver" else NAVIGATOR_MODEL, "fixture-secret",
                   gemini_prompt(role, 5, "basic"), 60, 2048, 2)

    def test_decisions_send_current_blurred_image_and_return_only_silent_controls(self):
        agent = self.agent(GeminiDecisionAgent, "driver")
        observed = {"sim_time": 3, "held_keys": ["W"], "working_memory": {"text": "unused"},
                    "timing": {"since_previous_observation_sim_seconds": .2}}
        with patch.object(agent.client, "post", return_value=decision()) as post:
            result, usage = agent.decide(self.image, observed, [{"message": "Turn left"}])
        self.assertEqual(result, {"hold": ["W", "A"], "tap": [], "message": ""})
        self.assertEqual(usage["output_tokens"], 0)
        self.assertFalse(agent.supports_memory)
        endpoint, body = post.call_args.args
        self.assertEqual(endpoint, "decisions")
        self.assertEqual(body["input"][1]["mime_type"], "image/jpeg")
        self.assertNotIn("working_memory", body["input"][0]["text"])
        self.assertIn("since_previous_observation", body["input"][0]["text"])
        self.assertNotIn("fixture-secret", json.dumps(body))
        for keys in CONTROLS.values():
            validate_action({"hold": keys, "tap": [], "message": ""}, "driver")

    def test_unknown_choice_or_missing_confidence_is_rejected_with_usage(self):
        agent = self.agent(GeminiDecisionAgent, "driver")
        for reply in (decision("invented"), {"answers": {}}, decision()):
            if reply.get("answers", {}).get("controls", {}).get("choice") == "accelerate_left":
                reply["answers"]["controls"]["confidence"] = float("nan")
            with patch.object(agent.client, "post", return_value=reply), self.assertRaises(InvalidModelResponse):
                agent.decide(self.image, {}, [])

    def test_navigator_schema_history_and_thinking_token_accounting(self):
        agent = self.agent(GeminiNavigatorAgent, "navigator")
        reply = {"candidates": [{"finishReason": "STOP", "content": {"parts": [
            {"text": "not user-visible", "thought": True},
            {"text": json.dumps({"hold": [], "tap": [], "message": "Start with W; release A/D.", "notes": "Clear."})}]} }],
            "usageMetadata": {"promptTokenCount": 200, "candidatesTokenCount": 40,
                              "thoughtsTokenCount": 20, "totalTokenCount": 260}}
        with patch.object(agent.client, "post", return_value=reply) as post:
            for _ in range(4):
                _, usage = agent.decide(self.image, {"sim_time": 1, "coordination": {}, "working_memory": {}}, [])
        self.assertEqual(usage["output_tokens"], 60)
        self.assertEqual(len(agent.history), 2)
        self.assertNotIn("inlineData", json.dumps(agent.history))
        body = post.call_args.args[1]
        self.assertEqual(body["generationConfig"]["thinkingConfig"], {"thinkingLevel": "low"})
        self.assertEqual(body["generationConfig"]["responseJsonSchema"]["properties"]["hold"]["items"]["enum"], ["B"])
        reply["candidates"][0]["finishReason"] = "MAX_TOKENS"
        with patch.object(agent.client, "post", return_value=reply), self.assertRaises(InvalidModelResponse):
            agent.decide(self.image, {}, [])
        self.assertFalse(token_usage({})["known"])

    def test_http_errors_expose_only_safe_quota_fields_and_honor_retry(self):
        payload = {"error": {"message": "echo fixture-secret", "details": [
            {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "75.5s"},
            {"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [
                {"quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                 "quotaId": "RequestsPerDay", "quotaValue": "0", "consumer": "secret-project"}]}]}}
        err = urllib.error.HTTPError("https://example.invalid", 429, "ignored", {}, io.BytesIO(json.dumps(payload).encode()))
        with patch("urllib.request.urlopen", side_effect=err), self.assertRaises(GeminiAPIError) as raised:
            GeminiClient("fixture-secret", 5).post("decisions", {})
        error = raised.exception
        self.assertEqual(error.retry_after, 75.5)
        self.assertTrue(error.permanent)
        self.assertNotIn("fixture-secret", str(error))
        self.assertNotIn("secret-project", json.dumps(error.quotas))
        self.assertEqual(api_error(429, {}, {}).retry_after, 60)

    def test_input_token_reservations_reconcile_and_expire(self):
        now = [0.0]
        budget = InputTokenWindow(10000, lambda: now[0])
        budget.reserve(1)
        self.assertFalse(budget.ready())
        budget.settle(1, {"input_tokens": 4000})
        self.assertTrue(budget.ready())
        budget.reserve(2)
        self.assertFalse(budget.ready())
        budget.settle(2, {"known": False})
        now[0] = 60
        self.assertTrue(budget.ready())

    def started_fixture(self, **settings):
        f = Fixture(provider="gemini", driver_rpm=180, navigator_rpm=5, speed=5, **settings)
        f.tick()
        self.assertEqual(f.coordinator.requests, 1)  # don't spend driver quota waiting for first advice
        f.executor.complete(0, (action("Start W, straight ahead"), {"input_tokens": 1000}))
        f.tick(); f.tick()
        self.assertEqual(f.coordinator.requests, 2)
        return f

    def test_fast_silent_driver_loops_independently_with_timing(self):
        f = self.started_fixture()
        f.executor.complete(1, (action(hold=["W"]), {"input_tokens": 2000}))
        f.tick(); f.tick(seconds=4)
        self.assertEqual(f.coordinator.requests, 3)
        observed = f.coordinator.seats["driver"].context["observation"]
        self.assertGreater(observed["timing"]["since_previous_observation_sim_seconds"], 0)
        self.assertGreater(observed["timing"]["previous_request_latency_real_seconds"], 0)
        self.assertFalse(any(e["event"] == "message" and e["role"] == "driver" for e in f.events))
        started = f.coordinator.held_since["driver"]["W"]
        f.executor.complete(2, (action(hold=["W"]), {"input_tokens": 2000}))
        f.tick(); f.tick(seconds=4)
        self.assertEqual(f.coordinator.held_since["driver"]["W"], started)
        later = f.coordinator.seats["driver"].context["observation"]
        self.assertGreater(later["timing"]["held_for_sim_seconds"]["W"],
                           observed["timing"]["held_for_sim_seconds"]["W"])

    def test_429_releases_controls_and_waits_without_blocking_navigator(self):
        f = self.started_fixture()
        f.latest["driver"]["held"] = ["W", "A"]
        f.executor.complete(1, error=GeminiAPIError(429, 60))
        f.tick()
        self.assertEqual(f.commands[-1][2]["hold"], [])
        f.tick(seconds=15)
        self.assertEqual(f.coordinator.requests, 3)  # navigator only
        self.assertEqual(f.events[-1]["role"], "navigator")
        f.tick(seconds=46)
        self.assertEqual(f.coordinator.requests, 4)
        self.assertEqual(f.events[-1]["role"], "driver")

    def test_quota_window_releases_driver_and_does_not_repeat_release(self):
        f = self.started_fixture(driver_tpm=8000)
        f.executor.complete(1, (action(hold=["W"]), {"input_tokens": 7900}))
        f.tick(); f.tick()
        releases = [e for e in f.events if e["event"] == "controls_released"]
        self.assertEqual(len(releases), 1)
        self.assertEqual(releases[0]["reason"], "input_token_cooldown")
        f.tick(); f.tick()
        self.assertEqual(len([e for e in f.events if e["event"] == "controls_released"]), 1)

    def test_driver_speech_rejected_and_decision_recaps_disabled(self):
        f = self.started_fixture()
        f.executor.complete(1, (action("I am talking"), {}))
        f.tick(); f.tick()
        self.assertFalse(any(e["event"] == "message" and e["role"] == "driver" for e in f.events))
        agents = {"driver": self.agent(GeminiDecisionAgent, "driver"), "navigator": self.agent(GeminiNavigatorAgent, "navigator")}
        f = Fixture(provider="gemini", agents=agents, memory_every=1)
        self.assertEqual(f.coordinator.memories["driver"].every, 0)
        self.assertEqual(f.coordinator.memories["navigator"].every, 1)

    def test_recap_quota_error_also_cools_down_action_requests(self):
        f = self.started_fixture()
        future = Future()
        future.set_exception(GeminiAPIError(429, 75))
        f.coordinator.memories["navigator"].pending = {"future": future, "request_id": 99,
            "through_turn": 1, "started": 0}
        f.coordinator.collect_memory("navigator", f.latest)
        self.assertFalse(f.coordinator.role_ready("navigator"))
        self.assertGreaterEqual(f.coordinator.role_next["navigator"], f.now + 75)
        self.assertEqual(f.events[-1]["http_status"], 429)

    def test_permission_error_stops_without_retrying_or_falling_back(self):
        f = self.started_fixture()
        f.executor.complete(1, error=GeminiAPIError(403, permanent=True))
        self.assertEqual(f.tick(), "provider_errors")
        self.assertEqual(f.coordinator.requests, 2)

    def test_separate_key_cli_defaults_and_repeat_preserve_gemini(self):
        root = Path(self.temp.name)
        config = root / ".env"
        config.write_text("GEMINI_API_KEY=fixture-secret\n")
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(read_key(config, "gemini"), "fixture-secret")
            self.assertTrue(RunController(root, config, "gemini").state(None)["can_new"])
            self.assertFalse(RunController(root, config).state(None)["can_new"])
        command = new_run_command(root, config, "gemini")
        with patch("sys.argv", ["harness", *command[3:]]), patch("tools.ai_harness.__main__.run_episode") as run:
            main()
        args = run.call_args.args[0]
        self.assertEqual((args.driver_model, args.navigator_model), (DRIVER_MODEL, NAVIGATOR_MODEL))
        self.assertEqual((args.speed, args.memory_every), (5, 0))
        self.assertEqual(args.driver_tpm, 40000)
        atomic_json(root / "manifest.json", vars(args))
        repeated = restart_command(root, config)
        self.assertIn("--driver-tpm", repeated)
        self.assertNotIn("fixture-secret", str(repeated))


if __name__ == "__main__":
    unittest.main()
