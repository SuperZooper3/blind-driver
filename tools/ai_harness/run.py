"""One shared Godot simulation, two complete seat views, alternating visual agents."""
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

from .agents import CohereAgent, InvalidModelResponse, ScriptedAgent, PROMPT_REVISION, prompt, validate_action
from .context import TeamContext
from .monitor import ConsoleMonitor
from .memory import RateBudget, WorkingMemory
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
    manifest = {**vars(args), "run_id": run_id, "created_unix": time.time(), "schema_version": 5,
                "prompt_revision": PROMPT_REVISION,
                "prototype": prototype_number(),
                "communication_policy": "optional speech; last 8 delivered messages with ages; own action acknowledgments",
                "hold_policy": "until_replaced_with_optional_key_pulses",
                "scoring": DEFAULT_SCORING.copy(),
                "basic_course_version": "roadside_thorns_v2",
                "git_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "git_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
                "godot_version": subprocess.check_output([godot, "--version"], text=True).strip(),
                "capture": "one 2560x800 engine frame, two complete 1280x800 seat crops",
                "engine_mode": "shared_local",
                "history_policy": f"last {args.history_turns} own factual notes; compact delivered dialogue; one current screenshot and visible HUD transcript",
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
    manifest["thinking"] = {"token_budget": args.thinking_tokens, "supported_models_only": True}
    atomic_json(directory / "manifest.json", manifest)
    monitor = ConsoleMonitor(directory, manifest)
    processes, logs = {}, []
    sequence = {role: 0 for role in ROLES}
    requests = input_tokens = output_tokens = usage_known_requests = 0
    errors = []
    reason = "infrastructure_error"
    latest = {}
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=3, thread_name_prefix="visual-agent")
    future = None
    request_context = {}
    memories = {role: WorkingMemory(args.memory_every) for role in ROLES}
    team = TeamContext()
    heard = {role: 0 for role in ROLES}
    heartbeat = 0.0
    rate = RateBudget(args.rpm if args.provider == "cohere" else 120 / args.scripted_interval)
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

    def collect_memory(role, *, ending=False):
        nonlocal input_tokens, output_tokens, usage_known_requests
        memory = memories[role]
        pending = memory.pending
        if not pending or (not ending and not pending["future"].done()):
            return
        try:
            recap, usage = memory.finish()
            input_tokens += int(usage.get("input_tokens", 0))
            output_tokens += int(usage.get("output_tokens", 0))
            usage_known_requests += 1
            log("memory_response", role=role, request_id=pending["request_id"], memory=recap,
                latency_seconds=time.monotonic() - pending["started"], usage=usage,
                sim_time=latest.get(role, {}).get("sim_time", 0))
        except Exception as exc:
            detail = {}
            if isinstance(exc, InvalidModelResponse):
                input_tokens += int(exc.usage.get("input_tokens", 0))
                output_tokens += int(exc.usage.get("output_tokens", 0))
                usage_known_requests += 1
                detail["usage"] = exc.usage
            log("memory_error", role=role, request_id=pending["request_id"],
                error=str(exc)[:250] if isinstance(exc, (ValueError, RuntimeError)) else type(exc).__name__, **detail)

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
                            CohereAgent(role, model, key, system, args.timeout, args.max_output_tokens, args.history_turns,
                                        thinking_tokens=args.thinking_tokens, image_width=args.image_width,
                                        image_detail=getattr(args, role + "_image_detail")))
            manifest[role + "_prompt_sha256"] = hashlib.sha256(system.encode()).hexdigest()
        atomic_json(directory / "manifest.json", manifest)
        for role in ROLES:
            command(role, "start")
        start = time.monotonic()
        status("running")
        log("episode_started", speed=args.speed, seed=args.seed, provider=args.provider)
        inbox = {role: [] for role in ROLES}
        turn = 0
        next_request = start
        next_observation_sim = 0.0
        request_context = {}
        pending_ack = None
        error_streak = {role: 0 for role in ROLES}
        while True:
            if stop_requested():
                reason = "operator_stop"
                break
            if time.monotonic() - heartbeat > 1:
                status("running")
                heartbeat = time.monotonic()
            for memory_role in ROLES:
                collect_memory(memory_role)
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
                role, seq, action, latency, context = pending_ack
                observed = context["observation"]
                state = latest[role]
                if state.get("sequence", -1) >= seq:
                    accepted = state.get("applied_sequence") == seq
                    log("action_ack", role=role, sequence=seq, accepted=accepted,
                        sim_time=state["sim_time"], held=state["held"], error=state.get("input_error", ""))
                    message = team.acknowledge(role, action, accepted=accepted,
                        sim_time=state["sim_time"], observation_sim=observed["sim_time"],
                        error=state.get("input_error", ""))
                    if accepted:
                        memories[role].record(observed, context["delivered"], action, state["sim_time"])
                        if message:
                            other = "driver" if role == "navigator" else "navigator"
                            log("message", **message, to=other, latency_seconds=latency,
                                hold=action["hold"], tap=action["tap"])
                            inbox[other].append(message)
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
                    log("response", role=role, request_id=request_context["request_id"], action=action,
                        latency_seconds=latency, usage=usage,
                        sim_time=latest[role]["sim_time"], observation_sim=request_context["observation"]["sim_time"])
                    seq = command(role, "keys", **{k: action[k] for k in ("hold", "tap", "steering_pulse_sim", "pedal_pulse_sim") if k in action},
                                  observation_sim=request_context["observation"]["sim_time"])
                    pending_ack = role, seq, action, latency, request_context
                    error_streak[role] = 0
                except Exception as exc:
                    error_streak[role] += 1
                    inbox[role][:0] = request_context["delivered"]
                    heard[role] = request_context["heard_before"]
                    details = {}
                    if isinstance(exc, InvalidModelResponse):
                        input_tokens += int(exc.usage.get("input_tokens", 0))
                        output_tokens += int(exc.usage.get("output_tokens", 0))
                        usage_known_requests += 1
                        details = {"usage": exc.usage, "details": exc.details}
                    message = str(exc)[:250] if isinstance(exc, (ValueError, RuntimeError)) else type(exc).__name__
                    errors.append({"role": role, "error": message})
                    log("request_error", role=role, request_id=request_context["request_id"], error=message, latency_seconds=latency, **details)
                    other = "driver" if role == "navigator" else "navigator"
                    inbox[other].append({"role": role, "message": "Partner response unavailable this exchange."})
                    turn += 1
                future = None
                if error_streak[role] >= 3:
                    reason = "provider_errors"
                    break

            if (not future and not pending_ack and time.monotonic() >= next_request
                    and driver.get("sim_time", 0) >= next_observation_sim):
                if requests >= args.max_requests:
                    reason = "request_budget"
                    break
                if input_tokens + output_tokens >= args.max_tokens:
                    reason = "token_budget"
                    break
                role = ROLES[turn % 2]
                other = "driver" if role == "navigator" else "navigator"
                recap_due = memories[other].due() and requests + 1 < args.max_requests
                recap_slot = recap_due and rate.take(2)
                if not recap_slot and not rate.take():
                    time.sleep(0.04)
                    continue
                state = latest[role]
                observation = team.observation(role, state, memories[role], heard[role])
                heard_before = heard[role]
                heard[role] = max([heard[role]] + [e["id"] for e in observation["sound_captions"]])
                delivered = inbox[role][:]
                inbox[role].clear()
                requests += 1
                request_context = {"role": role, "request_id": requests, "observation": observation, "delivered": delivered, "heard_before": heard_before, "started_monotonic": time.monotonic()}
                log("request", role=role, request_id=requests, observation=observation,
                    image=f"{role}/{state['image']}", partner_messages=delivered)
                future = executor.submit(agents[role].decide, directory / role / state["image"], observation, delivered)
                interval = args.scripted_interval if args.provider == "scripted" else 0
                next_request = time.monotonic() + interval
                next_observation_sim = state["sim_time"] + args.decision_interval_sim
                # Recap only when a second slot is available; never delay a
                # driving decision just to accumulate background recap quota.
                if recap_slot:
                    requests += 1
                    pending = memories[other].start(executor, agents[other], requests)
                    log("memory_request", role=other, request_id=requests,
                        through_turn=pending["through_turn"], concurrent_action=request_context["request_id"],
                        sim_time=latest[other]["sim_time"])
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
        if future:
            try:
                _, usage = future.result()
                input_tokens += int(usage.get("input_tokens", 0))
                output_tokens += int(usage.get("output_tokens", 0))
                usage_known_requests += 1
                log("response_discarded", role=request_context["role"], request_id=request_context["request_id"],
                    usage=usage, reason="episode_ended")
            except InvalidModelResponse as exc:
                input_tokens += int(exc.usage.get("input_tokens", 0))
                output_tokens += int(exc.usage.get("output_tokens", 0))
                usage_known_requests += 1
                log("response_discarded", role=request_context["role"], request_id=request_context["request_id"],
                    usage=exc.usage, reason="episode_ended_invalid_response")
            except Exception:
                pass
        for role in ROLES:
            collect_memory(role, ending=True)
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
