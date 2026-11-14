"""A single, read-only terminal timeline for both agents and the running game."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import time
import unicodedata
from .scoring import score_frame


def safe_text(value) -> str:
    # Model output is untrusted terminal text, not ANSI/control instructions.
    return "".join(c if not unicodedata.category(c).startswith("C") else " " for c in str(value))


class ConsoleMonitor:
    def __init__(self, directory: Path, manifest: dict, output=None):
        self.output = output or sys.stdout
        self.started = manifest["created_unix"]
        self.scoring = manifest.get("scoring")
        self.last_status = 0.0
        self.finished = False
        self.pending = None
        self.requests = self.tokens = self.errors = 0
        models = {role: manifest[role + "_model"] if manifest["provider"] != "scripted" else "SCRIPTED (no model calls)"
                  for role in ("driver", "navigator")}
        self.emit(f"\nBLIND DRIVER — LIVE AGENT TIMELINE\nRun: {directory}\n"
                  f"{manifest['provider']} | game speed {manifest['speed']:g}% | "
                  f"limit {manifest['sim_seconds']:g} simulation seconds\n"
                  f"DRIVER: {models['driver']}\nNAVIGATOR: {models['navigator']}\n"
                  "Messages appear after the game accepts the action. Waiting never pauses the game.\n")

    def emit(self, value):
        print(value, file=self.output, flush=True)

    def event(self, item):
        kind, role = item["event"], item.get("role", "").upper()
        if kind == "episode_started":
            self.started = item["unix_time"]
        elapsed = max(0, item["unix_time"] - self.started)
        sim = item.get("sim_time", item.get("observation", {}).get("sim_time"))
        prefix = f"[real {elapsed:6.1f}s" + (f" | sim {sim:6.2f}s" if sim is not None else "") + "]"
        detail = None
        if kind == "episode_started":
            detail = "RUNNING — navigator observes first"
        elif kind == "request":
            self.requests += 1
            self.pending = role
            detail = f"{role} observing frame {item['observation']['frame']} / waiting for model (request {item['request_id']})"
        elif kind == "response":
            self.pending = None
            usage = item.get("usage", {})
            self.tokens += usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
            action = item["action"]
            holding = (f"for {action['hold_sim_seconds']:g} sim s (legacy timed hold)"
                       if "hold_sim_seconds" in action else "until next instruction")
            if "steering_pulse_sim" in action:
                holding = f"steering pulse {action['steering_pulse_sim']:g} game s; other keys until next instruction"
            detail = (f"{role} answered in {item['latency_seconds']:.2f}s | "
                      f"hold={'+'.join(action['hold']) or 'none'} tap={'+'.join(action['tap']) or 'none'} "
                      f"{holding} | awaiting game acknowledgment")
        elif kind == "memory_request":
            self.requests += 1
            detail = f"{role} updating recap through turn {item['through_turn']} in background"
        elif kind == "memory_response":
            usage = item.get("usage", {})
            self.tokens += usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
            detail = f"{role} RECAP: {item['memory']['text']}"
        elif kind == "message":
            detail = f"{role} → {item['to'].upper()}: {item['message']}"
        elif kind == "action_ack" and not item.get("accepted"):
            detail = f"{role} ACTION REJECTED: {item.get('error', '')}"
        elif kind in {"request_error", "infrastructure_error", "recap_error", "memory_error"}:
            self.pending = None
            self.errors += 1
            usage = item.get("usage", {})
            self.tokens += usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
            detail = f"{role} ERROR: {item.get('error', kind)}"
        elif kind == "episode_finished":
            self.finished = True
            detail = (f"STOPPED: {item['reason']} | {item['requests']} requests | "
                      f"{item['input_tokens'] + item['output_tokens']} known tokens | "
                      f"usage {'complete' if item.get('usage_complete') else 'incomplete'} | rendering recap…")
        elif kind == "recap_ready":
            detail = f"RECAP READY: {item['path']}"
        if detail:
            self.emit(prefix + " " + safe_text(detail))

    def status(self, states, *, now=None, force=False):
        now = time.time() if now is None else now
        if not force and (self.finished or now - self.last_status < 5):
            return
        driver = states.get("driver", {})
        if not driver.get("active") and not force:
            return
        self.last_status = now
        keys = []
        for role in ("driver", "navigator"):
            row = states.get(role, {})
            held = "+".join(row.get("held", [])) or "released"
            label = " FALLBACK" if row.get("fallback") else ""
            age = now - row.get("unix_time", now)
            keys.append(f"{role}={held}{label}" + (f" STALE {age:.1f}s" if age > 3 else ""))
        self.emit(safe_text(
            f"[real {max(0, now-self.started):6.1f}s | sim {driver.get('sim_time', 0):6.2f}s] "
            f"STATUS {driver.get('speed_kmh', 0):5.1f} km/h | "
            f"progress {driver.get('forward_progress_m', 0):.1f} m | "
            f"score {score_frame(driver, self.scoring)['score']:.1f} | "
            f"hits {driver.get('impact_events', 0)} | " + " / ".join(keys) +
            f" | {self.pending + ' thinking' if self.pending else 'between requests'} | "
            f"{self.requests} requests / {self.tokens} known tokens / {self.errors} errors"))


class EventTail:
    """Leave an unfinished JSONL record unread until the writer completes it."""
    def __init__(self, path):
        self.path, self.offset = path, 0

    def read(self):
        if not self.path.exists():
            return []
        records = []
        with self.path.open("rb") as stream:
            stream.seek(self.offset)
            while line := stream.readline():
                if not line.endswith(b"\n"):
                    break
                self.offset = stream.tell()
                try:
                    records.append(json.loads(line))
                except (ValueError, UnicodeError):
                    continue
        return records


def watch(directory: Path, latest=False):
    from .run import read_json
    directory = directory.expanduser().resolve()
    print(f"Watching {directory} — Ctrl-C closes this viewer; it does not stop the game.", flush=True)
    selected = monitor = tail = None
    try:
        while True:
            if latest:
                candidates = sorted(directory.glob("*/manifest.json"), key=lambda p: p.parent.name)
                candidate = candidates[-1].parent if candidates else None
            else:
                candidate = directory
            if candidate and candidate != selected:
                manifest = read_json(candidate / "manifest.json")
                if manifest:
                    selected = candidate
                    monitor = ConsoleMonitor(selected, manifest)
                    tail = EventTail(selected / "events.jsonl")
            if monitor:
                for item in tail.read():
                    monitor.event(item)
                    if item["event"] == "recap_ready" and not latest:
                        return
                monitor.status({r: read_json(selected / r / "latest.json") for r in ("driver", "navigator")})
            time.sleep(.2)
    except KeyboardInterrupt:
        print("\nViewer closed. The run continues independently.")
