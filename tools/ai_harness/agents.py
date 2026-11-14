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
DEFAULT_MODEL = "command-a-vision-07-2025"
PROMPT_REVISION = "grounded-copilot-v4"

from .prompts import prompt, current_task


class InvalidModelResponse(ValueError):
    def __init__(self, message, usage, details):
        super().__init__(message)
        self.usage, self.details = usage, details


def validate_action(value: object, role: str) -> dict:
    if not isinstance(value, dict) or not {"hold", "tap", "message"} <= set(value) or set(value) - {"hold", "tap", "message", "notes", "steering_pulse_sim"}:
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
    if "steering_pulse_sim" in value:
        pulse = value["steering_pulse_sim"]
        if (role != "driver" or not held.intersection({"A", "D"}) or isinstance(pulse, bool)
                or not isinstance(pulse, (float, int)) or not math.isfinite(pulse) or not .05 <= pulse <= 1):
            raise ValueError("steering_pulse_sim requires driver A/D and 0.05–1 game seconds")
    return value


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
        self.response_feedback = ""

    def decide(self, image: Path, observation: dict, messages: list[dict]) -> tuple[dict, dict]:
        # No metric dictionary is accepted here: caller constructs this small view.
        situation = {k: v for k, v in observation.items() if k not in {"coordination", "working_memory", "frame", "input_feedback", "own_turn"}}
        situation["sim_time"] = round(situation.get("sim_time", 0), 2)
        coordination = observation.get("coordination", {})
        # Keep only fresh conversational context, without duplicate nested
        # observations, messages, assistant answers or recaps on every turn.
        situation["dialogue"] = [{"who": m["role"], "said": m["message"],
            "age": round(m.get("age_sim_seconds", 0), 1)}
            for m in coordination.get("recent_dialogue", [])[-4:]]
        if messages:
            situation["new_partner_message"] = messages[-1]["message"]
        if observation.get("working_memory", {}).get("text"):
            situation["earlier_recap"] = observation["working_memory"]
        repeats = coordination.get("consecutive_identical_messages", 0)
        if repeats >= 2:
            situation["reassessment_required"] = f"You repeated the same message {repeats} times. Inspect current HUD/image, change view if uncertain, and give a concrete next step or silence."
        result = coordination.get("last_action_result")
        if result and not result.get("accepted"):
            situation["rejected_action"] = result
        context = json.dumps(situation, ensure_ascii=False, separators=(",", ":"))
        encoded = base64.b64encode(image.read_bytes()).decode("ascii")
        current = {"role": "user", "content": [
            {"type": "text", "text": context},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + encoded}},
        ]}
        # A fresh task, with bounded factual records, avoids training the next
        # response to repeat a long run of previous assistant answers.
        current["content"][0]["text"] = self.system_prompt + "\nCurrent situation:\n" + context
        if self.history:
            current["content"][0]["text"] += "\nEarlier own observations (may be stale): " + json.dumps(self.history, ensure_ascii=False)
        if self.response_feedback:
            current["content"][0]["text"] += "\nResponse feedback: " + self.response_feedback
        current["content"].append({"type": "text", "text":
            ("NAVIGATOR controls ONLY the view: hold must be [] or [\"B\"], tap only M/C. "
             "Put car steering/braking instructions in message to DRIVER. You cannot press W/S/A/D. "
             if self.role == "navigator" else "DRIVER chooses W/S/A/D/SPACE in hold, optional H in tap. ") +
            "Inspect THIS image and HUD now. Return ONLY the JSON object. "
            "Put fresh observed facts in notes before choosing keys and any useful message. " + current_task(self.role, observation)})
        body = {"model": self.model, "messages": [current],
                "max_tokens": self.max_tokens, "temperature": 0.2}
        if self.model.startswith("command-a-plus") or self.model.startswith("command-a-reasoning"):
            body["thinking"] = {"type": "disabled"}
        if self.model.startswith("command-a-plus"):
            body["response_format"] = {"type": "json_object", "schema": {
                "type": "object", "properties": {
                    "hold": {"type": "array", "items": {"type": "string", "enum": sorted(HELD_KEYS[self.role])}},
                    "tap": {"type": "array", "items": {"type": "string", "enum": sorted(TAP_KEYS[self.role])}},
                    "message": {"type": "string"},
                    "notes": {"type": "string"},
                    "steering_pulse_sim": {"type": "number"},
                }, "required": ["hold", "tap", "message", "notes"], "additionalProperties": False,
            }}
        content, usage, answer = self._chat(body)
        try:
            action = validate_action(json.loads(content), self.role)
        except (ValueError, TypeError) as exc:
            self.response_feedback = ("Your previous output was rejected and no action/message was delivered. "
                f"Validation: {str(exc)[:160]}. Generate one concise valid JSON object, without a preamble.")
            raise InvalidModelResponse(str(exc), usage, {"finish_reason": answer.get("finish_reason"),
                "content_types": [p.get("type") for p in answer.get("message", {}).get("content", [])],
                "text_preview": content[:300]}) from None
        self.response_feedback = ""
        # Retain observations, not a repetitive assistant-message transcript.
        # Delivered speech and accepted keys live in TeamContext; do not duplicate them.
        self.history.append({"at": round(observation.get("sim_time", 0), 2),
                             "view": observation.get("view", {}), "notes": action.get("notes", "")})
        self.history = self.history[-self.history_turns:]
        return action, usage

    def summarize(self, previous: dict, turns: list[dict]) -> tuple[str, dict]:
        # Pure snapshot operation: never mutates history while decide() is running.
        instruction = (f"You maintain the {self.role}'s short working memory in Blind Driver. "
            "Update the previous recap using only the supplied conversation and own notes. "
            "Use compact labeled items: observed situation with timestamp; last instruction and "
            "driver acknowledgment; active maneuver/release condition; hazards or unresolved "
            "questions. Preserve collisions, off-road/stalled observations, and whether recovery "
            "was verified. Summarize repetition once instead of listing every turn. "
            "Distinguish speech, accepted controls, and observed outcomes: 'turn left' is advice, "
            "not proof we turned; repeated 'clear' claims do not prove safe progress. "
            "Never turn missing observations into 'no problems'. Keep uncertainties explicit. "
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
