"""Translate explicit model intents to ordinary, bounded keyboard gestures.

No route sensor, lane following, speed feedback controller, or chosen steering
is implemented here. All directions/pedals come from the model's decision.
"""
import math


def _seconds(value, default):
    if value is None:
        return default
    if not isinstance(value, bool) and value == 0:
        return default
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not .05 <= value <= 1:
        raise ValueError("Pulse duration must be 0.05–1 game seconds")
    return value


def translate_decision(value, role, observation):
    if not isinstance(value, dict):
        raise ValueError("Decision must be a JSON object")
    # Old providers/explicit scripted baselines retain the keyboard contract.
    if "hold" in value:
        return value
    result = {"hold": [], "tap": [], "message": value.get("message", ""), "notes": value.get("notes", "")}
    if role == "driver":
        if set(value) - {"pedal", "steering", "pedal_seconds", "steering_seconds", "message", "notes"}:
            raise ValueError("Unknown driver decision field")
        pedal, steering = value.get("pedal"), value.get("steering")
        if pedal not in {"accelerate", "coast", "brake", "reverse", "park"} or steering not in {"left", "straight", "right"}:
            raise ValueError("Choose a valid pedal and steering intent")
        if pedal in {"accelerate", "brake", "reverse"}:
            result["hold"].append("W" if pedal == "accelerate" else "S")
            result["pedal_pulse_sim"] = _seconds(value.get("pedal_seconds"), {"accelerate": 1, "brake": .2, "reverse": .3}[pedal])
        elif pedal == "park":
            result["hold"].append("SPACE")
        if steering != "straight":
            result["hold"].append("A" if steering == "left" else "D")
            result["steering_pulse_sim"] = _seconds(value.get("steering_seconds"), .15)
    else:
        if set(value) - {"view", "message", "notes"} or value.get("view") not in {"map", "chase", "rear", "seat"}:
            raise ValueError("Choose navigator view map/chase/rear/seat")
        desired, current = value["view"], observation.get("view", {})
        if desired == "rear":
            result["hold"] = ["B"]
        else:
            opened = current.get("map") in {"open", "opening"}
            if (desired == "map") != opened:
                result["tap"].append("M")
            if desired in {"chase", "seat"} and current.get("camera", "seat") != desired:
                result["tap"].append("C")
    return result


def decision_schema(role):
    properties = {"notes": {"type": "string"}, "message": {"type": "string"}}
    if role == "driver":
        properties.update(pedal={"type": "string", "enum": ["accelerate", "coast", "brake", "reverse", "park"]},
                          steering={"type": "string", "enum": ["left", "straight", "right"]})
        properties["pedal_seconds"] = {"type": "number", "description": "0 uses gesture default; otherwise 0.05–1 game seconds"}
        properties["steering_seconds"] = {"type": "number", "description": "0 uses 0.15s; otherwise 0.05–1 game seconds"}
    else:
        properties["view"] = {"type": "string", "enum": ["map", "chase", "rear", "seat"]}
    required = [k for k in properties if not k.endswith("_seconds")]
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}
