"""Gemini variant: closed-set silent controls and a visual Hydrogen navigator.

Wire formats follow Google's Decisions REST API and generateContent API. No SDK,
automatic model fallback, provider-side chat history, or generated driver speech.
"""
from __future__ import annotations

import base64
import json
import math
import re
import urllib.error
import urllib.request
from urllib.parse import quote

from .agents import HELD_KEYS, TAP_KEYS, InvalidModelResponse, prompt, validate_action
from .driving_guidance import DRIVING_MECHANICS

DRIVER_MODEL = "gemini-decision-1"
NAVIGATOR_MODEL = "gemini-4-hydrogen"
PROMPT_REVISION = "gemini-one-way-v1"
API_ROOT = "https://generativelanguage.googleapis.com/v1beta/"

# A single joint choice prevents independently selected pedals/steering from
# contradicting each other. Each choice replaces the entire held-key set.
CONTROLS = {}
CRITERIA = {}
for pedal, pedal_keys, pedal_text in (
    ("coast", [], "release pedals"), ("accelerate", ["W"], "hold W to accelerate"),
    ("brake_reverse", ["S"], "hold S to brake, then reverse if stopped"),
):
    for steer, steer_keys, steer_text in (
        ("straight", [], "release A/D"), ("left", ["A"], "hold A for left steering"),
        ("right", ["D"], "hold D for right steering"),
    ):
        for handbrake in (False, True):
            name = pedal + "_" + steer + ("_handbrake" if handbrake else "")
            CONTROLS[name] = pedal_keys + steer_keys + (["SPACE"] if handbrake else [])
            CRITERIA[name] = pedal_text + "; " + steer_text + (
                "; hold SPACE for handbrake skid/parking." if handbrake else "; release SPACE.")


def gemini_prompt(role, speed, course, readable=True):
    if role == "driver":
        return (
            "Choose keyboard inputs for DRIVER in the Blind Driver video game. You are a silent "
            "decision controller: no speech, questions, prose, or working recap. Your view is blurred; "
            "follow the navigator's newest concrete instruction and visible HUD/captions. "
            f"Simulation runs continuously at {speed:g}% real-time speed during API calls. "
            "Timing and instruction ages are in simulation seconds unless labeled real. "
            "held_for_sim_seconds records continuous key-hold duration across repeated decisions. "
            "Use those durations, instruction ages and current evidence to release steering at the instructed point. "
            "Choose the complete held-key set for NOW; it persists until the next accepted decision. "
            "Wait with no throttle for the first navigation instruction. Release throttle and "
            "steering when advice is stale or uncertain. Never invent road geometry hidden by blur. "
            "S continues into reverse after stopping; SPACE is not the ordinary brake. "
            "Use current visible evidence to check whether instructions still apply. "
            + DRIVING_MECHANICS
        )
    # Keep course, controls, map interpretation and visual evidence rules from
    # the shared navigator prompt, replacing the conversational assumptions.
    text = prompt(role, speed, course, readable)
    for old, new in (
        ("Act like an attentive teammate: read the latest partner message, respond to requests, ",
         "Act like an attentive navigator: inspect the current image, "),
        ("Respond to the partner's latest question or correction before repeating earlier advice.",
         "Verify your previous instruction visually before repeating earlier advice."),
        ("Each turn: check the newest driver message and sound captions; inspect current ",
         "Each turn: check sound captions; inspect current "),
        ("Use a brief question when needed (e.g. 'Are we still blocked after reversing?'), and use the driver's answer.",
         "The driver is silent. Check movement and recovery yourself in the next screenshot."),
    ):
        text = text.replace(old, new)
    return text + (
        " This variant has ONE-WAY communication. The driver is a fast Decisions controller, "
        "never talks, never acknowledges verbally, and cannot answer questions. Do not ask it "
        "questions or wait for a reply. Proactively issue short actionable instructions with a "
        "duration in SIMULATION seconds or a visible release condition. Correct them using your "
        "next screenshot, HUD and sound captions. Do not assume acceptance means success. "
        "Your message is the driver's only clear-road guidance."
    )


