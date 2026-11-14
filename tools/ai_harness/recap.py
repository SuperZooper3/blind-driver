"""Offline composition: two full screens, actual dialogue, controls and telemetry."""
from __future__ import annotations

from bisect import bisect_right
import csv
import hashlib
from functools import lru_cache
import json
import math
from pathlib import Path
import shutil
import statistics
import subprocess
import textwrap

from PIL import Image, ImageDraw, ImageFont, ImageOps
from .scoring import DEFAULT_SCORING, score_frame

WIDTH, HEIGHT = 1920, 1080
BG, PANEL, INK, MUTED = "#101e22", "#1c3036", "#edf4ed", "#a8b9bc"
MINT, GOLD, RED = "#85d9bf", "#efc77d", "#ef987e"


def json_lines(path: Path) -> list[dict]:
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            continue  # A crash may leave a partial final record.
    return result


@lru_cache(maxsize=12)
def font(size: int):
    for name in ("/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default(size=size)


def line_chart(draw, box, rows, field, title, color=MINT, until=None):
    x, y, w, h = box
    draw.rounded_rectangle((x, y, x+w, y+h), 10, fill=PANEL)
    draw.text((x+16, y+10), title, font=font(20), fill=INK)
    rows = [r for r in rows if r.get("active") and (until is None or r["unix_time"] <= until)]
    if len(rows) < 2:
        return
    times = [r["sim_time"] for r in rows]
    values = [float(r.get(field, 0)) for r in rows]
    xmax = max(1.0, max(times))
    ymin, ymax = min(0.0, min(values)), max(1.0, max(values))
    left, top, right, bottom = x+52, y+48, x+w-18, y+h-28
    draw.line((left, top, left, bottom, right, bottom), fill=MUTED, width=1)
    points = [(left+t/xmax*(right-left), bottom-(v-ymin)/(ymax-ymin)*(bottom-top)) for t, v in zip(times, values)]
    draw.line(points, fill=color, width=3)
    draw.text((x+8, top), f"{ymax:.0f}", font=font(15), fill=MUTED)
    if ymin < 0:
        draw.text((x+5, bottom-15), f"{ymin:.0f}", font=font(15), fill=MUTED)
    draw.text((right-110, bottom+5), f"{xmax:.1f} sim s", font=font(15), fill=MUTED)


def export_metrics(directory: Path, frames: list[dict], events: list[dict]) -> dict:
    manifest = json.loads((directory / "manifest.json").read_text())
    result = json.loads((directory / "result.json").read_text())
    scoring = manifest.get("scoring", DEFAULT_SCORING)
    frames = [{**row, **score_frame(row, scoring)} for row in frames]
    if frames:
        fields = sorted({k for row in frames for k in row})
        with (directory / "metrics.csv").open("w", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=fields)
            writer.writeheader()
            writer.writerows({k: json.dumps(v) if isinstance(v, (list, dict)) else v for k, v in row.items()} for row in frames)
    active = [r for r in frames if r.get("active")]
    final = frames[-1] if frames else {}
    latencies = [e["latency_seconds"] for e in events if e["event"] == "response"]
    memory_responses = [e for e in events if e["event"] == "memory_response"]
    sim_duration = max((r["sim_time"] for r in frames), default=0)
    conditions = {key: manifest.get(key) for key in (
        "source_sha256", "sim_seconds", "max_requests", "max_tokens", "rpm", "max_output_tokens",
        "history_turns", "timeout", "max_action_age_sim", "capture_fps", "thinking",
        "driver_prompt_sha256", "navigator_prompt_sha256", "hold_policy", "scoring",
        "basic_course_version", "readable_ui", "memory_every", "engine_mode", "decision_interval_sim", "thinking_tokens", "image_width")}
    conditions["scoring"] = scoring
    cohort = hashlib.sha256(json.dumps(conditions, sort_keys=True).encode()).hexdigest()[:12]
    fallback_time = 0.0
    for a, b in zip(active, active[1:]):
        if a.get("fallback"):
            fallback_time += max(0, b["sim_time"] - a["sim_time"])
    summary = {
        "run_id": manifest["run_id"], "provider": manifest["provider"], "label": manifest.get("label", ""),
        "driver_model": manifest["driver_model"], "navigator_model": manifest["navigator_model"],
        "speed_percent": manifest["speed"], "seed": manifest["seed"], "course": manifest["course"],
        "cohort": cohort, "conditions": conditions, "source_sha256": manifest.get("source_sha256"),
        "hold_policy": manifest.get("hold_policy", "timed_legacy"),
        "scoring": scoring, **score_frame(final, scoring),
        "sim_seconds": sim_duration, "distance_m": final.get("distance_m", 0),
        "forward_progress_m": max((r.get("forward_progress_m", 0) for r in frames), default=0),
        "max_speed_kmh": max((r.get("speed_kmh", 0) for r in frames), default=0),
        "offroad_sim_seconds": final.get("offroad_sim_seconds", 0),
        "impact_events": final.get("impact_events", 0), "impact_total": final.get("impact_total", 0),
        "part_health": final.get("part_health", []), "crash_reason": final.get("crash_reason", ""),
        "fallback_sim_seconds": fallback_time,
        "latency_p50_seconds": statistics.median(latencies) if latencies else None,
        "latency_p95_seconds": sorted(latencies)[max(0, math.ceil(.95*len(latencies))-1)] if latencies else None,
        "capture_ms_mean": statistics.mean(r["capture_ms"] for r in frames) if frames else None,
        "driver_frames": len(frames),
        "memory_requests": sum(e["event"] == "memory_request" for e in events),
        "memory_completed": len(memory_responses),
        "memory_errors": sum(e["event"] == "memory_error" for e in events),
        "memory_tokens": sum(e.get("usage", {}).get("input_tokens", 0) + e.get("usage", {}).get("output_tokens", 0) for e in memory_responses),
        "memory_latency_mean_seconds": statistics.mean(e["latency_seconds"] for e in memory_responses) if memory_responses else None,
        "max_capture_gap_seconds": max((b["unix_time"]-a["unix_time"] for a,b in zip(active, active[1:])), default=0),
        "cost_usd": None,  # Unknown unless pricing is explicitly configured; never pretend free.
        **result,
    }
    transcript = []
    starts = [e["unix_time"] for e in events if e["event"] == "episode_started"]
    start = starts[0] if starts else 0
    endings = [e["unix_time"] for e in events if e["event"] == "episode_finished"]
    summary["orchestration_real_seconds"] = endings[-1]-start if starts and endings else None
    game_events = json_lines(directory / "driver" / "input_events.jsonl")
    game_starts = [e["unix_time"] for e in game_events if e["event"] == "started"]
    game_ends = [e["unix_time"] for e in game_events if e["event"] == "finished"]
    summary["real_seconds"] = game_ends[0]-game_starts[0] if game_starts and game_ends else summary["orchestration_real_seconds"]
    summary["effective_speed_percent"] = 100*sim_duration/summary["real_seconds"] if summary["real_seconds"] else None
    summary["applied_actions"] = sum(e["event"] == "action_ack" and e.get("accepted", False) for e in events)
    summary["invalid_responses"] = sum(e["event"] == "request_error" for e in events)
    ages = [max(0, e["sim_time"]-e["observation_sim"]) for e in events if e["event"] == "message"]
    summary["observation_age_sim_p50"] = statistics.median(ages) if ages else None
    summary["observation_age_sim_max"] = max(ages) if ages else None
    (directory / "summary.json").write_text(json.dumps(summary, indent=2))
    for event in events:
        if event["event"] == "message":
            transcript.append(f"[{event['sim_time']:.2f}s sim / {event['unix_time']-start:.2f}s real] "
                              f"{event['role']} → {event['to']}: {event['message']}")
    (directory / "transcript.txt").write_text("\n".join(transcript), encoding="utf-8")
    chart = Image.new("RGB", (1600, 1160), BG)
    draw = ImageDraw.Draw(chart)
    draw.text((25, 16), f"{manifest['provider'].upper()} · {manifest['speed']:g}% speed · seed {manifest['seed']}", font=font(28), fill=INK)
    for box, field, title, color in (
        ((20, 70, 770, 340), "speed_kmh", "Speed · km/h", MINT),
        ((810, 70, 770, 340), "forward_progress_m", "New forward progress · m", GOLD),
        ((20, 430, 770, 340), "road_distance_m", "Distance from road center · m", RED),
        ((810, 430, 770, 340), "distance_m", "Odometer · m (includes backtracking)", MINT),
        ((20, 790, 770, 340), "score", "Safety-adjusted score · points", GOLD),
        ((810, 790, 770, 340), "penalty_total", "Accumulated penalties · points", RED),
    ):
        line_chart(draw, box, frames, field, title, color)
    chart.save(directory / "metrics.png")
    return summary


def simulation_timeline(rows: list[dict]):
    """Map a normal-speed video second to the recorded simulation's wall time."""
    sim_times = [r["sim_time"] for r in rows]
    def wall_for_sim(target: float):
        index = max(0, bisect_right(sim_times, target)-1)
        a = rows[index]
        b = rows[min(index+1, len(rows)-1)]
        span = b["sim_time"] - a["sim_time"]
        weight = max(0, min(1, (target-a["sim_time"])/span)) if span > 0 else 0
        return a["unix_time"] + weight*(b["unix_time"]-a["unix_time"])
    return max(sim_times, default=0), wall_for_sim


def build_recap(directory: Path, fps: int = 15, review_speed: float | None = None) -> dict:
    directory = Path(directory).resolve()
    # Validate before opening FFmpeg with overwrite enabled: an attempted rebuild
    # after cleanup must never truncate the only remaining video.
    for role in ("driver", "navigator"):
        for frame in json_lines(directory / role / "frames.jsonl"):
            if frame.get("image") and not (directory / role / frame["image"]).is_file():
                raise ValueError("Raw screenshots were cleaned or are missing; the saved recap is unchanged. Use --keep-frames for rebuilds.")
    (directory / "recap_settings.json").write_text(json.dumps({"video_fps": fps,
        "review_speed": review_speed, "playback_mode": "normal_game_speed" if review_speed is None else "wall_clock_multiplier",
        "simulation_replay": "measured driver simulation clock",
        "resolution": [WIDTH, HEIGHT]}, indent=2))
    manifest = json.loads((directory / "manifest.json").read_text())
    events = json_lines(directory / "events.jsonl")
    seats = {role: json_lines(directory / role / "frames.jsonl") for role in ("driver", "navigator")}
    seats["driver"] = [{**row, **score_frame(row, manifest.get("scoring"))} for row in seats["driver"]]
    summary = export_metrics(directory, seats["driver"], events)
    if not all(seats.values()):
        return summary
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg is required for the recap; frames/metrics are saved. Install it and run the recap command.")
    started = next((e["unix_time"] for e in events if e["event"] == "episode_started"),
                   max(seats[r][0]["unix_time"] for r in seats))
    ended = next((e["unix_time"] for e in reversed(events) if e["event"] == "episode_finished"),
                 max(seats[r][-1]["unix_time"] for r in seats))
    times = {r: [v["unix_time"] for v in rows] for r, rows in seats.items()}
    messages = [e for e in events if e["event"] == "message"]
    responses = [e for e in events if "usage" in e]

    @lru_cache(maxsize=8)
    def screenshot(role, name):
        with Image.open(directory / role / name) as image:
            # Fit the entire screenshot. Nothing, including the HUD, is cropped.
            return ImageOps.pad(image.convert("RGB"), (960, 600), color=BG)

    def render(wall: float, playback: str):
        canvas = Image.new("RGB", (WIDTH, HEIGHT), BG)
        draw = ImageDraw.Draw(canvas)
        selected = {r: seats[r][max(0, bisect_right(times[r], wall)-1)] for r in seats}
        driver = selected["driver"]
        for role, x, color in (("driver", 0, MINT), ("navigator", 960, GOLD)):
            row = selected[role]
            if row.get("image"):
                canvas.paste(screenshot(role, row["image"]), (x, 60))
            name = manifest[role + "_model"] if manifest["provider"] != "scripted" else "SCRIPTED BASELINE"
            draw.text((x+22, 5), f"{role.upper()}  /  {name}", font=font(24), fill=color)
            keys = "+".join(row.get("held", [])) or "released"
            age = max(0, wall-row["unix_time"])
            draw.text((x+22, 35), f"Keys: {keys}" + (" · expired / fallback" if row.get("fallback") else "")
                      + (f" · FRAME STALE {age:.1f}s" if age > 1 else ""), font=font(18), fill=color)
        draw.line((960, 0, 960, 660), fill=MUTED, width=2)
        stats = (f"SIM {driver['sim_time']:6.2f}s    REAL {max(0, wall-started):6.1f}s    "
                 f"GAME {manifest['speed']:g}%    {playback}    "
                 f"{driver.get('speed_kmh', 0):5.1f} km/h    "
                 f"PROGRESS {driver.get('forward_progress_m', 0):.1f} m    "
                 f"HITS {driver.get('impact_events', 0)}")
        draw.text((24, 680), stats, font=font(23), fill=INK)
        draw.text((24, 713), f"SCORE {driver['score']:.1f}    PENALTIES: hits −{driver['penalty_hits']:.0f}  /  off-road −{driver['penalty_offroad']:.1f}  /  damage −{driver['penalty_damage']:.1f}  /  failure −{driver['penalty_failure']:.0f}", font=font(20), fill=GOLD)
        draw.text((24, 746), "DELIVERED CONVERSATION", font=font(18), fill=MUTED)
        recent = [m for m in messages if m["unix_time"] <= wall][-3:]
        while sum(32 + max(1, len(textwrap.wrap(m["message"], 83)[:3]))*25 for m in recent) > 250:
            recent.pop(0)
        y = 775
        for msg in recent:
            color = GOLD if msg["role"] == "navigator" else MINT
            draw.text((24, y), f"{msg['role'].upper()}  {msg['sim_time']:.2f}s sim · {msg['latency_seconds']:.1f}s inference", font=font(18), fill=color)
            lines = textwrap.wrap(msg["message"], 83)[:3]
            draw.multiline_text((24, y+24), "\n".join(lines), font=font(21), fill=INK, spacing=3)
            y += 32 + max(1, len(lines))*25
        line_chart(draw, (1220, 730, 675, 210), seats["driver"], "speed_kmh", "Speed history · km/h", MINT, wall)
        health = driver.get("part_health", [])
        draw.text((1220, 958), "PART HEALTH  FL / FR / RL / RR / ENGINE / F / R / GLASS", font=font(17), fill=MUTED)
        for index, value in enumerate(health):
            x = 1220 + index * 84
            draw.rectangle((x, 990, x+72, 1008), fill=PANEL)
            draw.rectangle((x, 990, x+72*max(0, value), 1008), fill=MINT if value > .4 else RED)
        used = [r for r in responses if r["unix_time"] <= wall]
        tokens = sum(r.get("usage", {}).get("input_tokens", 0) + r.get("usage", {}).get("output_tokens", 0) for r in used)
        draw.text((24, 1044), f"{manifest['course']} · seed {manifest['seed']} · {len(used)} responses · {tokens} billed tokens · source {manifest['git_commit'][:8]}"
                  + (" · SCRIPTED, NOT MODEL PERFORMANCE" if manifest["provider"] == "scripted" else ""), font=font(18), fill=MUTED)
        return canvas

    # The primary video restores normal game speed using measured clock progress.
    # An explicit review-speed override remains useful for reading the dialogue.
    sim_rows = [r for r in seats["driver"] if r["unix_time"] >= started]
    sim_end, wall_for_sim = simulation_timeline(sim_rows)
    videos = [("recap.mp4", sim_end, wall_for_sim, "NORMAL GAME SPEED")]
    if review_speed is not None:
        videos = [
            ("recap.mp4", (ended-started)/review_speed, lambda t: started+t*review_speed, f"REVIEW {review_speed:g}× REAL"),
            ("recap_simulation.mp4", sim_end, wall_for_sim, "NORMAL GAME SPEED"),
        ]
    for name, duration, mapping, label in videos:
        if duration <= 0:
            continue
        cmd = [ffmpeg, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
               "-s", f"{WIDTH}x{HEIGHT}", "-r", str(fps), "-i", "-", "-an", "-c:v", "libx264",
               "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(directory / name)]
        with (directory / (name + ".log")).open("w") as output:
            encoder = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=output)
            try:
                for index in range(max(1, math.ceil(duration*fps))):
                    picture = render(mapping(index/fps), label)
                    encoder.stdin.write(picture.tobytes())
                encoder.stdin.close()
                if encoder.wait(timeout=60):
                    raise RuntimeError(f"FFmpeg failed; see {directory / (name + '.log')}")
            finally:
                if encoder.poll() is None:
                    encoder.kill()
                    encoder.wait()
    if review_speed is None and (directory / "recap.mp4").is_file():
        shutil.copyfile(directory / "recap.mp4", directory / "recap_simulation.mp4")
    render(ended, "FINAL RECAP").save(directory / "recap.jpg", quality=92)
    print(f"Recap: {directory / 'recap.mp4'}", flush=True)
    return summary


def summarize_runs(root: Path) -> Path:
    """Keep individual runs + grouped statistics; never pool distinct speed levels."""
    root = Path(root).resolve()
    rows = [json.loads(path.read_text()) for path in sorted(root.glob("*/summary.json"))]
    if not rows:
        raise RuntimeError(f"No completed run summaries under {root}")
    fields = sorted({k for row in rows for k in row})
    with (root / "runs.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows({k: json.dumps(v) if isinstance(v, (list, dict)) else v for k, v in row.items()} for row in rows)
    groups = {}
    for row in rows:
        key = tuple(row.get(k, "legacy") for k in ("provider", "label", "course", "driver_model", "navigator_model", "speed_percent", "cohort"))
        groups.setdefault(key, []).append(row)
    grouped = []
    for key, samples in groups.items():
        valid = [s for s in samples if s["valid_run"]]
        values = [s["forward_progress_m"] for s in valid]
        scores = [s["score"] for s in valid if "score" in s]
        grouped.append(dict(zip(("provider", "label", "course", "driver_model", "navigator_model", "speed_percent", "cohort"), key),
                            runs=len(samples), valid_runs=len(valid),
                            mean_progress_m=statistics.mean(values) if values else None,
                            median_progress_m=statistics.median(values) if values else None,
                            stdev_progress_m=statistics.stdev(values) if len(values)>1 else None,
                            mean_score=statistics.mean(scores) if scores else None,
                            median_score=statistics.median(scores) if scores else None,
                            mean_hits=statistics.mean(s.get("impact_events", 0) for s in valid) if valid else None,
                            mean_offroad_sim_seconds=statistics.mean(s.get("offroad_sim_seconds", 0) for s in valid) if valid else None,
                            seeds=[s["seed"] for s in valid]))
    (root / "benchmark.json").write_text(json.dumps(grouped, indent=2))
    chart = Image.new("RGB", (1600, max(500, 115+len(grouped)*76)), BG)
    draw = ImageDraw.Draw(chart)
    draw.text((25, 20), "Progress by speed and model pair · descriptive means, inspect runs.csv for limits/errors", font=font(25), fill=INK)
    maximum = max(1, max((g["mean_progress_m"] or 0 for g in grouped), default=1))
    for i, group in enumerate(grouped):
        y = 90+i*76
        title = f"{group['speed_percent']:g}%  {group['driver_model']} / {group['navigator_model']}  [{group['label']}; {group['cohort'][:6]}]"
        draw.text((25, y), title[:110], font=font(19), fill=INK)
        value = group["mean_progress_m"] or 0
        draw.rectangle((25, y+29, 25+value/maximum*1200, y+52), fill=MINT)
        draw.text((1245, y+25), f"{value:.1f} m · n={group['valid_runs']}", font=font(20), fill=GOLD)
    chart.save(root / "benchmark.png")
    return root / "benchmark.png"
