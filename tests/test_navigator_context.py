"""Regressions for the map-loop run: context, delivery, and provider payloads."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.ai_harness.agents import CohereAgent, DEFAULT_MODEL, InvalidModelResponse, prompt
from tools.ai_harness.context import TeamContext
from tools.ai_harness.memory import WorkingMemory


def state(**extra):
    return {"frame": 17, "sim_time": 5.0, "held": [], "map_open": True, "map_reveal": 1,
        "camera": "chase", "look_back": False, "position": [999, 999, 999],
        "speed_kmh": 91, "road_distance_m": 25, "impact_events": 7, "part_health": [0],
        "sound_events": [{"id": 2, "sim_time": 4.5, "text": "CRASH — hard impact", "strength": 99}], **extra}


class NavigatorContextTests(unittest.TestCase):
    def test_latest_guidance_replaces_old_turn_only_after_acceptance(self):
        from tools.ai_harness.actions import translate_decision
        from tools.ai_harness.agents import validate_action
        team, memory = TeamContext(), WorkingMemory(0)
        def advise(steering, at, accepted=True):
            decision = {"view": "chase", "message": "", "notes": "Private road observation",
                "guidance": {"travel": "forward", "steering": steering, "target_speed_kmh": 40, "steering_seconds": .15}}
            observation = team.observation("navigator", state(sim_time=at), memory, 0)
            action = validate_action(translate_decision(decision, "navigator", observation), "navigator")
            team.acknowledge("navigator", action, accepted=accepted, sim_time=at, observation_sim=at)
            return action
        self.assertIn("steer left", advise("left", 1)["message"])
        first = team.observation("driver", state(sim_time=1.1), memory, 0)["active_guidance"]
        self.assertFalse(first["already_acted_on"])
        team.acknowledge("driver", {"hold": ["A"], "tap": [], "message": ""},
                         accepted=True, sim_time=1.2, observation_sim=1.1, observation={"active_guidance": first})
        self.assertTrue(team.observation("driver", state(), memory, 0)["active_guidance"]["already_acted_on"])
        advise("right", 2, accepted=False)
        self.assertEqual(team.observation("driver", state(), memory, 0)["active_guidance"]["id"], first["id"])
        self.assertIn("straighten", advise("straight", 3)["message"])
        latest = team.observation("driver", state(), memory, 0)
        self.assertEqual(latest["active_guidance"]["instruction"]["steering"], "straight")
        self.assertFalse(latest["active_guidance"]["already_acted_on"])
        self.assertEqual(advise("straight", 4)["message"], "")
        self.assertNotIn("Private road observation", json.dumps(latest))

    def test_late_driver_reply_does_not_consume_newer_guidance(self):
        team, memory = TeamContext(), WorkingMemory(0)
        base = {"hold": [], "tap": [], "message": "", "guidance":
            {"travel": "forward", "steering": "left", "target_speed_kmh": 30, "steering_seconds": .15}}
        team.acknowledge("navigator", base, accepted=True, sim_time=1, observation_sim=.5)
        driver_input = team.observation("driver", state(sim_time=1.1), memory, 0)
        team.acknowledge("navigator", {**base, "guidance": {**base["guidance"], "steering": "straight"}},
            accepted=True, sim_time=2, observation_sim=1.5)
        team.acknowledge("driver", {"hold": ["A"], "tap": [], "message": "Turning left"},
            accepted=True, sim_time=2.1, observation_sim=1.1, observation=driver_input)
        updated = team.observation("driver", state(sim_time=2.2), memory, 0)
        self.assertEqual(updated["active_guidance"]["instruction"]["steering"], "straight")
        self.assertFalse(updated["active_guidance"]["already_acted_on"])
        team.acknowledge("driver", {"hold": [], "tap": [], "message": "Straightening"},
            accepted=True, sim_time=2.3, observation_sim=2.2, observation=updated)
        self.assertTrue(team.observation("driver", state(sim_time=2.4), memory, 0)["active_guidance"]["already_acted_on"])

    def test_provider_receives_every_unread_message_and_reply_ids(self):
        messages = [{"id": i, "in_reply_to": i - 1, "role": "navigator",
            "message": "Instruction %d" % i, "sim_time": i / 10} for i in range(1, 11)]
        observation = {"sim_time": 2, "coordination": {"recent_dialogue": messages[-4:]}}
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "view.jpg"
            image.write_bytes(b"fixture")
            agent = CohereAgent("driver", DEFAULT_MODEL, "unused", "Driver", 10, 1536, 2)
            decision = {"pedal": "park", "steering": "straight", "message": "", "notes": "Waiting"}
            with patch.object(agent, "_chat", return_value=(json.dumps(decision), {}, {})) as chat:
                agent.decide(image, observation, messages)
            text = chat.call_args.args[0]["messages"][0]["content"][0]["text"]
            payload = json.loads(text.split("Current situation:\n", 1)[1])
        self.assertEqual([m["id"] for m in payload["new_partner_messages"]], list(range(1, 11)))
        self.assertEqual(payload["new_partner_messages"][0]["said"], "Instruction 1")
        self.assertEqual(payload["new_partner_messages"][-1]["in_reply_to"], 9)
        self.assertEqual(payload["dialogue"], [])  # No duplicate copies of unread speech.

    def test_map_loop_has_recent_dialogue_and_execution_feedback_without_telemetry(self):
        team, memory = TeamContext(), WorkingMemory(0)
        for i in range(3):
            team.acknowledge("navigator", {"hold": [], "tap": ["M"],
                "message": "Check map for upcoming turns and obstacles.", "notes": "private navigator notes"},
                accepted=True, sim_time=i + 1, observation_sim=i + .5)
            team.acknowledge("driver", {"hold": ["W"], "tap": [], "message": "Still blocked; which way?",
                "notes": "private driver notes"}, accepted=True, sim_time=i + 1.5, observation_sim=i + 1)
        observation = team.observation("navigator", state(), memory, 1)
        coordination = observation["coordination"]
        self.assertEqual(coordination["consecutive_map_toggles"], 3)
        self.assertEqual(coordination["consecutive_identical_messages"], 3)
        self.assertEqual(coordination["recent_dialogue"][-1]["message"], "Still blocked; which way?")
        self.assertEqual(coordination["recent_dialogue"][-1]["age_sim_seconds"], 1.5)
        self.assertEqual(coordination["recent_dialogue"][-1]["evidence_age_sim_seconds"], 2)
        self.assertTrue(coordination["last_action_result"]["accepted"])
        self.assertEqual(observation["view"], {"camera": "chase", "facing": "forward", "map": "open"})
        self.assertEqual(observation["sound_captions"], [{"id": 2, "sim_time": 4.5, "text": "CRASH — hard impact"}])
        serialized = json.dumps(observation)
        for private in ("position", "speed_kmh", "road_distance_m", "impact_events", "part_health", "strength", "private", '"W"'):
            self.assertNotIn(private, serialized)
        driver = team.observation("driver", state(held=["W"]), memory, 2)
        self.assertEqual(driver["view"], {"camera": "seat", "facing": "forward", "map": "closed"})
        self.assertEqual(driver["sound_captions"], [])

    def test_silence_rejected_actions_and_repeated_urgent_warnings(self):
        team, memory = TeamContext(), WorkingMemory(0)
        warning = {"hold": [], "tap": ["M"], "message": "Brake! Rock ahead.", "notes": "private"}
        for i in range(2):
            self.assertEqual(team.acknowledge("navigator", warning, accepted=True,
                sim_time=i, observation_sim=i)["message"], warning["message"])
        self.assertIsNone(team.acknowledge("navigator", {**warning, "message": "Never delivered"},
            accepted=False, sim_time=2, observation_sim=0, error="stale_observation"))
        observed = team.observation("navigator", state(), memory, 0)
        self.assertFalse(observed["coordination"]["last_action_result"]["accepted"])
        self.assertEqual(observed["coordination"]["consecutive_map_toggles"], 2)
        self.assertNotIn("Never delivered", json.dumps(observed))
        silent = {"hold": [], "tap": [], "message": "  \n", "notes": "Checking map privately"}
        self.assertIsNone(team.acknowledge("navigator", silent, accepted=True, sim_time=3, observation_sim=3))
        observed = team.observation("navigator", state(), memory, 0)
        self.assertEqual(len(observed["coordination"]["recent_dialogue"]), 2)
        self.assertEqual(observed["coordination"]["consecutive_map_toggles"], 0)
        self.assertEqual(observed["coordination"]["consecutive_identical_messages"], 0)
        self.assertEqual(observed["held_keys"], [])

    def test_dialogue_bounded_and_returned_observation_is_a_snapshot(self):
        team, memory = TeamContext(), WorkingMemory(0)
        for i in range(20):
            team.acknowledge("driver", {"hold": ["W"], "tap": [], "message": str(i)},
                accepted=True, sim_time=i, observation_sim=i)
        observed = team.observation("driver", state(sim_time=21), memory, 0)
        self.assertEqual([m["message"] for m in observed["coordination"]["recent_dialogue"]],
                         list(map(str, range(12, 20))))
        observed["coordination"]["last_action_result"]["hold"].clear()
        observed["coordination"]["recent_dialogue"][0]["message"] = "mutated"
        fresh = team.observation("driver", state(sim_time=21), memory, 0)
        self.assertEqual(fresh["coordination"]["last_action_result"]["hold"], ["W"])
        self.assertEqual(fresh["coordination"]["recent_dialogue"][0]["message"], "12")

    def test_map_animation_and_rear_view_labels(self):
        team, memory = TeamContext(), WorkingMemory(0)
        for opening, reveal, expected in ((True, .2, "opening"), (True, 1, "open"),
                                         (False, .3, "closing"), (False, 0, "closed")):
            observed = team.observation("navigator", state(map_open=opening, map_reveal=reveal), memory, 0)
            self.assertEqual(observed["view"]["map"], expected)
        observed = team.observation("navigator", state(map_open=False, map_reveal=0, look_back=True), memory, 0)
        self.assertEqual(observed["view"]["facing"], "rear")

    def test_recap_records_do_not_embed_previous_recaps_or_duplicate_dialogue(self):
        memory = WorkingMemory(8)
        memory.record({"sim_time": 3, "working_memory": {"text": "old recap"},
            "coordination": {"recent_dialogue": [{"message": "old speech"}]},
            "sound_captions": [{"text": "CRASH"}]}, [{"message": "Are we blocked?"}],
            {"hold": [], "tap": [], "message": "Let me check.", "notes": "Obstruction uncertain"}, 4)
        serialized = json.dumps(memory.turns)
        self.assertNotIn("old recap", serialized)
        self.assertNotIn("old speech", serialized)
        for fact in ("CRASH", "Are we blocked?", "Obstruction uncertain"):
            self.assertIn(fact, serialized)

    def test_command_payload_keeps_latest_dialogue_and_one_image_without_recursive_recaps(self):
        team, memory = TeamContext(), WorkingMemory(0)
        memory.recap = {"text": "Prior road looked straight, outcome unverified", "through_turn": 3}
        team.acknowledge("driver", {"hold": [], "tap": [], "message": "Hit something; now stopped."},
                         accepted=True, sim_time=4, observation_sim=3.5)
        requests = []
        action = {"hold": [], "tap": ["M"], "message": "Release W; I need to check clearance.",
                  "notes": "Impact audible; map covers road; closing it to inspect."}
        def chat(body):
            requests.append(body)
            return json.dumps(action), {}, {}
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "current.jpg"
            image.write_bytes(b"fixture")
            agent = CohereAgent("navigator", "command-a-plus-05-2026", "unused", prompt("navigator", 25, "basic"), 10, 512, 1)
            with patch.object(agent, "_chat", side_effect=chat):
                for _ in range(3):
                    agent.decide(image, team.observation("navigator", state(), memory, 0), [])
        body = requests[-1]
        self.assertEqual(body["thinking"], {"type": "disabled"})
        self.assertEqual(body["response_format"]["type"], "json_object")
        self.assertEqual(body["response_format"]["schema"]["properties"]["view"]["enum"], ["map", "chase", "rear", "seat"])
        self.assertNotIn("steering_pulse_sim", body["response_format"]["schema"]["properties"])
        content = body["messages"][-1]["content"]
        self.assertIn("are NAVIGATOR", content[0]["text"])
        self.assertIn("Return ONLY the JSON object", content[-1]["text"])
        self.assertIn("Hit something; now stopped.", content[0]["text"])
        self.assertIn("CRASH", content[0]["text"])
        self.assertEqual(sum(p.get("type") == "image_url" for m in body["messages"]
                             if isinstance(m["content"], list) for p in m["content"]), 1)
        self.assertNotIn("working_memory", json.dumps(agent.history))
        self.assertNotIn("coordination", json.dumps(agent.history))
        self.assertIn("Impact audible", json.dumps(agent.history))

    def test_visible_hud_and_map_check_age_do_not_expose_evaluator_metrics(self):
        team, memory = TeamContext(), WorkingMemory(0)
        hud = {"speed": "79 km/h", "trip": "260 m", "surface": "OFF ROAD", "motion": "MOVING",
               "damage": "CAR UNDAMAGED", "road_heading": 91.34}
        first = team.observation("navigator", state(map_open=False, map_reveal=0, hud=hud), memory, 0)
        self.assertTrue(first["map_check"]["due"])
        self.assertEqual(first["hud"]["surface"], "OFF ROAD")
        self.assertNotIn("road_heading", json.dumps(first))
        self.assertIsNone(first["previous_hud"])
        opened = team.observation("navigator", state(sim_time=6, hud=hud), memory, 0)
        self.assertFalse(opened["map_check"]["due"])
        self.assertEqual(opened["previous_hud"]["at"], 5)
        later = team.observation("navigator", state(sim_time=15, map_open=False, map_reveal=0, hud=hud), memory, 0)
        self.assertTrue(later["map_check"]["due"])
        self.assertEqual(later["map_check"]["last_open_view"], {"at": 6, "trip": "260 m"})

    def test_steering_pulse_requires_finite_bounded_driver_steering(self):
        from tools.ai_harness.agents import validate_action
        action = {"hold": ["W", "A"], "tap": [], "message": "", "steering_pulse_sim": .15}
        self.assertEqual(validate_action(action, "driver"), action)
        for pulse in (True, float("nan"), float("inf"), .01, 2, "0.2"):
            with self.subTest(pulse=pulse), self.assertRaises(ValueError):
                validate_action({**action, "steering_pulse_sim": pulse}, "driver")
        for hold in (["W"], []):
            self.assertNotIn("steering_pulse_sim", validate_action({**action, "hold": hold}, "driver"))
        self.assertNotIn("steering_pulse_sim", validate_action({**action, "steering_pulse_sim": 0}, "driver"))
        self.assertEqual(validate_action({"hold": ["S"], "tap": [], "message": "", "pedal_pulse_sim": .2}, "driver")["pedal_pulse_sim"], .2)
        with self.assertRaises(ValueError):
            validate_action({**action, "hold": ["B"]}, "navigator")

    def test_reasoning_and_resizing_preserve_the_entire_seat_without_old_images(self):
        import base64
        import io
        from PIL import Image
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "seat.jpg"
            Image.new("RGB", (1280, 800), "red").save(image)
            agent = CohereAgent("driver", DEFAULT_MODEL, "unused", "Drive", 10, 1536, 2,
                                thinking_tokens=512, image_width=960)
            requests = []
            def chat(body):
                requests.append(body)
                return json.dumps({"notes": "Speed readable", "hold": [], "tap": [], "message": ""}), {}, {}
            with patch.object(agent, "_chat", side_effect=chat):
                agent.decide(image, {}, [])
            body = requests[0]
            self.assertEqual(body["thinking"], {"type": "enabled", "token_budget": 512})
            data = body["messages"][0]["content"][1]["image_url"]["url"].split(",", 1)[1]
            with Image.open(io.BytesIO(base64.b64decode(data))) as sent:
                self.assertEqual(sent.size, (960, 600))
            with Image.open(image) as original:
                self.assertEqual(original.size, (1280, 800))

    def test_recovery_question_overrides_routine_map_check(self):
        from tools.ai_harness.prompts import current_task
        question = current_task("navigator", {"hud": {"surface": "OFF ROAD"},
            "view": {"map": "closed"}, "map_check": {"due": True, "last_open_view": None}})
        self.assertIn("LEFT/RIGHT", question)
        self.assertIn("No routine map check", question)
        self.assertIn("keep view=map", current_task("navigator", {"view": {"map": "opening"}}))

    def test_invalid_image_reply_is_reported_next_turn_without_fabricating_an_action(self):
        action = {"hold": [], "tap": [], "message": "", "notes": "Road view; awaiting driver question"}
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "view.jpg"
            image.write_bytes(b"fixture")
            agent = CohereAgent("navigator", "command-a-vision-07-2025", "unused", "Navigator prompt", 10, 512, 2)
            requests = []
            def chat(body):
                requests.append(body)
                return (("={}" if len(requests) == 1 else json.dumps(action)), {}, {})
            with patch.object(agent, "_chat", side_effect=chat):
                with self.assertRaises(InvalidModelResponse):
                    agent.decide(image, {}, [])
                self.assertEqual(agent.history, [])
                self.assertEqual(agent.decide(image, {}, [])[0], action)
            self.assertEqual(requests[1]["model"], "command-a-vision-07-2025")
            self.assertNotIn("thinking", requests[1])
            self.assertNotIn("response_format", requests[1])
            self.assertIn("no action/message was delivered", requests[1]["messages"][-1]["content"][0]["text"])
            self.assertEqual(agent.response_feedback, "")


if __name__ == "__main__":
    unittest.main()