class GeminiAPIError(RuntimeError):
    """Safe metadata only: never expose a provider body, request, or credential."""
    def __init__(self, status, retry_after=0, quotas=(), permanent=False):
        self.status = status
        self.retry_after = retry_after
        self.quotas = list(quotas)
        self.permanent = permanent
        hint = ("Check project quota/billing in AI Studio." if status == 429 else
                "Check key permissions/model access." if status in (400, 401, 403, 404) else
                "Retry after the provider recovers.")
        super().__init__(f"Gemini HTTP {status}. {hint}")


def api_error(status, payload, headers):
    retry = 0.0
    try:
        retry = max(0, float(headers.get("Retry-After", 0)))
    except (TypeError, ValueError):
        pass
    quotas = []
    for detail in payload.get("error", {}).get("details", []):
        if detail.get("@type", "").endswith("RetryInfo"):
            match = re.fullmatch(r"([0-9.]+)s", str(detail.get("retryDelay", "")))
            if match:
                retry = max(retry, float(match[1]))
        if detail.get("@type", "").endswith("QuotaFailure"):
            for violation in detail.get("violations", []):
                # Only known quota identifiers and numeric limits; no free text,
                # consumer/project identifiers, URLs, or echoed request data.
                quota = {}
                for field in ("quotaMetric", "quotaId"):
                    value = violation.get(field, "")
                    if re.fullmatch(r"[A-Za-z0-9_./-]{1,180}", str(value)):
                        quota[field] = value
                value = violation.get("quotaValue")
                if str(value).isdigit():
                    quota["quotaValue"] = int(value)
                if quota:
                    quotas.append(quota)
    permanent = status in (400, 401, 403, 404) or any(q.get("quotaValue") == 0 for q in quotas)
    return GeminiAPIError(status, max(60, retry) if status == 429 else retry, quotas, permanent)


