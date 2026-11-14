"""Model boundary: screenshots, own action history, and delivered messages only."""
from __future__ import annotations

import base64
import json
import math
import urllib.error
import urllib.request
from pathlib import Path


HELD_KEYS = {"driver": {"W", "S", "A", "D", "SPACE"}, "navigator": {"B"}}
TAP_KEYS = {"driver": {"H"}, "navigator": {"M", "C"}}


class InvalidModelResponse(ValueError):
    def __init__(self, message, usage, details):
        super().__init__(message)
        self.usage, self.details = usage, details


def validate_action(value: object, role: str) -> dict:
    if not isinstance(value, dict) or set(value) != {"hold", "tap", "hold_sim_seconds", "message"}:
        raise ValueError("Expected hold, tap, hold_sim_seconds, and message only")
    for field, allowed in (("hold", HELD_KEYS[role]), ("tap", TAP_KEYS[role])):
        keys = value[field]
        if not isinstance(keys, list) or any(not isinstance(k, str) or k not in allowed for k in keys):
            raise ValueError(f"Invalid {field} keys for {role}")
        if len(keys) != len(set(keys)):
            raise ValueError("Duplicate keys")
    held, tap = set(value["hold"]), set(value["tap"])
    if {"W", "S"} <= held or {"A", "D"} <= held or ("B" in held and "M" in tap):
        raise ValueError("Conflicting keys")
    duration = value["hold_sim_seconds"]
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 0.05 <= duration <= 2:
        raise ValueError("Hold duration must be 0.05–2 simulation seconds")
    if not isinstance(value["message"], str) or len(value["message"]) > 240:
        raise ValueError("Message must be a string of at most 240 characters")
    return value


def prompt(role: str, speed: float, course: str) -> str:
    common = (
        "You are playing Blind Driver cooperatively with another agent. Maximize useful "
        "forward road progress while avoiding collisions and leaving the road. The game "
        f"runs continuously at {speed:g}% speed, including while you think. "
        "You see an unmodified full game window with its HUD. Your partner sees their own window. "
        "Keep track of the situation and prior messages. Older advice may be stale. "
        "You may send exactly one concise message to your partner per response. "
        "Return ONLY a JSON object with exactly these fields: "
        '{"hold":[],"tap":[],"hold_sim_seconds":1.0,"message":"..."}. '
        "hold is the complete set of keys to hold, replacing all previous held keys; [] releases them. "
        "tap presses and releases each listed key once. hold_sim_seconds must be 0.05–2.0. "
        "The controls expire after that many simulation seconds unless replaced. Expiry applies "
        "the driver's handbrake and releases navigator keys. Your message is at most 240 characters. "
        "Do not repeat toggle keys unless you intend another toggle. No pause or restart is available. "
    )
    common += (
        "This is the basic course: gentle bends and static rocks, no police, jumps, bridges, "
        "cliffs, lakes, or thorns. The car still takes physical damage. "
        if course == "basic" else
        "This is the normal course: forks, dead ends, police, damage, jumps, and timed bridges. "
    )
    if role == "driver":
        return common + (
            "You are DRIVER. Your vision is blurred; rely on your navigator and the dashboard. "
            "Allowed hold keys: W accelerate, S brake then reverse after stopping, A left, D right, "
            "SPACE handbrake. Allowed tap key: H headlights. Do not press opposite directions "
            "together. Reply with your action or a short request for information."
        )
    return common + (
        "You are NAVIGATOR. You see clearly but cannot drive. Give specific steering/braking "
        "instructions including when to straighten. Allowed hold key: B look back (release to "
        "look forward). Allowed tap keys: M toggle map, C toggle seat/chase camera. The map "
        "covers your road view and unfolds over 0.38 simulation seconds. Looking back folds it. "
        "Do not combine B and M. You must observe the map on a later screenshot before using it."
    )


