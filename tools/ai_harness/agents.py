"""Model boundary: screenshots, own action history, and delivered messages only."""
from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from pathlib import Path
from .driving_guidance import DRIVING_MECHANICS


HELD_KEYS = {"driver": {"W", "S", "A", "D", "SPACE"}, "navigator": {"B"}}
TAP_KEYS = {"driver": {"H"}, "navigator": {"M", "C"}}
DEFAULT_MODEL = "command-a-vision-07-2025"
PROMPT_REVISION = "cooperative-navigation-v5-concurrent"


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
        "You see your complete seat view and HUD. Your partner sees the other seat in the same game engine. "
        "You and your partner run independently and may think at the same time; do not wait for a partner turn. "
        "Each request includes the latest available image and chat; messages arriving while you think "
        "will appear in your next request. Message in_reply_to identifies the latest dialogue the speaker had seen. "
        "A reply may predate your newest instruction; verify it was understood before assuming it was acted on. "
        "Keep track of the situation and prior messages. Older advice may be stale. "
        "Act like an attentive teammate: read the latest partner message, respond to requests, "
        "and check whether your last instruction actually helped. You may send one concise "
        "message per response; use an empty string when there is nothing useful to communicate. "
        "Return ONLY a JSON object with these fields: "
        '{"hold":[],"tap":[],"message":"...","notes":"..."}. '
        "notes is your own brief working record (at most 600 characters): observed road/car "
        "alignment and motion, hazards, active maneuver, and what to check next. Record HUD "
        "speed/heading when readable so you can notice changes next turn; mark unknowns. "
        "Keep map-check narration and analysis in notes, never in message. Do not write a detailed "
        "reasoning transcript. Notes are retained for you, not sent to your partner. "
        "You receive recent conversation verbatim and a rolling recap of earlier turns. "
        "The recap may lag; its through_turn says how far it covers. Current evidence takes precedence. "
        "Each request contains ONLY the current screenshot. Sound captions are text equivalents "
        "of audible game events, with game timestamps. Compare current evidence with your own "
        "previous notes: a CRASH caption means an impact occurred, not necessarily a tree; "
        "a tire pop means a puncture. Falling speed, no scene/odometer movement despite "
        "acceleration, or an obstruction ahead calls for reassessment, not more acceleration. "
        "A past impact does not prove the car is still blocked; check current evidence. "
        "coordination.recent_dialogue contains actual delivered speech from BOTH seats, with "
        "ages. partner_messages contains newly delivered messages. A proposed action in your "
        "history is not proof of execution: last_action_result and held_keys confirm controls. "
        "Control acceptance is not proof that a maneuver succeeded. Read the new screenshot. "
        "Respond to the partner's latest question or correction before repeating earlier advice. "
        "Useful speech is a concrete instruction, hazard warning, question, answer, or brief "
        "acknowledgment of a changed maneuver. Avoid routine status broadcasts, descriptions of "
        "your own map checks, and repeated 'no obstacles' claims. Repeat an urgent warning if "
        "it is still needed or unacknowledged; otherwise send a correction, answer, or silence. "
        "hold is the complete set of keys to hold, replacing all previous held keys; [] releases them. "
        "Held keys stay pressed throughout both agents' independent inference until YOUR next valid "
        "response replaces them. There is no duration or automatic release/braking between responses. "
        "To keep a key held, include it again; to release it, omit it from hold. "
        "tap presses and releases each listed key once. Your message is at most 240 characters. "
        "Do not repeat toggle keys unless you intend another toggle. No pause or restart is available. "
    )
    common += ("The enlarged map is NORTH UP; its orange arrow and heading degrees show car "
               "orientation (0 north, 90 east, 180 south, 270 west). Screen-left on the map "
               "is west, NOT necessarily the driver's left. Compare the road's desired heading "
               "with the car arrow: a small clockwise change is a right turn, counterclockwise "
               "is left; wrap across 0/360. For example, facing 350 toward 10 means right. " if readable else
               "This is the original display: the map rotates with the car, with forward pointing up. ")
    common += (
        "This is the basic course: gentle bends and static rocks, no police, jumps, bridges, "
        "cliffs, or lakes. Roadside thorns start roughly 18 metres from the road center; "
        "they wear out tires, and losing all four tires to thorns ends this practice run. "
        if course == "basic" else
        "This is the normal course: forks, dead ends, police, damage, jumps, and timed bridges. "
    )
    common += DRIVING_MECHANICS
    if role == "driver":
        return common + (
            "You are DRIVER. Your vision is blurred; rely on your navigator and the dashboard. "
            "Allowed hold keys: W accelerate, S brake then reverse after stopping, A left, D right, "
            "SPACE handbrake. Allowed tap key: H headlights. Do not press opposite directions "
            "together. You cannot open the map; the navigator must interpret it for you. "
            "At the start, wait for the first concrete navigation advice before accelerating; ask for it if missing. "
            "Follow fresh, concrete navigator directions and briefly acknowledge changed "
            "maneuvers (e.g. 'Braking and turning left; tell me when to straighten.'). "
            "If advice is vague or stale, ask a specific question and ease off while uncertain. "
            "Do not hold W indefinitely just because an earlier road looked straight. "
            "Release A/D when aligned; held steering continues during BOTH agents' inference. "
            "On a crash or apparent stall, release throttle, report what you can actually see "
            "or hear, and ask which way is clear. S held after stopping reverses the car: "
            "do not describe sustained S as a stationary brake. Coordinate a short recovery "
            "and check its result next turn. Do not use SPACE for ordinary slowing."
        )
    return common + (
        "You are NAVIGATOR, the driver's eyes and active copilot. Your main job is to tell "
        "the driver HOW to drive right now. You see clearly but cannot drive; the driver "
        "cannot see your map or notes. Never tell the driver to 'check the map'. Interpret it "
        "yourself and communicate the resulting steering/braking direction. "
        "Each turn: check the newest driver message and sound captions; inspect current "
        "alignment, motion, visible obstacles and HUD; verify your previous instruction; "
        "then give the most urgent useful correction or answer. Current drift/obstacles take "
        "priority over distant route planning. A straight ROAD does not mean the CAR is "
        "aligned with it. If the road is to our left, guide us left toward it; don't just "
        "say 'straight' while we head into the forest. Use the road view to judge this. "
        "Directions are relative to the DRIVER facing forward, even in map/rear views. "
        "Give action + timing + a release condition: e.g. if the car is drifting right, "
        "'Ease off W; steer left gently now toward the road center. Release A when aligned.' "
        "If a rock blocks the left side and the right is clear: 'Slow down; pass the rock "
        "on its right, then straighten.' These are conditional examples, not facts about "
        "this frame. Do not invent obstacle types, exact distances, or a safe route. "
        "When alignment is restored, explicitly say 'Straighten now; release A/D.' "
        "Use a brief question when needed (e.g. 'Are we still blocked after reversing?'), "
        "and use the driver's answer. After an impact, call for releasing throttle/slowing, "
        "inspect the road view, then give one recovery step toward visible clear space. "
        "If blocked, confirm rear clearance with B before advising reverse; check the "
        "result and tell the driver when to stop reversing. Say when clearance is unknown. "
        "Allowed hold key: B look back (release to "
        "look forward). Allowed tap keys: M toggle map, C toggle seat/chase camera. The map "
        "covers your road view and unfolds over 0.38 simulation seconds. Looking back folds it. "
        "Do not combine B and M. view reports only your visible map/camera mode. Use the "
        "road view by default. Open M only to answer a route question, read it on a LATER "
        "screenshot, remember the next bend, then close M to watch the road. Never infer "
        "the newly opened map's contents from the previous road screenshot. If the map is "
        "opening, wait without another M; if open, extract a useful route instruction "
        "before closing it. Do not alternate M every turn or hide behind the map after "
        "a collision. A map omits small obstacles and cannot establish that the road is "
        "clear. Switch C to chase only if it helps resolve alignment/obstruction. "
        "Use repetition feedback to break unhelpful loops, not to suppress needed warnings."
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
        self.response_feedback = ""

    def decide(self, image: Path, observation: dict, messages: list[dict]) -> tuple[dict, dict]:
        # No metric dictionary is accepted here: caller constructs this small view.
        context = json.dumps({"observation": observation, "partner_messages": messages}, ensure_ascii=False)
        encoded = base64.b64encode(image.read_bytes()).decode("ascii")
        current = {"role": "user", "content": [
            {"type": "text", "text": context},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + encoded}},
        ]}
        # Live Command A+ and Aya image replies can ignore a system-only task,
        # even with JSON Schema enabled. Ground the role/contract in THIS image
        # turn as well. Do not parse a plausible action out of prose or reasoning.
        current["content"][0]["text"] = self.system_prompt + "\nCurrent situation:\n" + context
        if self.response_feedback:
            current["content"][0]["text"] += "\nResponse feedback: " + self.response_feedback
        task = (
            "You are the NAVIGATOR speaking TO THE DRIVER, not the driver asking for directions. "
            "This is your clear passenger view. Answer the driver's latest question; do not echo it. "
            "Tell the driver whether to accelerate, slow, turn, or straighten based on this view. "
            "If stopped on a visibly clear straight road, tell the driver to start with W. "
            "Your own hold/tap keys only control the view (B/M/C), never the car. "
            if self.role == "navigator" else
            "You are the DRIVER speaking TO THE NAVIGATOR. This is your blurred driver view. "
            "Follow fresh navigation advice and choose car keys that implement it. "
        )
        current["content"].append({"type": "text", "text":
            task + "Choose your keyboard action and useful partner speech now. "
            "The keys must implement the action you intend: [] releases all keys; it does NOT accelerate. "
            "Return ONLY the JSON object with hold, tap, message, and notes. "
            "Start with { and end with }. No prose or analysis outside the object."})
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
            self.response_feedback = ("Your previous output was rejected and no action/message was delivered. "
                f"Validation: {str(exc)[:160]}. Generate one concise valid JSON object, without a preamble.")
            raise InvalidModelResponse(str(exc), usage, {"finish_reason": answer.get("finish_reason"),
                "content_types": [p.get("type") for p in answer.get("message", {}).get("content", [])],
                "text_preview": content[:300]}) from None
        self.response_feedback = ""
        # Only current image is sent. Older conversation is text, including own notes.
        # Keep old observations/notes but do not duplicate rolling recaps and
        # dialogue windows inside every historical turn.
        historical = {k: v for k, v in observation.items() if k not in {"working_memory", "coordination"}}
        history_context = json.dumps({"observation": historical, "partner_messages": messages}, ensure_ascii=False)
        self.history.extend([{"role": "user", "content": history_context},
                             {"role": "assistant", "content": json.dumps(action)}])
        self.history = self.history[-2 * self.history_turns:]
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
