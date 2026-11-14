"""Model boundary: screenshots, own action history, and delivered messages only."""
from __future__ import annotations

import base64
import json
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
    if not isinstance(value, dict) or not {"hold", "tap", "message"} <= set(value) or set(value) - {"hold", "tap", "message", "notes"}:
        raise ValueError("Expected hold, tap, message, and optional notes only")
    for field, allowed in (("hold", HELD_KEYS[role]), ("tap", TAP_KEYS[role])):
        keys = value[field]
        if not isinstance(keys, list) or any(not isinstance(k, str) or k not in allowed for k in keys):
            raise ValueError(f"Invalid {field} keys for {role}")
        if len(keys) != len(set(keys)):
            raise ValueError("Duplicate keys")
    held, tap = set(value["hold"]), set(value["tap"])
    if {"W", "S"} <= held or {"A", "D"} <= held or ("B" in held and "M" in tap):
        raise ValueError("Conflicting keys")
    if not isinstance(value["message"], str) or len(value["message"]) > 240:
        raise ValueError("Message must be a string of at most 240 characters")
    if not isinstance(value.get("notes", ""), str) or len(value.get("notes", "")) > 600:
        raise ValueError("Notes must be a string of at most 600 characters")
    return value


def prompt(role: str, speed: float, course: str, readable: bool = True) -> str:
    common = (
        "You are playing Blind Driver cooperatively with another agent. Maximize useful "
        "forward road progress while avoiding collisions and leaving the road. The game "
        f"runs continuously at {speed:g}% speed, including while you think. "
        "You see an unmodified full game window with its HUD. Your partner sees their own window. "
        "Keep track of the situation and prior messages. Older advice may be stale. "
        "You may send exactly one concise message to your partner per response. "
        "Return ONLY a JSON object with these fields: "
        '{"hold":[],"tap":[],"message":"...","notes":"..."}. '
        "notes is your own brief working record (at most 600 characters): observed facts, "
        "the decision you made, and uncertainties to check next time. Do not write a detailed "
        "reasoning transcript. Notes are retained for you, not sent to your partner. "
        "You receive recent conversation verbatim and a rolling recap of earlier turns. "
        "The recap may lag; its through_turn says how far it covers. Current evidence takes precedence. "
        "Each request contains ONLY the current screenshot. Sound captions are text equivalents "
        "of audible game events, with game timestamps. "
        "hold is the complete set of keys to hold, replacing all previous held keys; [] releases them. "
        "Held keys stay pressed throughout inference and your partner's turn until YOUR next valid "
        "response replaces them. There is no duration or automatic release/braking between responses. "
        "To keep a key held, include it again; to release it, omit it from hold. "
        "tap presses and releases each listed key once. Your message is at most 240 characters. "
        "Do not repeat toggle keys unless you intend another toggle. No pause or restart is available. "
    )
    common += ("The enlarged map is NORTH UP; its orange arrow and heading degrees show car "
               "orientation (0 north, 90 east). " if readable else
               "This is the original display: the map rotates with the car, with forward pointing up. ")
    common += (
        "This is the basic course: gentle bends and static rocks, no police, jumps, bridges, "
        "cliffs, or lakes. Roadside thorns start roughly 18 metres from the road center; "
        "they wear out tires, and losing all four tires to thorns ends this practice run. "
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
            result = {"hold": ["W"], "tap": [],
                      "message": "Scripted baseline: holding accelerator straight ahead."}
        else:
            # Exercise both the navigator's map and camera keys, then close them.
            taps = {1: ["M"], 2: ["M"], 3: ["C"], 4: ["C"]}.get(self.turn, [])
            result = {"hold": [], "tap": taps,
                      "message": "Scripted capture check; toggling " + ", ".join(taps) if taps
                      else "Scripted baseline: no visual reasoning or steering advice."}
        return result, {"input_tokens": 0, "output_tokens": 0}

    def summarize(self, previous: dict, turns: list[dict]) -> tuple[str, dict]:
        return (f"Scripted plumbing recap through turn {turns[-1]['turn']}; no visual reasoning.",
                {"input_tokens": 0, "output_tokens": 0})


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
        if self.model.startswith("c4ai-aya-vision"):
            # Aya's image replies can ignore instructions supplied only as a
            # system preamble. Put the same task/contract in the image turn too.
            current["content"][0]["text"] = self.system_prompt + "\nCurrent situation:\n" + context
            current["content"].append({"type": "text", "text":
                "Choose your keyboard action now. Return ONLY the JSON object with hold, tap, "
                "message, and notes. Do not describe the image outside that object."})
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
                    "message": {"type": "string"},
                    "notes": {"type": "string"},
                }, "required": ["hold", "tap", "message", "notes"], "additionalProperties": False,
            }}
        content, usage, answer = self._chat(body)
        try:
            action = validate_action(json.loads(content), self.role)
        except (ValueError, TypeError) as exc:
            raise InvalidModelResponse(str(exc), usage, {"finish_reason": answer.get("finish_reason"),
                "content_types": [p.get("type") for p in answer.get("message", {}).get("content", [])],
                "text_preview": content[:300]}) from None
        # Only current image is sent. Older conversation is text, including own notes.
        self.history.extend([{"role": "user", "content": context},
                             {"role": "assistant", "content": json.dumps(action)}])
        self.history = self.history[-2 * self.history_turns:]
        return action, usage

    def summarize(self, previous: dict, turns: list[dict]) -> tuple[str, dict]:
        # Pure snapshot operation: never mutates history while decide() is running.
        instruction = (f"You maintain the {self.role}'s short working memory in Blind Driver. "
            "Update the previous recap using only the supplied conversation and own notes. "
            "Preserve important observations, actions taken, partner instructions, uncertainties, "
            "and unresolved problems. Distinguish old from current observations using timestamps. "
            "Do not invent facts or new advice. Return a concise factual recap, at most 900 characters, "
            "not a detailed reasoning transcript. No image is provided for this bookkeeping task.")
        body = {"model": self.model, "messages": [{"role": "user", "content": instruction + "\n" +
            json.dumps({"previous_recap": previous, "turns": turns}, ensure_ascii=False)}],
            "max_tokens": min(300, self.max_tokens), "temperature": 0.2}
        if self.model.startswith(("command-a-plus", "command-a-reasoning")):
            body["thinking"] = {"type": "disabled"}
        content, usage, _ = self._chat(body)
        if not content.strip():
            raise InvalidModelResponse("Empty working recap", usage, {})
        return content[:900], usage

    def _chat(self, body: dict) -> tuple[str, dict, dict]:
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
        return content, usage, answer
