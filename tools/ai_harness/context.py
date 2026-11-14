"""Human-visible view state and acknowledged dialogue, never driving telemetry."""
from collections import deque
from copy import deepcopy


class TeamContext:
    def __init__(self):
        self.dialogue = deque(maxlen=8)
        self.results = {}
        self.last_messages = {}
        self.message_repeats = {}
        self.map_toggles = 0
        self.last_map_view = None
        self.previous_hud = {}
        self.guidance = None
        self.guidance_sequence = 0
        self.driver_guidance_sequence = 0

    def acknowledge(self, role, action, *, accepted, sim_time, observation_sim, error=""):
        self.results[role] = {"accepted": accepted, "sim_time": sim_time,
            "observation_sim": observation_sim, "hold": list(action["hold"]),
            "tap": list(action["tap"]), "error": error}
        if not accepted:
            return None
        if role == "navigator":
            self.map_toggles = self.map_toggles + 1 if "M" in action["tap"] else 0
            if "guidance" in action:
                self.guidance_sequence += 1
                self.guidance = {"id": self.guidance_sequence, "at": sim_time,
                    "observed_at": observation_sim, "instruction": deepcopy(action["guidance"])}
        else:
            self.driver_guidance_sequence = self.guidance_sequence
        speech = action["message"].strip()
        normalized = " ".join(speech.casefold().split())
        self.message_repeats[role] = (self.message_repeats.get(role, 0) + 1
            if normalized and self.last_messages.get(role) == normalized else int(bool(normalized)))
        self.last_messages[role] = normalized
        # Silence is an action, not a message. Never silently drop a repeated
        # warning: the model must reassess whether it is still needed.
        if not speech:
            return None
        message = {"role": role, "message": speech, "sim_time": sim_time,
                   "observation_sim": observation_sim}
        self.dialogue.append(message)
        return deepcopy(message)

    def observation(self, role, state, memory, heard):
        now = state["sim_time"]
        dialogue = [{**m, "age_sim_seconds": round(max(0, now - m["sim_time"]), 3),
                     "evidence_age_sim_seconds": round(max(0, now - m["observation_sim"]), 3)}
                    for m in self.dialogue]
        coordination = {"recent_dialogue": dialogue,
            "last_action_result": deepcopy(self.results.get(role)),
            "consecutive_identical_messages": self.message_repeats.get(role, 0)}
        if role == "navigator":
            coordination["consecutive_map_toggles"] = self.map_toggles
        # These labels describe what this seat's screenshot shows. The driver
        # receives no navigator map/camera state, partner keys, or private notes.
        view = {"camera": "seat", "facing": "forward", "map": "closed"}
        if role == "navigator":
            reveal = state.get("map_reveal", 0)
            view = {"camera": state.get("camera", "seat"),
                    "facing": "rear" if state.get("look_back") else "forward",
                    "map": ("open" if reveal >= .99 else "opening") if state.get("map_open")
                        else ("closing" if reveal > .01 else "closed")}
        # Only the exact rendered strings, never the evaluator's precise metrics.
        hud = {k: str(v) for k, v in state.get("hud", {}).items()
               if k in {"speed", "trip", "surface", "motion", "damage"}}
        extra = {"hud": hud, "previous_hud": deepcopy(self.previous_hud.get(role))}
        if self.guidance:
            extra["active_guidance"] = {**deepcopy(self.guidance),
                "age_seconds": round(max(0, now - self.guidance["at"]), 2),
                "already_acted_on": self.driver_guidance_sequence == self.guidance_sequence}
        self.previous_hud[role] = {"at": round(now, 2), **hud}
        if role == "navigator":
            if view["map"] == "open":
                self.last_map_view = {"at": round(now, 2), "trip": hud.get("trip", "unknown")}
            extra["map_check"] = {"last_open_view": deepcopy(self.last_map_view),
                "due": self.last_map_view is None or now - self.last_map_view["at"] >= 8}
        return {"frame": state["frame"], "sim_time": now, "held_keys": list(state["held"]),
                "input_feedback": state.get("input_error", ""), "view": view,
                "direction_warning": state.get("direction_warning", ""),
                "own_turn": memory.turn + 1, "working_memory": deepcopy(memory.recap),
                "coordination": coordination,
                **extra,
                "sound_captions": [{k: e[k] for k in ("id", "sim_time", "text")}
                    for e in state.get("sound_events", []) if e["id"] > heard]}
