"""Local run lifecycle: cooperative stop and restart with the same experiment settings."""
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

from .run import ROOT, atomic_json, read_json


def restart_command(directory):
    manifest = read_json(directory / "manifest.json")
    command = [sys.executable, "-m", "tools.ai_harness", "run", "--output", str(directory.parent)]
    fields = ("provider", "driver_model", "navigator_model", "driver_instructions", "navigator_instructions",
        "speed", "seed", "course", "sim_seconds", "capture_fps", "video_fps", "review_speed", "rpm",
        "max_requests", "max_tokens", "max_output_tokens", "history_turns", "memory_every", "timeout",
        "max_action_age_sim", "scripted_interval", "label", "godot")
    for field in fields:
        value = manifest.get(field)
        if value is not None:
            command.extend(["--" + field.replace("_", "-"), str(value)])
    command.append("--readable-ui" if manifest.get("readable_ui", True) else "--no-readable-ui")
    if manifest.get("keep_frames"):
        command.append("--keep-frames")
    return command


class RunController:
    def __init__(self):
        self.lock = threading.Lock()
        self.busy = False
        self.error = ""
        self.selected = None
        self.child = None

    def state(self, directory):
        runner = read_json(directory / "runner.json") if directory else {}
        result = read_json(directory / "result.json") if directory else {}
        manifest = read_json(directory / "manifest.json") if directory else {}
        phase = runner.get("phase", "finished" if result else "unknown")
        fresh = time.time() - runner.get("heartbeat", 0) < 6
        active = phase in {"starting", "running"} and fresh
        restartable = bool(manifest) and (active or phase == "finished")
        has_key = manifest.get("provider") != "cohere" or bool(os.environ.get("COHERE_API_KEY"))
        return {"busy": self.busy, "error": self.error, "phase": phase,
            "can_stop": active and not self.busy,
            "can_restart": restartable and has_key and not self.busy,
            "hint": "Restart uses the same models, speed, seed and budgets; it starts a new recording."
                    if has_key else "Start this viewer with COHERE_API_KEY in its environment to restart Cohere runs."}

    def request(self, action, directory, expected_run):
        with self.lock:
            if action not in {"stop", "restart"} or directory is None:
                raise ValueError("Unknown control or no run selected")
            if read_json(directory / "manifest.json").get("run_id") != expected_run:
                raise ValueError("The selected run changed; refresh before controlling it")
            state = self.state(directory)
            if not state["can_" + action]:
                raise ValueError("This run cannot " + action + " now. " + state["hint"])
            self.error = ""
            if state["can_stop"]:
                atomic_json(directory / "control.json", {"action": "stop", "run_id": expected_run})
            self.busy = True
            threading.Thread(target=self._complete, args=(action, directory), daemon=True).start()

    def _complete(self, action, directory):
        try:
            deadline = time.monotonic() + 180
            while True:
                runner = read_json(directory / "runner.json")
                if runner.get("phase") == "finished" or (not runner and (directory / "result.json").exists()):
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("Run did not finish stopping/rendering within 180 seconds; inspect its logs.")
                time.sleep(.2)
            if action == "restart":
                before = set(directory.parent.glob("*/manifest.json"))
                # Fixed executable/module, argument array, no shell or browser-supplied paths.
                with (directory / "restart.log").open("a") as output:
                    self.child = subprocess.Popen(restart_command(directory), cwd=ROOT,
                        env=os.environ.copy(), stdout=output, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    new = set(directory.parent.glob("*/manifest.json")) - before
                    if new:
                        self.selected = max(new, key=lambda p: p.parent.name).parent
                        break
                    if self.child.poll() is not None:
                        raise RuntimeError("Restart failed before recording; inspect restart.log in the previous run.")
                    time.sleep(.2)
                else:
                    raise RuntimeError("Restart is still starting; inspect restart.log before retrying.")
        except Exception as exc:
            self.error = str(exc)[:300]
        finally:
            self.busy = False
