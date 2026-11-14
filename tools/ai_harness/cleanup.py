"""Remove generated raw frames only after a usable recap has been saved."""
import json
from pathlib import Path
import shutil
import subprocess
import time


def cleanup_frames(directory: Path) -> dict:
    directory = directory.resolve()
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest.get("run_id") != directory.name:
        raise ValueError("Cleanup requires a recorded run directory")
    for name in ("result.json", "summary.json", "recap.jpg", "recap.mp4"):
        if not (directory / name).is_file():
            raise ValueError("Keep frames: recap artifacts are incomplete")
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height:format=duration", "-of", "json", str(directory / "recap.mp4")],
        capture_output=True, text=True, timeout=15, check=True)
    video = json.loads(probe.stdout)
    if not video.get("streams") or float(video.get("format", {}).get("duration", 0)) <= 0:
        raise ValueError("Keep frames: recap video could not be verified")
    count = size = 0
    for role in ("driver", "navigator"):
        frames = directory / role / "frames"
        if not frames.exists():
            continue
        if frames.is_symlink() or not frames.resolve().is_relative_to(directory):
            raise ValueError("Refusing cleanup outside the run")
        for path in frames.rglob("*"):
            if path.is_file() and not path.is_symlink():
                count += 1
                size += path.stat().st_size
        shutil.rmtree(frames)
    result = {"files_removed": count, "bytes_removed": size, "unix_time": time.time(),
              "kept": "recap videos/still, metrics, prompts, conversation and telemetry logs"}
    if count or not (directory / "cleanup.json").exists():
        (directory / "cleanup.json").write_text(json.dumps(result, indent=2) + "\n")
    return result
