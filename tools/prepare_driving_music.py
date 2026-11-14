#!/usr/bin/env python3
"""Prepare the supplied music.mp3 for the car radio (requires FFmpeg).

The final half second blends 123.5–124 with 13–13.5. Godot then loops
to 13.5, continuing the incoming side without repeating the crossfade.
"""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    target = ROOT / "assets/audio/driving_music.ogg"
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(args.source), "-i", str(args.source),
        "-filter_complex",
        "[0:a]atrim=end=124,asetpts=PTS-STARTPTS[bodytrim];"
        "[1:a]atrim=start=13:end=13.5,asetpts=PTS-STARTPTS[headtrim];"
        "[bodytrim][headtrim]acrossfade=d=0.5:c1=tri:c2=tri[music]",
        "-map", "[music]", "-map_metadata", "-1", "-ar", "48000", "-ac", "2",
        "-c:a", "libvorbis", "-q:a", "5", str(target),
    ], check=True)
    print(target)


if __name__ == "__main__":
    main()