class ScriptedAgent:
    """Explicit plumbing baseline, never described as an AI result."""

    def __init__(self, role: str):
        self.role = role
        self.turn = 0

    def decide(self, image: Path, observation: dict, messages: list[dict]) -> tuple[dict, dict]:
        self.turn += 1
        if self.role == "driver":
            result = {"hold": ["W"], "tap": [], "hold_sim_seconds": 2.0,
                      "message": "Scripted baseline: holding accelerator straight ahead."}
        else:
            # Exercise both the navigator's map and camera keys, then close them.
            taps = {1: ["M"], 2: ["M"], 3: ["C"], 4: ["C"]}.get(self.turn, [])
            result = {"hold": [], "tap": taps, "hold_sim_seconds": 2.0,
                      "message": "Scripted capture check; toggling " + ", ".join(taps) if taps
                      else "Scripted baseline: no visual reasoning or steering advice."}
        return result, {"input_tokens": 0, "output_tokens": 0}


class CohereAgent:
    def __init__(self, role: str, model: str, key: str, system_prompt: str,
                 timeout: float, max_tokens: int, history_turns: int):
        self.role, self.model, self.key = role, model, key
        self.system_prompt = system_prompt
        self.timeout, self.max_tokens = timeout, max_tokens
        self.history_turns = history_turns
        self.history: list[dict] = []

    def decide(self, image: Path, observation: dict, messages: list[dict]) -> tuple[dict, dict]:
        # No metric dictionary is accepted here: caller constructs this small view.
        context = json.dumps({"observation": observation, "partner_messages": messages}, ensure_ascii=False)
        encoded = base64.b64encode(image.read_bytes()).decode("ascii")
        current = {"role": "user", "content": [
            {"type": "text", "text": context},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + encoded}},
        ]}
        body = {"model": self.model, "messages": [
            {"role": "system", "content": self.system_prompt}, *self.history, current
        ], "max_tokens": self.max_tokens, "temperature": 0.2}
        if self.model.startswith("command-a-plus") or self.model.startswith("command-a-reasoning"):
            body["thinking"] = {"type": "disabled"}
        if self.model.startswith("command-a-plus"):
            body["response_format"] = {"type": "json_object", "schema": {
                "type": "object", "properties": {
                    "hold": {"type": "array", "items": {"type": "string", "enum": sorted(HELD_KEYS[self.role])}},
                    "tap": {"type": "array", "items": {"type": "string", "enum": sorted(TAP_KEYS[self.role])}},
                    "hold_sim_seconds": {"type": "number"}, "message": {"type": "string"},
                }, "required": ["hold", "tap", "hold_sim_seconds", "message"], "additionalProperties": False,
            }}
        # Vision-only models use JSON instructions; local validation applies to
        # every model. Tool calling is not required.
        request = urllib.request.Request(
            "https://api.cohere.com/v2/chat", data=json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                answer = json.load(response)
        except urllib.error.HTTPError as exc:
            # Never log request headers, the key, or echoed provider error bodies.
            raise RuntimeError(f"Cohere HTTP {exc.code}") from None
        content = "".join(part.get("text", "") for part in answer.get("message", {}).get("content", [])
                          if part.get("type") == "text")
        if content.startswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        units = answer.get("usage", {}).get("billed_units", answer.get("usage", {}).get("tokens", {}))
        usage = {"input_tokens": units.get("input_tokens", 0), "output_tokens": units.get("output_tokens", 0),
                 "response_id": answer.get("id"), "finish_reason": answer.get("finish_reason")}
        try:
            action = validate_action(json.loads(content), self.role)
        except (ValueError, TypeError) as exc:
            raise InvalidModelResponse(str(exc), usage, {"finish_reason": answer.get("finish_reason"),
                "content_types": [p.get("type") for p in answer.get("message", {}).get("content", [])],
                "text_preview": content[:300]}) from None
        # Retain role-local text and delivered dialogue, not an unbounded image history.
        self.history.extend([{"role": "user", "content": context},
                             {"role": "assistant", "content": json.dumps(action)}])
        self.history = self.history[-2 * self.history_turns:]
        return action, usage
