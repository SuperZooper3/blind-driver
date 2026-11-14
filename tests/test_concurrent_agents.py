"""Scheduling regressions: slow peers, live chat, quota fairness, and shutdown."""
from concurrent.futures import Future, ThreadPoolExecutor
from copy import deepcopy
from pathlib import Path
from threading import Event
from types import SimpleNamespace
import io
import unittest

from tools.ai_harness.agents import InvalidModelResponse
from tools.ai_harness.coordinator import AgentCoordinator, ROLES
from tools.ai_harness.monitor import ConsoleMonitor


def action(message="", hold=None):
    return {"hold": hold or [], "tap": [], "message": message}


class ManualExecutor:
    def __init__(self):
        self.calls = []

    def submit(self, function, *args):
        future = Future()
        self.calls.append((future, function, args))
        return future

    def complete(self, index, result=None, error=None):
        future, function, args = self.calls[index]
        if error:
            future.set_exception(error)
        else:
            future.set_result(result if result is not None else function(*args))


class Fixture:
    def __init__(self, executor=None, agents=None, **settings):
        self.now = 0.0
        self.latest = {role: {"sim_time": 0.0, "frame": 1, "held": [], "image": "frames/1.jpg",
            "sequence": 0, "applied_sequence": 0} for role in ROLES}
        self.events, self.commands = [], []
        self.delayed_ack = set()
        self.sequence = {role: 0 for role in ROLES}
        self.executor = executor or ManualExecutor()
        self.recap_executor = ManualExecutor()
        args = SimpleNamespace(provider="cohere", rpm=6000, scripted_interval=.1, memory_every=0,
            max_tokens=200000, max_requests=100, decision_interval_sim=0)
        vars(args).update(settings)
        self.agents = agents or {role: SimpleNamespace(decide=lambda *a: (action(), {"input_tokens": 3, "output_tokens": 2}),
            summarize=lambda *a: ("Recap", {"input_tokens": 1, "output_tokens": 1})) for role in ROLES}
        self.coordinator = AgentCoordinator(args, Path("fixture"), self.agents, self.executor,
            self.recap_executor, self.log, self.command, clock=lambda: self.now)

    def log(self, event, **fields):
        self.events.append(deepcopy({"event": event, **fields}))

    def command(self, role, kind, **fields):
        self.sequence[role] += 1
        self.commands.append((role, kind, fields))
        if role not in self.delayed_ack:
            self.ack(role, fields.get("hold", []))
        return self.sequence[role]

    def ack(self, role, hold=None, accepted=True):
        self.latest[role].update(sequence=self.sequence[role],
            applied_sequence=self.sequence[role] if accepted else -1, held=hold or [],
            input_error="" if accepted else "stale_observation")

    def tick(self, seconds=.1, fresh=True):
        self.now += seconds
        for state in self.latest.values():
            if fresh:
                state["frame"] += 1
                state["sim_time"] += .01
        return self.coordinator.step(self.latest)


