"""Local lifecycle: new runs use defaults; repeats preserve recorded settings."""
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

from .run import ROOT, atomic_json, read_json, read_key


def restart_command(directory, env_file=None):
    manifest = read_json(directory / "manifest.json")
    command = [sys.executable, "-m", "tools.ai_harness", "run", "--output", str(directory.parent)]
    fields = ("provider", "driver_model", "navigator_model", "driver_instructions", "navigator_instructions",
        "speed", "seed", "course", "sim_seconds", "capture_fps", "video_fps", "review_speed", "rpm",
        "max_requests", "max_tokens", "max_output_tokens", "history_turns", "memory_every", "timeout",
        "max_action_age_sim", "scripted_interval", "decision_interval_sim", "thinking_tokens", "image_width", "driver_image_detail", "navigator_image_detail", "label", "godot")
    for field in fields:
        value = manifest.get(field)
        if value is not None:
            command.extend(["--" + field.replace("_", "-"), str(value)])
    for field, legacy in (("thinking_tokens", 0), ("image_width", 1280), ("decision_interval_sim", 0), ("driver_image_detail", "auto"), ("navigator_image_detail", "auto")):
        if field not in manifest:
            command.extend(["--" + field.replace("_", "-"), str(legacy)])
    command.append("--readable-ui" if manifest.get("readable_ui", True) else "--no-readable-ui")
    command.append("--visual-road-tool" if manifest.get("visual_road_tool", False) else "--no-visual-road-tool")
    if manifest.get("keep_frames"):
        command.append("--keep-frames")
    if env_file is not None:
        command.extend(["--env-file", str(env_file)])
    return command


def new_run_command(output_root, env_file):
    # Leave model, prompt, speed and budgets to the CURRENT CLI defaults.
    return [sys.executable, "-m", "tools.ai_harness", "run", "--provider", "cohere",
            "--output", str(output_root), "--env-file", str(env_file)]


class RunController:
    def __init__(self, output_root=None, env_file=None):
        self.lock = threading.Lock()
        self.busy = False
        self.error = ""
        self.selected = None
        self.child = None
        self.output_root = Path(output_root) if output_root is not None else ROOT / "runs"
        self.env_file = Path(env_file).expanduser().resolve() if env_file is not None else ROOT / ".env"

    def has_key(self):
        try:
            return bool(read_key(self.env_file))
        except (RuntimeError, OSError):
            return False

    def state(self, directory):
        runner = read_json(directory / "runner.json") if directory else {}
        result = read_json(directory / "result.json") if directory else {}
        manifest = read_json(directory / "manifest.json") if directory else {}
        phase = runner.get("phase", "finished" if result else "unknown")
        fresh = time.time() - runner.get("heartbeat", 0) < 6
        active = phase in {"starting", "running"} and fresh
        restartable = bool(manifest) and (active or phase == "finished")
        cohere_key = self.has_key()
        has_key = manifest.get("provider") != "cohere" or cohere_key
        return {"busy": self.busy, "error": self.error, "phase": phase,
            "can_stop": active and not self.busy,
            "can_restart": restartable and has_key and not self.busy,
            "can_new": (directory is None or restartable) and cohere_key and not self.busy,
            "hint": "New run uses current defaults. Repeat saved run keeps its models, speed and limits."
                    if cohere_key else "Add COHERE_API_KEY to the server's .env file or environment to start AI runs."}

    def request(self, action, directory, expected_run):
        with self.lock:
            if action not in {"stop", "restart", "new"} or (directory is None and action != "new"):
                raise ValueError("Unknown control or no run selected")
            current_run = read_json(directory / "manifest.json").get("run_id") if directory else ""
            if current_run != expected_run:
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
            while directory is not None:
                runner = read_json(directory / "runner.json")
                if runner.get("phase") == "finished" or (not runner and (directory / "result.json").exists()):
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("Run did not finish stopping/rendering within 180 seconds; inspect its logs.")
                time.sleep(.2)
            if action in {"restart", "new"}:
                output_root = directory.parent if directory else self.output_root
                output_root.mkdir(parents=True, exist_ok=True)
                before = set(output_root.glob("*/manifest.json"))
                command = (restart_command(directory, self.env_file) if action == "restart"
                           else new_run_command(output_root, self.env_file))
                log_path = directory / "restart.log" if directory else output_root / "launch.log"
                # Fixed executable/module, argument array, no shell or browser-supplied paths.
                # Child reads the configured .env afresh; no key in argv or manifests.
                with log_path.open("a") as output:
                    self.child = subprocess.Popen(command, cwd=ROOT,
                        env=os.environ.copy(), stdout=output, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    new = set(output_root.glob("*/manifest.json")) - before
                    if new:
                        self.selected = max(new, key=lambda p: p.parent.name).parent
                        break
                    if self.child.poll() is not None:
                        raise RuntimeError(f"Run failed before recording; inspect {log_path.name} in the recording folder.")
                    time.sleep(.2)
                else:
                    raise RuntimeError(f"Run is still starting; inspect {log_path.name} before retrying.")
        except Exception as exc:
            self.error = str(exc)[:300]
        finally:
            self.busy = False
