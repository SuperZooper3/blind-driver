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
        self.message_id = 0

    def acknowledge(self, role, action, *, accepted, sim_time, observation_sim, error="", observation=None):
        self.results[role] = {"accepted": accepted, "sim_time": sim_time,
            "observation_sim": observation_sim, "hold": list(action["hold"]),
            "tap": list(action["tap"]), "error": error}
        if not accepted:
            return None
        if role == "navigator":
            self.map_toggles = self.map_toggles + 1 if "M" in action["tap"] else 0
        speech = action["message"].strip()
        normalized = " ".join(speech.casefold().split())
        self.message_repeats[role] = (self.message_repeats.get(role, 0) + 1
            if normalized and self.last_messages.get(role) == normalized else int(bool(normalized)))
        self.last_messages[role] = normalized
        # Silence is an action, not a message. Never silently drop a repeated
        # warning: the model must reassess whether it is still needed.
        if not speech:
            return None
        self.message_id += 1
        seen = (observation or {}).get("coordination", {}).get("latest_message_id", 0)
        message = {"id": self.message_id, "in_reply_to": seen, "role": role, "message": speech, "sim_time": sim_time,
                   "observation_sim": observation_sim}
        self.dialogue.append(message)
        return deepcopy(message)

    def observation(self, role, state, memory, heard):
        now = state["sim_time"]
        dialogue = [{**m, "age_sim_seconds": round(max(0, now - m["sim_time"]), 3),
                     "evidence_age_sim_seconds": round(max(0, now - m["observation_sim"]), 3)}
                    for m in self.dialogue]
        coordination = {"recent_dialogue": dialogue, "latest_message_id": self.message_id,
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
        return {"frame": state["frame"], "sim_time": now, "held_keys": list(state["held"]),
                "input_feedback": state.get("input_error", ""), "view": view,
                "direction_warning": state.get("direction_warning", ""),
                "own_turn": memory.turn + 1, "working_memory": deepcopy(memory.recap),
                "coordination": coordination,
                "sound_captions": [{k: e[k] for k in ("id", "sim_time", "text")}
                    for e in state.get("sound_events", []) if e["id"] > heard]}
