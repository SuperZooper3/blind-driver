"""One shared Godot simulation, two complete seat views, independent concurrent visual agents."""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time
import uuid

from .agents import CohereAgent, ScriptedAgent, PROMPT_REVISION, prompt
from .coordinator import AgentCoordinator
from .monitor import ConsoleMonitor
from .scoring import DEFAULT_SCORING

ROOT = Path(__file__).resolve().parents[2]
ROLES = ("navigator", "driver")


def prototype_number() -> int:
    return int(re.search(r"const PROTOTYPE\s*:=\s*(\d+)", (ROOT / "scripts/version.gd").read_text())[1])


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def find_godot(explicit: str | None = None) -> str:
    candidates = [explicit, os.environ.get("GODOT"), shutil.which("godot"), shutil.which("godot4"),
                  "/Applications/Godot.app/Contents/MacOS/Godot",
                  str(Path.home() / "Downloads/Godot.app/Contents/MacOS/Godot")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve())
    raise RuntimeError("Godot not found; pass --godot /path/to/Godot")


def read_key(env_file: Path) -> str:
    key = os.environ.get("COHERE_API_KEY", "")
    if not key and env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.strip().startswith("COHERE_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('\"\'')
                break
    if not key:
        raise RuntimeError(f"Set COHERE_API_KEY or add it to {env_file}. Use --provider scripted without a key.")
    return key


def prepare(godot: str) -> None:
    # Also catches compile errors before opening either window or making API calls.
    result = subprocess.run([godot, "--headless", "--path", str(ROOT), "--editor", "--import"],
                            capture_output=True, text=True, timeout=120)
    if result.returncode or "SCRIPT ERROR" in result.stdout + result.stderr:
        raise RuntimeError("Godot import failed:\n" + (result.stdout + result.stderr)[-6000:])


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def run_episode(args, *, prepared: bool = False) -> Path:
    if not shutil.which("ffmpeg"):
        raise RuntimeError("Install FFmpeg before recording a run")
    godot = find_godot(args.godot)
    key = read_key(Path(args.env_file).expanduser()) if args.provider == "cohere" else ""
    output_root = Path(args.output).expanduser().resolve()
    if ROOT.is_relative_to(output_root):
        raise ValueError("The recording directory must not contain the game project")
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / ".gdignore").touch()
    if not prepared:
        prepare(godot)
    run_id = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + uuid.uuid4().hex[:6]
    directory = output_root / run_id
    directory.mkdir(parents=True, mode=0o700)
    (directory / ".gdignore").touch()
    manifest = {**vars(args), "run_id": run_id, "created_unix": time.time(), "schema_version": 8,
                "prompt_revision": PROMPT_REVISION,
                "scheduling_policy": "independent_seats_v1",
                "prototype": prototype_number(),
                "communication_policy": "optional speech; last 8 delivered messages with ages; own action acknowledgments",
                "hold_policy": "until_replaced",
                "scoring": DEFAULT_SCORING.copy(),
                "basic_course_version": "roadside_thorns_v2",
                "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "git_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
                "godot_version": subprocess.check_output([godot, "--version"], text=True).strip(),
                "capture": "one 2560x800 engine frame, two complete 1280x800 seat crops",
                "engine_mode": "shared_local",
                "history_policy": f"last {args.history_turns} own text turns + rolling recap; one current screenshot",
                "benchmark_label": args.label,
                "provider": args.provider}
    manifest.pop("func", None)
    source_files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
    source_hash = hashlib.sha256()
    for name in sorted(set(source_files)):
        path = ROOT / name
        if path.is_file() and path.suffix in {".gd", ".py", ".godot", ".tscn"}:
            source_hash.update(name.encode() + b"\0" + path.read_bytes())
    manifest["source_sha256"] = source_hash.hexdigest()
    manifest["thinking"] = "disabled for Cohere reasoning models"
    atomic_json(directory / "manifest.json", manifest)
    monitor = ConsoleMonitor(directory, manifest)
    processes, logs = {}, []
    sequence = {role: 0 for role in ROLES}
    requests = input_tokens = output_tokens = usage_known_requests = 0
    errors = []
    reason = "infrastructure_error"
    latest = {}
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=2, thread_name_prefix="visual-agent")
    coordinator = None
    recap_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="agent-recap")
    heartbeat = 0.0
    events_file = (directory / "events.jsonl").open("w", encoding="utf-8")

    def log(event: str, **fields) -> dict:
        item = {"event": event, "unix_time": time.time(), **fields}
        events_file.write(json.dumps(item, ensure_ascii=False) + "\n")
        events_file.flush()
        monitor.event(item)
        return item

    def command(role: str, kind: str, **fields) -> int:
        sequence[role] += 1
        atomic_json(directory / role / "input.json", {"type": kind, "sequence": sequence[role], **fields})
        return sequence[role]

    def status(phase):
        atomic_json(directory / "runner.json", {"run_id": run_id, "pid": os.getpid(),
            "phase": phase, "heartbeat": time.time()})

    def stop_requested():
        control = read_json(directory / "control.json")
        return control.get("run_id") == run_id and control.get("action") == "stop"

    status("starting")
    try:
        for role in ROLES:
            seat_dir = directory / role
            seat_dir.mkdir()
            config = {"directory": str(seat_dir), "role": role, "seed": args.seed,
                      "course": args.course, "speed_percent": args.speed, "readable_ui": args.readable_ui,
                      "capture_fps": args.capture_fps, "max_sim_seconds": args.sim_seconds,
                      "max_action_age_sim": args.max_action_age_sim, "shared_screens": True,
                      "navigator_directory": str(directory / "navigator")}
            atomic_json(seat_dir / "config.json", config)
        env = {k: v for k, v in os.environ.items() if k not in {"COHERE_API_KEY", "BLIND_DRIVER_LAN_PORT"}}
        env.update(BLIND_DRIVER_AI_CONFIG=str(directory / "driver" / "config.json"),
                   BLIND_DRIVER_RECORDS_PATH=str(directory / "records.cfg"))
        output = (directory / "godot.log").open("w")
        logs.append(output)
        processes["game"] = subprocess.Popen([
            godot, "--path", str(ROOT), "--windowed", "--resolution", "1600x500",
            "--position", "10,70", "--max-fps", "60", "--audio-driver", "Dummy", "--", "--split",
        ], env=env, stdout=output, stderr=subprocess.STDOUT)
        log("process_started", role="shared_game", pid=processes["game"].pid)

        deadline = time.monotonic() + 45
        while True:
            status("starting")
            if stop_requested():
                raise KeyboardInterrupt
            latest = {role: read_json(directory / role / "latest.json") for role in ROLES}
            if any(p.poll() is not None for p in processes.values()):
                raise RuntimeError("A Godot process exited; inspect this run's godot.log")
            if all(v.get("connected") and v.get("image") for v in latest.values()):
                break
            if time.monotonic() > deadline:
                raise RuntimeError("Timed out waiting for two rendered seats in the shared game")
            time.sleep(0.1)

        agents = {}
        for role in ROLES:
            system = prompt(role, args.speed, args.course, args.readable_ui)
            extra_path = getattr(args, role + "_instructions", None)
            if extra_path:
                system += "\nAdditional experiment instructions:\n" + Path(extra_path).read_text(encoding="utf-8")
            (directory / role / "prompt.txt").write_text(system, encoding="utf-8")
            model = getattr(args, role + "_model")
            agents[role] = (ScriptedAgent(role) if args.provider == "scripted" else
                            CohereAgent(role, model, key, system, args.timeout, args.max_output_tokens, args.history_turns))
            manifest[role + "_prompt_sha256"] = hashlib.sha256(system.encode()).hexdigest()
        atomic_json(directory / "manifest.json", manifest)
        for role in ROLES:
            command(role, "start")
        start = time.monotonic()
        status("running")
        log("episode_started", speed=args.speed, seed=args.seed, provider=args.provider, scheduling_policy="independent_seats_v1")
        coordinator = AgentCoordinator(args, directory, agents, executor, recap_executor, log, command)
        while True:
            if stop_requested():
                reason = "operator_stop"
                break
            if time.monotonic() - heartbeat > 1:
                status("running")
                heartbeat = time.monotonic()
            latest = {role: read_json(directory / role / "latest.json") for role in ROLES}
            if any(p.poll() is not None for p in processes.values()):
                raise RuntimeError("Game exited during episode")
            driver = latest["driver"]
            monitor.status(latest)
            if driver.get("finished_reason"):
                reason = driver["finished_reason"]
                break
            if driver.get("sim_time", 0) >= args.sim_seconds:
                reason = "time_limit"
                break
            if time.monotonic() - start > args.sim_seconds / (args.speed / 100) + 30:
                reason = "wall_time_limit"
                break
            if any(time.time() - state.get("unix_time", 0) > 3 for state in latest.values()):
                reason = "capture_stalled"
                errors.append({"error": "A full-window capture stream stopped for over 3 seconds"})
                break
            if not all(v.get("active") for v in latest.values()):
                time.sleep(0.05)
                continue

            stop_reason = coordinator.step(latest)
            if stop_reason:
                reason = stop_reason
                break
            time.sleep(0.04)
    except KeyboardInterrupt:
        reason = "operator_stop"
    except Exception as exc:
        errors.append({"error": str(exc)[:500]})
        log("infrastructure_error", error=str(exc)[:500])
    finally:
        status("stopping")
        for role in ROLES:
            if (directory / role).is_dir():
                command(role, "stop", reason=reason)
        # Let each window record its final control state before shutting it down.
        time.sleep(0.4)
        for process in processes.values():
            stop_process(process)
        # Stop keys/game first, then account for already-issued calls. No late
        # response is ever applied to a stopped run. Provider timeout bounds this.
        if coordinator:
            coordinator.finish(latest)
            requests = coordinator.requests
            input_tokens, output_tokens = coordinator.input_tokens, coordinator.output_tokens
            usage_known_requests = coordinator.usage_known_requests
            errors.extend(coordinator.errors)
        executor.shutdown(wait=False, cancel_futures=True)
        recap_executor.shutdown(wait=False, cancel_futures=True)
        for output in logs:
            output.close()
        log("episode_finished", reason=reason, requests=requests, input_tokens=input_tokens,
            output_tokens=output_tokens, errors=errors, usage_complete=usage_known_requests == requests)
        events_file.close()
        atomic_json(directory / "result.json", {"reason": reason, "requests": requests,
                    "input_tokens": input_tokens, "output_tokens": output_tokens, "errors": errors,
                    "usage_complete": usage_known_requests == requests,
                    "requests_without_usage": requests - usage_known_requests,
                    "terminated": reason == "game_over", "truncated": reason != "game_over",
                    "valid_run": reason not in {"infrastructure_error", "provider_errors", "wall_time_limit", "capture_error", "capture_stalled"}})
    status("rendering")
    from .recap import build_recap
    events_file = (directory / "events.jsonl").open("a", encoding="utf-8")
    try:
        build_recap(directory, fps=args.video_fps, review_speed=args.review_speed)
        if (directory / "recap.mp4").is_file():
            log("recap_ready", path=str(directory / "recap.mp4"))
            if not args.keep_frames:
                from .cleanup import cleanup_frames
                log("frames_cleaned", **cleanup_frames(directory))
    except Exception as exc:
        log("recap_error", error=str(exc)[:500])
        raise
    finally:
        events_file.close()
        status("finished")
    if reason in {"infrastructure_error", "provider_errors", "capture_error", "capture_stalled"}:
        raise RuntimeError(f"Run ended with {reason}; diagnostic artifacts: {directory}")
    return directory
