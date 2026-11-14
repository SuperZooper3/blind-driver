import unittest
from tools.ai_harness.actions import translate_decision
from tools.ai_harness.agents import validate_action


class SemanticActionTests(unittest.TestCase):
    def driver(self, **fields):
        decision = {"pedal": "coast", "steering": "straight", "message": "", "notes": "", **fields}
        return validate_action(translate_decision(decision, "driver", {}), "driver")

    def test_coast_cannot_hold_accelerator_and_brake_has_bounded_default(self):
        self.assertEqual(self.driver()["hold"], [])
        action = self.driver(pedal="brake", steering="left")
        self.assertEqual(action["hold"], ["S", "A"])
        self.assertEqual(action["pedal_pulse_sim"], .2)
        self.assertEqual(action["steering_pulse_sim"], .15)
        self.assertEqual(self.driver(pedal="accelerate")["pedal_pulse_sim"], 1)
        self.assertEqual(self.driver(pedal="reverse")["pedal_pulse_sim"], .3)
        self.assertEqual(self.driver(pedal="park")["hold"], ["SPACE"])

    def test_explicit_durations_and_zero_default_never_create_unbounded_steering(self):
        for seconds, expected in ((0, .15), (.3, .3)):
            action = self.driver(steering="right", steering_seconds=seconds)
            self.assertEqual(action["steering_pulse_sim"], expected)
        for seconds in (-1, True, float("nan"), 3):
            with self.subTest(seconds=seconds), self.assertRaises(ValueError):
                self.driver(steering="right", steering_seconds=seconds)
        with self.assertRaises(ValueError):
            self.driver(pedal="teleport")

    def test_navigator_view_selection_is_idempotent_and_can_close_map_into_chase(self):
        def select(desired, map_state="closed", camera="seat", facing="forward"):
            return validate_action(translate_decision({"view": desired, "message": "Wait", "notes": "private"}, "navigator",
                {"view": {"map": map_state, "camera": camera, "facing": facing}}), "navigator")
        self.assertEqual(select("map")["tap"], ["M"])
        for phase in ("open", "opening"):
            self.assertEqual(select("map", phase)["tap"], [])
        self.assertEqual(select("chase", "open")["tap"], ["M", "C"])
        self.assertEqual(select("chase", "closed", "chase")["tap"], [])
        self.assertEqual(select("rear", "open")["hold"], ["B"])
        self.assertEqual(select("chase", "closed", "chase", "rear")["hold"], [])
        self.assertEqual(select("seat", "closed", "chase")["tap"], ["C"])
        with self.assertRaises(ValueError):
            translate_decision({"view": "drive"}, "navigator", {})

    def test_rejects_unsupported_fields_instead_of_inventing_controls(self):
        for role, decision in (("navigator", {"view": "map", "pedal": "accelerate"}),
                               ("driver", {"pedal": "coast", "steering": "left", "teleport": True})):
            with self.assertRaises(ValueError):
                translate_decision(decision, role, {})
