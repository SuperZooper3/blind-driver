"""Independent seat decisions with shared dialogue, quotas, and game acknowledgments.

Only this coordinator mutates shared state. Worker threads receive snapshots; each
seat has at most one decision or unacknowledged action in progress.
"""
from copy import deepcopy
from dataclasses import dataclass, field
import time

from .agents import InvalidModelResponse, validate_action
from .context import TeamContext
from .memory import RateBudget, WorkingMemory, InputTokenWindow
from .gemini import GeminiAPIError

ROLES = ("navigator", "driver")
CONTROL_FIELDS = ("hold", "tap", "steering_pulse_sim", "pedal_pulse_sim")


@dataclass
class SeatLoop:
    future: object = None
    context: dict = field(default_factory=dict)
    acknowledgment: tuple | None = None
    last_frame: int = -1
    last_request: float = float("-inf")
    next_request: float = 0
    next_observation_sim: float = 0
    error_streak: int = 0
    heard: int = 0
    inbox: list = field(default_factory=list)
    last_observation_sim: float | None = None
    last_latency_real: float = 0
    quota_released: bool = False

    @property
    def idle(self):
        return self.future is None and self.acknowledgment is None

    def ready(self, state, now):
        # New speech can wake a seat even before the next image or optional
        # simulation interval. Never repeatedly send an unchanged silent frame.
        return (self.idle and now >= self.next_request and
                (bool(self.inbox) or (state["frame"] != self.last_frame and
                 state["sim_time"] >= self.next_observation_sim)))


