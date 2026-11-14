"""Launch two ordinary Godot windows and alternate visual agent requests."""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import uuid

from .agents import CohereAgent, InvalidModelResponse, ScriptedAgent, prompt, validate_action
from .monitor import ConsoleMonitor

ROOT = Path(__file__).resolve().parents[2]
ROLES = ("navigator", "driver")


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
    if not prepared:
        prepare(godot)
    run_id = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + uuid.uuid4().hex[:6]
    directory = Path(args.output).expanduser().resolve() / run_id
    directory.mkdir(parents=True, mode=0o700)
    manifest = {**vars(args), "run_id": run_id, "created_unix": time.time(), "schema_version": 2,
                "hold_policy": "until_replaced",
                "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "git_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
                "godot_version": subprocess.check_output([godot, "--version"], text=True).strip(),
                "capture": "two complete game windows; no crops or reconstructed HUD",
                "history_policy": f"last {args.history_turns} own text turns; current screenshot",
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
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    processes, logs = {}, []
    sequence = {role: 0 for role in ROLES}
    requests = input_tokens = output_tokens = usage_known_requests = 0
    errors = []
    reason = "infrastructure_error"
    latest = {}
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="visual-agent")
    future = None
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

    try:
        for role, flag, position in (("driver", "--host", "10,70"), ("navigator", "--join=127.0.0.1", "660,70")):
            seat_dir = directory / role
            seat_dir.mkdir()
            config = {"directory": str(seat_dir), "role": role, "seed": args.seed,
                      "course": args.course, "speed_percent": args.speed,
                      "capture_fps": args.capture_fps, "max_sim_seconds": args.sim_seconds,
                      "max_action_age_sim": args.max_action_age_sim}
            atomic_json(seat_dir / "config.json", config)
            env = {k: v for k, v in os.environ.items() if k != "COHERE_API_KEY"}
            env.update(BLIND_DRIVER_AI_CONFIG=str(seat_dir / "config.json"),
                       BLIND_DRIVER_RECORDS_PATH=str(seat_dir / "records.cfg"),
                       BLIND_DRIVER_LAN_PORT=str(port))
            output = (seat_dir / "godot.log").open("w")
            logs.append(output)
            processes[role] = subprocess.Popen([
                godot, "--path", str(ROOT), "--windowed", "--resolution", "1280x800",
                "--position", position, "--max-fps", "60", "--audio-driver", "Dummy", "--", flag,
            ], env=env, stdout=output, stderr=subprocess.STDOUT)
            log("process_started", role=role, pid=processes[role].pid)
            if role == "driver":
                time.sleep(0.5)

        deadline = time.monotonic() + 45
        while True:
            latest = {role: read_json(directory / role / "latest.json") for role in ROLES}
            if any(p.poll() is not None for p in processes.values()):
                raise RuntimeError("A Godot process exited; inspect this run's seat godot.log files")
            if all(v.get("connected") and v.get("image") for v in latest.values()):
                break
            if time.monotonic() > deadline:
                raise RuntimeError("Timed out waiting for two connected, rendered game windows")
            time.sleep(0.1)

        agents = {}
        for role in ROLES:
            system = prompt(role, args.speed, args.course)
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
        log("episode_started", speed=args.speed, seed=args.seed, provider=args.provider)
        inbox = {role: [] for role in ROLES}
        turn = 0
        next_request = start
        request_context = {}
        pending_ack = None
        error_streak = 0
        while True:
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

            if pending_ack:
                role, seq, action, latency, observed = pending_ack
                state = latest[role]
                if state.get("sequence", -1) >= seq:
                    accepted = state.get("applied_sequence") == seq
                    log("action_ack", role=role, sequence=seq, accepted=accepted,
                        sim_time=state["sim_time"], held=state["held"], error=state.get("input_error", ""))
                    if accepted:
                        other = "driver" if role == "navigator" else "navigator"
                        message = log("message", role=role, to=other, message=action["message"],
                                      sim_time=state["sim_time"], observation_sim=observed["sim_time"],
                                      latency_seconds=latency, hold=action["hold"], tap=action["tap"])
                        inbox[other].append({k: message[k] for k in ("role", "message", "sim_time", "observation_sim")})
                    pending_ack = None
                    turn += 1

            if future and future.done():
                role = request_context["role"]
                latency = time.monotonic() - request_context["started_monotonic"]
                try:
                    action, usage = future.result()
                    action = validate_action(action, role)
                    input_tokens += int(usage.get("input_tokens", 0))
                    output_tokens += int(usage.get("output_tokens", 0))
                    usage_known_requests += 1
                    log("response", role=role, request_id=requests, action=action,
                        latency_seconds=latency, usage=usage,
                        sim_time=latest[role]["sim_time"], observation_sim=request_context["observation"]["sim_time"])
                    seq = command(role, "keys", **{k: action[k] for k in ("hold", "tap")},
                                  observation_sim=request_context["observation"]["sim_time"])
                    pending_ack = role, seq, action, latency, request_context["observation"]
                    error_streak = 0
                except Exception as exc:
                    error_streak += 1
                    details = {}
                    if isinstance(exc, InvalidModelResponse):
                        input_tokens += int(exc.usage.get("input_tokens", 0))
                        output_tokens += int(exc.usage.get("output_tokens", 0))
                        usage_known_requests += 1
                        details = {"usage": exc.usage, "details": exc.details}
                    message = str(exc)[:250] if isinstance(exc, (ValueError, RuntimeError)) else type(exc).__name__
                    errors.append({"role": role, "error": message})
                    log("request_error", role=role, error=message, latency_seconds=latency, **details)
                    other = "driver" if role == "navigator" else "navigator"
                    inbox[other].append({"role": role, "message": "Partner response unavailable this exchange."})
                    turn += 1
                future = None
                if error_streak >= 3:
                    reason = "provider_errors"
                    break

            if not future and not pending_ack and time.monotonic() >= next_request:
                if requests >= args.max_requests:
                    reason = "request_budget"
                    break
                if input_tokens + output_tokens >= args.max_tokens:
                    reason = "token_budget"
                    break
                role = ROLES[turn % 2]
                state = latest[role]
                # Explicit whitelist: precise telemetry never enters model inputs.
                observation = {"frame": state["frame"], "sim_time": state["sim_time"],
                               "held_keys": state["held"], "input_feedback": state.get("input_error", "")}
                delivered = inbox[role][:]
                inbox[role].clear()
                requests += 1
                request_context = {"role": role, "observation": observation, "started_monotonic": time.monotonic()}
                log("request", role=role, request_id=requests, observation=observation,
                    image=f"{role}/{state['image']}", partner_messages=delivered)
                future = executor.submit(agents[role].decide, directory / role / state["image"], observation, delivered)
                interval = args.scripted_interval if args.provider == "scripted" else 60 / args.rpm
                next_request = time.monotonic() + interval
            time.sleep(0.04)
    except KeyboardInterrupt:
        reason = "operator_stop"
    except Exception as exc:
        errors.append({"error": str(exc)[:500]})
        log("infrastructure_error", error=str(exc)[:500])
    finally:
        for role in processes:
            command(role, "stop", reason=reason)
        # Let each window record its final control state before shutting it down.
        time.sleep(0.4)
        for process in processes.values():
            stop_process(process)
        executor.shutdown(wait=False, cancel_futures=True)
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
    from .recap import build_recap
    events_file = (directory / "events.jsonl").open("a", encoding="utf-8")
    try:
        build_recap(directory, fps=args.video_fps, review_speed=args.review_speed)
        if (directory / "recap.mp4").is_file():
            log("recap_ready", path=str(directory / "recap.mp4"))
    except Exception as exc:
        log("recap_error", error=str(exc)[:500])
        raise
    finally:
        events_file.close()
    if reason in {"infrastructure_error", "provider_errors", "capture_error", "capture_stalled"}:
        raise RuntimeError(f"Run ended with {reason}; diagnostic artifacts: {directory}")
    return directory
