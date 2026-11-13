#!/usr/bin/env python3
"""Run real Godot physics and two-process localhost integration checks."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
if not GODOT:
    for candidate in [Path("/Applications/Godot.app/Contents/MacOS/Godot"), Path.home() / "Downloads/Godot.app/Contents/MacOS/Godot"]:
        if candidate.exists():
            GODOT = str(candidate)
            break
if not GODOT:
    sys.exit("Set GODOT to your Godot 4 executable.")


def command(script, logfile, *args):
    return [GODOT, "--headless", "--path", str(ROOT), "--log-file", str(logfile), "--script", script, *args]


with tempfile.TemporaryDirectory(prefix="blind-driver-checks-") as directory:
    temporary = Path(directory)
    physics = subprocess.run(
        command("tests/drive_smoke.gd", temporary / "physics.log", "--fixed-fps", "60", "--quit-after", "1500"),
        capture_output=True, text=True, timeout=45,
    )
    print(physics.stdout)
    if physics.returncode or "FAIL:" in physics.stdout or "SCRIPT ERROR" in physics.stderr:
        print(physics.stderr)
        sys.exit(1)
    host = None
    try:
        with (temporary / "host-output.txt").open("w+") as output:
            host = subprocess.Popen(command("tests/network_probe.gd", temporary / "host.log", "--", "--probe-host"), stdout=output, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if "HOST_READY" in (temporary / "host-output.txt").read_text():
                    break
                if host.poll() is not None:
                    sys.exit((temporary / "host-output.txt").read_text())
                time.sleep(0.1)
            else:
                sys.exit("FAIL: test host did not start")
            client = subprocess.run(command("tests/network_probe.gd", temporary / "client.log", "--", "--probe-join"), capture_output=True, text=True, timeout=25)
            print(client.stdout)
            host.wait(timeout=15)
            host_output = (temporary / "host-output.txt").read_text()
            print(host_output)
            if client.returncode or host.returncode or "FAIL:" in client.stdout or "SCRIPT ERROR" in client.stderr or "SCRIPT ERROR" in host_output:
                print(client.stderr)
                sys.exit(1)
    finally:
        if host and host.poll() is None:
            host.terminate()
            host.wait(timeout=5)
print("All driving and network checks passed.")