class ConcurrentAgentTests(unittest.TestCase):
    def test_fast_driver_repeats_while_navigator_is_still_thinking(self):
        entered, release = Event(), Event()
        driver_inputs = []
        def navigator(*_):
            entered.set()
            if not release.wait(5): raise RuntimeError("test did not release navigator")
            return action("Turn left"), {"input_tokens": 4, "output_tokens": 1}
        def driver(image, observed, messages):
            driver_inputs.append((observed, messages))
            return action("Checking alignment"), {"input_tokens": 4, "output_tokens": 1}
        with ThreadPoolExecutor(max_workers=2) as pool:
            fixture = Fixture(executor=pool, agents={"driver": SimpleNamespace(decide=driver),
                "navigator": SimpleNamespace(decide=navigator)})
            try:
                fixture.tick()
                self.assertTrue(entered.wait(1))
                nav_future = fixture.coordinator.seats["navigator"].future
                for _ in range(3):
                    fixture.coordinator.seats["driver"].future.result(timeout=1)
                    fixture.tick()  # accept this response
                    fixture.tick()  # acknowledge and start the next driver decision
                self.assertGreaterEqual(len(driver_inputs), 3)
                self.assertFalse(nav_future.done())
                self.assertEqual(fixture.coordinator.seats["navigator"].future, nav_future)
            finally:
                release.set()
                fixture.coordinator.finish(fixture.latest)

    def test_chat_arriving_during_inference_is_in_next_snapshot(self):
        f = Fixture()
        f.tick()  # both see the initial scene
        self.assertEqual([call[2][2] for call in f.executor.calls], [[], []])
        f.executor.complete(0, (action("Brake, obstacle ahead"), {}))
        f.tick(); f.tick()  # navigator speaks while driver is still in flight
        driver = f.coordinator.seats["driver"]
        self.assertEqual(driver.inbox[0]["message"], "Brake, obstacle ahead")
        self.assertEqual(driver.context["delivered"], [])
        f.executor.complete(1, (action("Was accelerating"), {}))
        f.tick(); f.tick()
        observed, delivered = driver.context["observation"], driver.context["delivered"]
        self.assertEqual(delivered[0]["message"], "Brake, obstacle ahead")
        self.assertEqual(observed["frame"], f.latest["driver"]["frame"])
        # The late driver reply must not pretend it had already read the warning.
        reply = [e for e in f.events if e["event"] == "message" and e["role"] == "driver"][-1]
        self.assertEqual(reply["in_reply_to"], 0)
        self.assertGreater(observed["coordination"]["latest_message_id"], reply["in_reply_to"])

    def test_slow_game_acknowledgment_blocks_only_its_own_seat(self):
        f = Fixture()
        f.delayed_ack.add("driver")
        f.tick()
        f.executor.complete(0); f.executor.complete(1)
        f.tick(); f.tick()
        self.assertEqual(f.coordinator.requests, 3)  # navigator starts again
        self.assertIsNotNone(f.coordinator.seats["driver"].acknowledgment)
        self.assertIsNone(f.coordinator.seats["driver"].future)
        self.assertEqual(sum(role == "driver" for role, *_ in f.commands), 1)

    def test_request_and_token_caps_apply_across_both_seats_and_drain_final_actions(self):
        for settings, expected in [({"max_requests": 2}, "request_budget"),
                                   ({"max_tokens": 8}, "token_budget")]:
            with self.subTest(settings=settings):
                f = Fixture(**settings)
                f.tick()
                self.assertEqual(f.coordinator.requests, 2)
                f.executor.complete(0); f.executor.complete(1)
                self.assertIsNone(f.tick())
                self.assertEqual(f.tick(), expected)
                self.assertEqual(len(f.commands), 2)
                self.assertEqual(f.coordinator.requests, 2)
                self.assertEqual(f.coordinator.input_tokens + f.coordinator.output_tokens, 10)
                self.assertTrue(f.coordinator.usage_complete)
        f = Fixture(max_requests=1)
        f.tick()
        self.assertEqual(len(f.executor.calls), 1)
        f.executor.complete(0)
        f.tick()
        self.assertEqual(f.tick(), "request_budget")

    def test_older_waiting_seat_gets_next_rate_slot(self):
        f = Fixture(rpm=60)
        f.tick(seconds=0)
        f.executor.complete(0)
        f.tick(seconds=.1); f.tick(seconds=.1)
        self.assertEqual(f.coordinator.requests, 2)
        f.tick(seconds=.8)  # navigator consumes the next slot; driver still busy
        self.assertEqual(f.coordinator.requests, 3)
        f.executor.complete(1); f.executor.complete(2)
        f.tick(seconds=.1); f.tick(seconds=.1)
        f.tick(seconds=.8)
        request = [e for e in f.events if e["event"] == "request"][-1]
        self.assertEqual(request["role"], "driver")
        self.assertEqual(f.coordinator.requests, 4)

    def test_unchanged_frame_waits_but_new_chat_wakes_seat_before_optional_delay(self):
        f = Fixture(decision_interval_sim=5)
        f.tick(); f.executor.complete(0); f.executor.complete(1)
        f.tick(fresh=False); f.tick(fresh=False)
        self.assertEqual(f.coordinator.requests, 2)
        f.coordinator.seats["driver"].inbox.append({"role": "navigator", "message": "Brake now"})
        f.tick(fresh=False)
        self.assertEqual(f.coordinator.requests, 3)
        self.assertTrue(f.coordinator.seats["navigator"].idle)
        self.assertEqual(f.coordinator.seats["driver"].context["delivered"][0]["message"], "Brake now")

    def test_failed_call_restores_undelivered_chat_before_newer_messages(self):
        f = Fixture()
        driver = f.coordinator.seats["driver"]
        driver.inbox.append({"role": "navigator", "message": "First warning"})
        f.tick()
        f.executor.complete(0, (action("Newer correction"), {}))
        f.tick(); f.tick()
        f.executor.complete(1, error=InvalidModelResponse("bad json", {"input_tokens": 9}, {}))
        f.tick()
        self.assertEqual([m["message"] for m in driver.inbox], ["First warning", "Newer correction"])
        f.tick(seconds=3)
        self.assertEqual([m["message"] for m in driver.context["delivered"]], ["First warning", "Newer correction"])
        self.assertEqual(f.coordinator.input_tokens, 9)
        self.assertFalse(any("unavailable" in e.get("message", "") for e in f.events))

    def test_recaps_use_separate_worker_without_delaying_decisions(self):
        f = Fixture(memory_every=1)
        f.tick(); f.executor.complete(0); f.executor.complete(1)
        f.tick(); f.tick()
        f.tick()  # both decisions still pending; refill permits background recap
        self.assertEqual(f.coordinator.requests, 5)
        self.assertEqual(len(f.recap_executor.calls), 1)
        self.assertEqual(len(f.executor.calls), 4)
        f.executor.complete(2); f.executor.complete(3)
        f.tick(); f.tick()
        self.assertEqual(len(f.executor.calls), 6)
        self.assertFalse(f.recap_executor.calls[0][0].done())

    def test_stop_accounts_for_both_inflight_calls_without_applying_them(self):
        f = Fixture()
        f.tick()
        f.executor.complete(0, (action("late"), {"input_tokens": 10, "output_tokens": 2}))
        f.executor.complete(1, error=InvalidModelResponse("invalid", {"input_tokens": 11, "output_tokens": 3}, {}))
        f.coordinator.finish(f.latest)
        self.assertEqual(f.commands, [])
        self.assertTrue(f.coordinator.usage_complete)
        self.assertEqual(f.coordinator.input_tokens + f.coordinator.output_tokens, 26)
        self.assertEqual(len([e for e in f.events if e["event"] == "response_discarded"]), 2)

    def test_monitor_tracks_each_inflight_seat_independently(self):
        monitor = ConsoleMonitor(Path("fixture"), {"created_unix": 0, "speed": 5,
            "sim_seconds": 60, "provider": "scripted"}, io.StringIO())
        for index, role in enumerate(ROLES):
            monitor.event({"event": "request", "role": role, "unix_time": 1, "request_id": index,
                "observation": {"frame": 1, "sim_time": 0}})
        monitor.event({"event": "request_error", "role": "driver", "unix_time": 2, "error": "timeout"})
        monitor.status({"driver": {"active": True}}, now=2, force=True)
        self.assertIn("NAVIGATOR thinking", monitor.output.getvalue())
        self.assertEqual(monitor.pending, {"NAVIGATOR"})