class GeminiClient:
    def __init__(self, key, timeout):
        self.key, self.timeout = key, timeout

    def post(self, endpoint, body):
        request = urllib.request.Request(API_ROOT + endpoint, data=json.dumps(body).encode(),
            headers={"x-goog-api-key": self.key, "Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            try:
                payload = json.loads(exc.read())
            except (ValueError, OSError):
                payload = {}
            finally:
                exc.close()
            raise api_error(exc.code, payload, exc.headers) from None
        except (urllib.error.URLError, TimeoutError):
            raise RuntimeError("Gemini network request failed or timed out") from None


def token_usage(answer, decisions=False):
    data = answer.get("usage" if decisions else "usageMetadata", {})
    input_tokens = data.get("total_input_tokens" if decisions else "promptTokenCount")
    total = data.get("total_tokens" if decisions else "totalTokenCount")
    # totalTokenCount includes thinking; candidatesTokenCount alone does not.
    output = data.get("total_output_tokens") if decisions else (
        max(0, total - input_tokens) if total is not None and input_tokens is not None else None)
    known = input_tokens is not None and output is not None
    return {"input_tokens": input_tokens or 0, "output_tokens": output or 0, "known": known}


class GeminiDecisionAgent:
    supports_memory = False

    def __init__(self, role, model, key, system_prompt, timeout, max_tokens, history_turns):
        if role != "driver":
            raise ValueError("Decisions agent must occupy the driver seat")
        self.model, self.system_prompt = model, system_prompt
        self.client = GeminiClient(key, timeout)
        self.last_decision = None

    def decide(self, image, observation, messages):
        context = {k: v for k, v in observation.items() if k != "working_memory"}
        body = {"model": self.model, "input": [
            {"type": "text", "text": self.system_prompt + "\n" + json.dumps({
                "observation": context, "new_navigator_instructions": messages})},
            {"type": "image", "mime_type": "image/jpeg", "resolution": "medium",
             "data": base64.b64encode(image.read_bytes()).decode("ascii")},
        ], "questions": {
            "controls": {"type": "choice", "instructions":
                "Which complete combination of held keys best implements the current driving instruction now? "
                "Use timing, current view, latest navigator guidance, and the supplied driving mechanics.",
                "criteria": CRITERIA},
            "headlights": {"type": "choice", "instructions": "Should H be tapped once now? Avoid repeated toggles.",
                "criteria": {"unchanged": "Leave headlights unchanged (normal choice).",
                             "toggle": "Toggle headlights once when current visibility or explicit instruction requires it."}},
        }}
        answer = self.client.post("decisions", body)
        usage = token_usage(answer, decisions=True)
        results = answer.get("answers", {})
        try:
            for name, options in (("controls", CONTROLS), ("headlights", {"unchanged", "toggle"})):
                result = results[name]
                if result.get("type") != "choice" or result.get("choice") not in options:
                    raise ValueError("Invalid decision choice")
                confidence = result.get("confidence")
                if not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
                    raise ValueError("Invalid decision confidence")
            self.last_decision = {name: {k: results[name][k] for k in ("choice", "confidence")}
                                  for name in ("controls", "headlights")}
            return {"hold": list(CONTROLS[results["controls"]["choice"]]),
                    "tap": ["H"] if results["headlights"]["choice"] == "toggle" else [],
                    "message": ""}, usage
        except (KeyError, TypeError, ValueError):
            raise InvalidModelResponse("Missing or invalid Gemini decision", usage, {}) from None


class GeminiNavigatorAgent:
    supports_memory = True

    def __init__(self, role, model, key, system_prompt, timeout, max_tokens, history_turns):
        self.role, self.model, self.system_prompt = role, model, system_prompt
        self.max_tokens, self.history_turns = max_tokens, history_turns
        self.client = GeminiClient(key, timeout)
        self.history = []
        self.response_feedback = ""

    def generate(self, parts, *, schema=None, system=None):
        config = {"maxOutputTokens": self.max_tokens, "thinkingConfig": {"thinkingLevel": "low"}}
        if schema:
            config.update(responseMimeType="application/json", responseJsonSchema=schema)
        answer = self.client.post("models/" + quote(self.model, safe="-") + ":generateContent", {
            "systemInstruction": {"parts": [{"text": system or self.system_prompt}]},
            "contents": [{"role": "user", "parts": parts}], "generationConfig": config})
        candidates = answer.get("candidates", [])
        candidate = candidates[0] if candidates else {}
        text = "".join(part.get("text", "") for part in candidate.get("content", {}).get("parts", [])
                       if not part.get("thought"))
        usage = token_usage(answer)
        if candidate.get("finishReason") != "STOP" or not text.strip():
            raise InvalidModelResponse("Gemini navigator response blocked, truncated, or empty", usage, {})
        return text, usage

    def decide(self, image, observation, messages):
        schema = {"type": "object", "properties": {
            "hold": {"type": "array", "items": {"type": "string", "enum": sorted(HELD_KEYS[self.role])}},
            "tap": {"type": "array", "items": {"type": "string", "enum": sorted(TAP_KEYS[self.role])}},
            "message": {"type": "string", "maxLength": 240},
            "notes": {"type": "string", "maxLength": 600},
        }, "required": ["hold", "tap", "message", "notes"], "additionalProperties": False}
        text, usage = self.generate([
            {"text": json.dumps({"recent_own_turns": self.history, "observation": observation,
                                  "partner_messages": messages, "response_feedback": self.response_feedback})},
            {"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(image.read_bytes()).decode("ascii")}},
            {"text": "Inspect this current clear seat view. Direct the silent driver now; return only the action JSON."},
        ], schema=schema)
        try:
            action = validate_action(json.loads(text), self.role)
        except (ValueError, TypeError):
            self.response_feedback = "Previous output was invalid; no controls or speech were delivered. Return valid action JSON."
            raise InvalidModelResponse("Invalid Gemini navigator action", usage, {}) from None
        self.response_feedback = ""
        self.history.append({"observation": {k: v for k, v in observation.items()
                            if k not in {"working_memory", "coordination"}}, "action": action})
        self.history = self.history[-self.history_turns:]
        return action, usage

    def summarize(self, previous, turns):
        text, usage = self.generate([{"text": json.dumps({"previous": previous, "turns": turns})}],
            system="Summarize this navigator's factual observations, directions and unresolved maneuvers in under 900 characters. "
                   "The driver is silent. Distinguish instructions from visually verified outcomes; invent nothing.")
        return text[:900], usage
