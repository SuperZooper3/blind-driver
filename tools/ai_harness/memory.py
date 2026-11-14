"""Role-local factual recaps and a shared request rate budget."""
from __future__ import annotations

from copy import deepcopy
import time


class RateBudget:
    """Two-call burst lets both seats start together; long-run rate stays bounded."""
    def __init__(self, per_minute, clock=time.monotonic):
        self.clock, self.rate = clock, per_minute / 60
        self.tokens, self.updated = 2.0, clock()

    def take(self, count=1, *, reserve=0):
        now = self.clock()
        self.tokens = min(2.0, self.tokens + (now - self.updated) * self.rate)
        self.updated = now
        if self.tokens < count + reserve:
            return False
        self.tokens -= count
        return True


class WorkingMemory:
    def __init__(self, every):
        self.every, self.turn = every, 0
        self.recap = {"text": "", "through_turn": 0}
        self.turns = []
        self.last_scheduled = 0
        self.pending = None

    def record(self, observation, messages, action, accepted_sim):
        self.turn += 1
        # The recap already receives its predecessor plus the exact exchanges.
        # Avoid resending embedded recap/dialogue windows for every recorded turn.
        compact = {k: v for k, v in observation.items() if k not in {"working_memory", "coordination"}}
        self.turns.append(deepcopy({"turn": self.turn, "observation": compact,
            "partner_messages": messages, "action": action, "accepted_sim": accepted_sim}))
        # Separate from provider history; recaps always operate on immutable snapshots.
        self.turns = self.turns[-32:]

    def due(self):
        return self.every > 0 and not self.pending and self.turn - self.last_scheduled >= self.every

    def start(self, executor, agent, request_id):
        self.last_scheduled = self.turn
        turns = deepcopy([t for t in self.turns if t["turn"] > self.recap["through_turn"]])
        self.pending = {"future": executor.submit(agent.summarize, deepcopy(self.recap), turns),
            "request_id": request_id, "through_turn": self.turn, "started": time.monotonic()}
        return self.pending

    def finish(self):
        pending, self.pending = self.pending, None
        text, usage = pending["future"].result()
        self.recap = {"text": text, "through_turn": pending["through_turn"]}
        return deepcopy(self.recap), usage
