import json
from pathlib import Path
import tempfile
import unittest

from tools.ai_harness.dashboard import snapshot


class LastControlsTests(unittest.TestCase):
    def test_last_accepted_press_survives_pulse_release_rejected_and_pending_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "manifest.json").write_text(json.dumps({"run_id": "fixture"}))
            for role in ("driver", "navigator"):
                (root / role).mkdir()
                (root / role / "latest.json").write_text(json.dumps({"held": [], "active": False}))
            events = [
                {"event": "response", "role": "driver", "request_id": 2, "action": {"hold": ["W", "A"], "tap": ["H"], "steering_pulse_sim": .3, "notes": "private"}},
                {"event": "action_ack", "role": "driver", "accepted": True, "sim_time": 1.2},
                {"event": "response", "role": "navigator", "request_id": 3, "action": {"hold": [], "tap": ["M"]}},
                {"event": "action_ack", "role": "navigator", "accepted": True, "sim_time": 1.8},
                {"event": "response", "role": "driver", "request_id": 4, "action": {"hold": ["S"], "tap": []}},
                {"event": "action_ack", "role": "driver", "accepted": False, "sim_time": 2.2},
                {"event": "response", "role": "navigator", "request_id": 5, "action": {"hold": ["B"], "tap": []}},
            ]
            (root / "events.jsonl").write_text("\n".join(map(json.dumps, events)))
            state = snapshot(root)
            driver = state["seats"]["driver"]
            self.assertEqual(driver["held"], [])
            self.assertEqual(driver["last_action"], {"request_id": 2, "sim_time": 1.2, "hold": ["W", "A"], "tap": ["H"], "steering_pulse_sim": .3})
            self.assertEqual(state["seats"]["navigator"]["last_action"]["tap"], ["M"])
            events.append({"event": "action_ack", "role": "driver", "request_id": 6, "accepted": True, "sim_time": 3,
                           "action": {"hold": [], "tap": [], "notes": "not public"}})
            (root / "events.jsonl").write_text("\n".join(map(json.dumps, events)))
            self.assertEqual(snapshot(root)["seats"]["driver"]["last_action"], {"request_id": 6, "sim_time": 3, "hold": [], "tap": []})