class AgentCoordinator:
    def __init__(self, args, directory, agents, executor, recap_executor, log, command,
                 *, enrich_observation=None, clock=time.monotonic):
        self.args, self.directory, self.agents = args, directory, agents
        self.executor, self.recap_executor = executor, recap_executor
        self.log, self.command, self.clock = log, command, clock
        self.enrich_observation = enrich_observation
        self.seats = {role: SeatLoop() for role in ROLES}
        self.memories = {role: WorkingMemory(args.memory_every if getattr(agents[role], "supports_memory", True) else 0)
                         for role in ROLES}
        self.team = TeamContext()
        self.rate = RateBudget(args.rpm if args.provider != "scripted" else 120 / args.scripted_interval, clock)
        self.role_next = {role: 0.0 for role in ROLES}
        self.token_windows = ({role: InputTokenWindow(getattr(args, role + "_tpm", 40000), clock)
                               for role in ROLES} if args.provider == "gemini" else {})
        self.requests = self.input_tokens = self.output_tokens = self.usage_known_requests = 0
        self.errors = []

    @property
    def usage_complete(self):
        return self.requests == self.usage_known_requests

    @property
    def budget_reason(self):
        if self.input_tokens + self.output_tokens >= self.args.max_tokens:
            return "token_budget"
        if self.requests >= self.args.max_requests:
            return "request_budget"
        return None

    @property
    def busy(self):
        return any(not seat.idle for seat in self.seats.values()) or any(m.pending for m in self.memories.values())

    def account(self, usage, role=None, request_id=None):
        self.input_tokens += int(usage.get("input_tokens", 0))
        self.output_tokens += int(usage.get("output_tokens", 0))
        self.usage_known_requests += int(usage.get("known", True))
        if role in self.token_windows:
            window = self.token_windows[role]
            window.settle(request_id, usage)
            if usage.get("known", True) and request_id in window.entries:
                started = window.entries[request_id][0]
                # Spread image-token usage across the minute, instead of
                # driving in a burst followed by a long quota-induced stop.
                self.role_next[role] = max(self.role_next[role], started + 60 * window.estimate / window.limit)

    def role_ready(self, role):
        return (self.clock() >= self.role_next[role] and
                (role not in self.token_windows or self.token_windows[role].ready()))

    def take_role(self, role):
        if role in self.token_windows:
            self.token_windows[role].reserve(self.requests + 1)
        rpm = getattr(self.args, role + "_rpm", None)
        if self.args.provider == "gemini" and rpm:
            # No burst per model; action and recap requests share this slot.
            self.role_next[role] = self.clock() + 60 / rpm

    def collect_memory(self, role, latest, *, ending=False):
        memory = self.memories[role]
        pending = memory.pending
        if not pending or (not ending and not pending["future"].done()):
            return
        try:
            recap, usage = memory.finish()
            self.account(usage, role, pending["request_id"])
            self.log("memory_response", role=role, request_id=pending["request_id"], memory=recap,
                latency_seconds=self.clock() - pending["started"], usage=usage,
                sim_time=latest.get(role, {}).get("sim_time", 0))
        except Exception as exc:
            detail = {}
            if isinstance(exc, InvalidModelResponse):
                self.account(exc.usage, role, pending["request_id"])
                detail["usage"] = exc.usage
            self.log("memory_error", role=role, request_id=pending["request_id"],
                error=str(exc)[:250] if isinstance(exc, (ValueError, RuntimeError)) else type(exc).__name__, **detail)

    def step(self, latest):
        # Deliver every accepted message before building either seat's next input.
        for role, seat in self.seats.items():
            self.collect_memory(role, latest)
            if not seat.acknowledgment:
                continue
            seq, action, latency, context = seat.acknowledgment
            observed, state = context["observation"], latest[role]
            if state.get("sequence", -1) < seq:
                continue
            accepted = state.get("applied_sequence") == seq
            self.log("action_ack", role=role, sequence=seq, accepted=accepted,
                sim_time=state["sim_time"], held=state["held"], error=state.get("input_error", ""),
                request_id=context["request_id"],
                action={k: action[k] for k in CONTROL_FIELDS if k in action})
            message = self.team.acknowledge(role, action, accepted=accepted,
                sim_time=state["sim_time"], observation_sim=observed["sim_time"],
                error=state.get("input_error", ""), observation=observed)
            if accepted:
                self.memories[role].record(observed, context["delivered"], action, state["sim_time"])
                if message:
                    other = "driver" if role == "navigator" else "navigator"
                    self.log("message", **message, to=other, latency_seconds=latency,
                        hold=action["hold"], tap=action["tap"])
                    self.seats[other].inbox.append(message)
            seat.acknowledgment = None

        for role, seat in self.seats.items():
            if seat.future is None or not seat.future.done():
                continue
            future, seat.future = seat.future, None
            context = seat.context
            latency = self.clock() - context["started_monotonic"]
            try:
                action, usage = future.result()
                self.account(usage, role, context["request_id"])
                action = validate_action(action, role)
                if self.args.provider == "gemini" and role == "driver" and action["message"]:
                    raise ValueError("Gemini driver must remain silent")
                seat.last_latency_real = latency
                self.log("response", role=role, request_id=context["request_id"], action=action,
                    decision=getattr(self.agents[role], "last_decision", None),
                    latency_seconds=latency, usage=usage, sim_time=latest[role]["sim_time"],
                    observation_sim=context["observation"]["sim_time"])
                seq = self.command(role, "keys", **{k: action[k] for k in CONTROL_FIELDS if k in action},
                    observation_sim=context["observation"]["sim_time"])
                seat.acknowledgment = seq, action, latency, context
                seat.error_streak = 0
            except Exception as exc:
                seat.error_streak += 1
                seat.inbox[:0] = context["delivered"]
                seat.heard = context["heard_before"]
                seat.next_request = self.clock() + min(2 ** seat.error_streak, 5)
                details = {}
                if isinstance(exc, InvalidModelResponse):
                    self.account(exc.usage, role, context["request_id"])
                    details = {"usage": exc.usage, "details": exc.details}
                if self.args.provider == "gemini":
                    # Release even after a timeout/invalid answer: held steering
                    # must not persist throughout a potentially long cooldown.
                    self.command(role, "keys", hold=[], tap=[], observation_sim=latest[role]["sim_time"])
                    self.log("controls_released", role=role, reason="provider_error", sim_time=latest[role]["sim_time"])
                if isinstance(exc, GeminiAPIError):
                    seat.next_request = max(seat.next_request, self.clock() + exc.retry_after)
                    self.role_next[role] = max(self.role_next[role], seat.next_request)
                    details.update(http_status=exc.status, retry_after_seconds=exc.retry_after, quotas=exc.quotas)
                    if exc.permanent:
                        seat.error_streak = 3
                message = str(exc)[:250] if isinstance(exc, (ValueError, RuntimeError)) else type(exc).__name__
                self.errors.append({"role": role, "error": message})
                self.log("request_error", role=role, request_id=context["request_id"], error=message,
                    latency_seconds=latency, **details)

        if any(seat.error_streak >= 3 for seat in self.seats.values()):
            return "provider_errors"
        if self.budget_reason:
            # A request cap must not discard the other seat's already-paid result.
            # Stop dispatching now; finish outstanding actions and acknowledgments.
            return None if self.busy else self.budget_reason

        # Oldest opportunity first: a fast seat cannot monopolize the shared quota.
        for role in sorted(ROLES, key=lambda r: (self.seats[r].last_request, self.seats[r].context.get("request_id", 0))):
            seat, state = self.seats[role], latest[role]
            if self.args.provider == "gemini" and role == "driver":
                # Do not burn a free daily budget choosing "wait" while the
                # first Hydrogen request is still in flight.
                if not self.team.dialogue:
                    continue
                if seat.idle and not self.token_windows[role].ready() and not seat.quota_released:
                    self.command(role, "keys", hold=[], tap=[], observation_sim=state["sim_time"])
                    seat.quota_released = True
                    self.log("controls_released", role=role, reason="input_token_cooldown", sim_time=state["sim_time"])
            if not seat.ready(state, self.clock()) or not self.role_ready(role) or self.budget_reason:
                continue
            if not self.rate.take():
                break
            self.take_role(role)
            seat.quota_released = False
            observation = self.team.observation(role, state, self.memories[role], seat.heard)
            if self.args.provider == "gemini":
                accepted = self.team.results.get(role, {})
                observation["timing"] = {
                    "simulation_speed_percent": getattr(self.args, "speed", 25),
                    "since_previous_observation_sim_seconds": (None if seat.last_observation_sim is None else
                        round(state["sim_time"] - seat.last_observation_sim, 3)),
                    "since_last_control_ack_sim_seconds": (round(state["sim_time"] - accepted["sim_time"], 3)
                        if accepted else None),
                    "previous_request_latency_real_seconds": round(seat.last_latency_real, 3),
                    "minimum_request_interval_real_seconds": 60 / getattr(self.args, role + "_rpm", 10),
                }
                seat.last_observation_sim = state["sim_time"]
            path = self.directory / role / state["image"]
            if self.enrich_observation:
                self.enrich_observation(role, path, observation)
            heard_before = seat.heard
            seat.heard = max([seat.heard] + [e["id"] for e in observation["sound_captions"]])
            delivered, seat.inbox = deepcopy(seat.inbox), []
            self.requests += 1
            seat.context = {"role": role, "request_id": self.requests, "observation": observation,
                "delivered": delivered, "heard_before": heard_before, "started_monotonic": self.clock()}
            self.log("request", role=role, request_id=self.requests, observation=observation,
                image=f"{role}/{state['image']}", partner_messages=delivered)
            seat.future = self.executor.submit(self.agents[role].decide, path, observation, delivered)
            seat.last_request = self.clock()
            seat.last_frame = state["frame"]
            interval = self.args.scripted_interval if self.args.provider == "scripted" else 0
            seat.next_request = self.clock() + interval
            seat.next_observation_sim = state["sim_time"] + getattr(self.args, "decision_interval_sim", 0)

        # Recaps have a separate worker and leave a rate slot for the next action.
        # They can never occupy a seat's decision worker or consume its final call.
        if (not any(m.pending for m in self.memories.values()) and
                any(s.future for s in self.seats.values()) and self.requests + 1 < self.args.max_requests):
            for role in ROLES:
                if self.memories[role].due() and self.role_ready(role) and self.rate.take(reserve=1):
                    self.take_role(role)
                    self.requests += 1
                    pending = self.memories[role].start(self.recap_executor, self.agents[role], self.requests)
                    self.log("memory_request", role=role, request_id=self.requests,
                        through_turn=pending["through_turn"],
                        concurrent_actions=[s.context["request_id"] for s in self.seats.values() if s.future],
                        sim_time=latest[role]["sim_time"])
                    break
        return None

    def finish(self, latest):
        """After releasing keys/stopping the game, account for both in-flight calls."""
        for role, seat in self.seats.items():
            if seat.future is None:
                continue
            future, seat.future = seat.future, None
            try:
                _, usage = future.result()
                self.account(usage, role, seat.context["request_id"])
                self.log("response_discarded", role=role, request_id=seat.context["request_id"],
                    usage=usage, reason="episode_ended")
            except InvalidModelResponse as exc:
                self.account(exc.usage, role, seat.context["request_id"])
                self.log("response_discarded", role=role, request_id=seat.context["request_id"],
                    usage=exc.usage, reason="episode_ended_invalid_response")
            except Exception as exc:
                self.log("response_discarded", role=role, request_id=seat.context["request_id"],
                    reason="episode_ended", error=type(exc).__name__)
        for role in ROLES:
            self.collect_memory(role, latest, ending=True)
