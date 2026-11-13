#!/usr/bin/env python3
"""Godot physics + LAN checks; --relay also tests two games through Node."""
import os
from pathlib import Path
import re
import shutil
import socket
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


def wait_output(process, path, pattern):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        output = path.read_text()
        match = re.search(pattern, output)
        if match:
            return match
        if process.poll() is not None:
            raise RuntimeError(output)
        time.sleep(0.1)
    raise RuntimeError("Timed out waiting for process: " + path.read_text())


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)


def run_pair(temporary, relay_url="", resilience=False, lan_recovery=False, hazards=False):
    probe = "tests/hazard_network_probe.gd" if hazards else "tests/network_probe.gd"
    host = None
    tag = "relay" if relay_url else "lan"
    extra = ["--relay-url=" + relay_url] if relay_url else []
    if lan_recovery:
        extra += ["--probe-duration=15", "--expect-lan-recovery"]
    if resilience:
        extra += ["--probe-duration=75", "--expect-recovery"]
    path = temporary / (tag + "-host-output.txt")
    try:
        with path.open("w+") as output:
            host = subprocess.Popen(command(probe, temporary / (tag + "-host.log"), "--", "--probe-host", *extra), stdout=output, stderr=subprocess.STDOUT)
            if relay_url:
                code = wait_output(host, path, r"ROOM_READY=([A-F0-9]{18})").group(1)
                extra.append("--relay-room=" + code)
            else:
                wait_output(host, path, "HOST_READY")
            client = subprocess.run(command(probe, temporary / (tag + "-client.log"), "--", "--probe-join", *extra), capture_output=True, text=True, timeout=95 if resilience else (45 if hazards else 25))
            print(f"[{tag}]", client.stdout)
            host.wait(timeout=15)
            host_output = path.read_text()
            print(re.sub(r"ROOM_READY=[A-F0-9]+", "ROOM_READY=(test room)", host_output))
            if client.returncode or host.returncode or "FAIL:" in client.stdout or "SCRIPT ERROR" in client.stderr or "SCRIPT ERROR" in host_output:
                raise RuntimeError(client.stderr + "\nNetwork integration check failed")
    finally:
        stop(host)


def run_named_pair(temporary, relay_url):
    """Navigator arrives first, then both enter only an agreed name (no exchanged code)."""
    host = client = None
    extra = ["--relay-url=" + relay_url, "--lobby-name=integration-friends", "--probe-duration=14"]
    client_path = temporary / "named-client-output.txt"
    host_path = temporary / "named-host-output.txt"
    try:
        with client_path.open("w+") as client_output, host_path.open("w+") as host_output:
            client = subprocess.Popen(command("tests/network_probe.gd", temporary / "named-client.log", "--", "--probe-join", "--cut-before-driver", *extra), stdout=client_output, stderr=subprocess.STDOUT)
            wait_output(client, client_path, "WAITING_RECONNECT")
            host = subprocess.Popen(command("tests/network_probe.gd", temporary / "named-host.log", "--", "--probe-host", *extra), stdout=host_output, stderr=subprocess.STDOUT)
            client.wait(timeout=25)
            host.wait(timeout=20)
        outputs = client_path.read_text() + host_path.read_text()
        print("[named lobby]", re.sub(r"ROOM_READY=[A-F0-9]+", "ROOM_READY=(test room)", outputs))
        if client.returncode or host.returncode or "FAIL:" in outputs or "SCRIPT ERROR" in outputs:
            raise RuntimeError("Named lobby integration failed")
    finally:
        stop(client)
        stop(host)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="blind-driver-checks-") as directory:
        temporary = Path(directory)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            os.environ["BLIND_DRIVER_LAN_PORT"] = str(reservation.getsockname()[1])
        os.environ["BLIND_DRIVER_RECORDS_PATH"] = str(temporary / "records.cfg")
        police = subprocess.run(command("tests/police_smoke.gd", temporary / "police.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(police.stdout)
        if police.returncode or "FAIL:" in police.stdout or "SCRIPT ERROR" in police.stderr:
            sys.exit(police.stderr or "Police check failed")
        survival = subprocess.run(command("tests/survival_smoke.gd", temporary / "survival.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(survival.stdout)
        if survival.returncode or "FAIL:" in survival.stdout or "SCRIPT ERROR" in survival.stderr:
            sys.exit(survival.stderr or "Survival check failed")
        lobby_ui = subprocess.run(command("tests/lobby_ui_smoke.gd", temporary / "lobby-ui.log"), capture_output=True, text=True, timeout=15)
        print(lobby_ui.stdout)
        if lobby_ui.returncode or "FAIL:" in lobby_ui.stdout or "SCRIPT ERROR" in lobby_ui.stderr:
            sys.exit(lobby_ui.stderr or "Lobby UI check failed")
        physics = subprocess.run(command("tests/drive_smoke.gd", temporary / "physics.log", "--fixed-fps", "60", "--quit-after", "1500"), capture_output=True, text=True, timeout=45)
        print(physics.stdout)
        if physics.returncode or "FAIL:" in physics.stdout or "SCRIPT ERROR" in physics.stderr:
            sys.exit(physics.stderr or "Physics check failed")
        gameplay = subprocess.run(command("tests/gameplay_smoke.gd", temporary / "gameplay.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(gameplay.stdout)
        if gameplay.returncode or "FAIL:" in gameplay.stdout or "SCRIPT ERROR" in gameplay.stderr:
            sys.exit(gameplay.stderr or "Gameplay check failed")
        obstacles = subprocess.run(command("tests/obstacle_smoke.gd", temporary / "obstacles.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(obstacles.stdout)
        if obstacles.returncode or "FAIL:" in obstacles.stdout or "SCRIPT ERROR" in obstacles.stderr:
            sys.exit(obstacles.stderr or "Obstacle check failed")
        launcher = subprocess.run(command("tests/local_pair_smoke.gd", temporary / "launcher.log"), capture_output=True, text=True, timeout=25)
        print(launcher.stdout)
        if launcher.returncode or "FAIL:" in launcher.stdout or "SCRIPT ERROR" in launcher.stderr:
            sys.exit(launcher.stderr or "Local window launcher check failed")
        run_pair(temporary, hazards=True)
        run_pair(temporary, lan_recovery="--resilience" in sys.argv)
        if "--relay" in sys.argv or "--resilience" in sys.argv:
            relay = None
            try:
                relay_output = temporary / "relay-output.txt"
                with relay_output.open("w+") as output:
                    relay = subprocess.Popen(["node", "../tests/relay_fault_server.mjs" if "--resilience" in sys.argv else "index.mjs"], cwd=ROOT / "server", env={**os.environ, "PORT": "0", "HOST": "127.0.0.1"}, stdout=output, stderr=subprocess.STDOUT)
                    port = wait_output(relay, relay_output, r"listening on 127\.0\.0\.1:(\d+)").group(1)
                    run_pair(temporary, f"ws://127.0.0.1:{port}/ws", "--resilience" in sys.argv)
                    if "--resilience" not in sys.argv:
                        run_named_pair(temporary, f"ws://127.0.0.1:{port}/ws")
                        run_pair(temporary, f"ws://127.0.0.1:{port}/ws", hazards=True)
                    if "--resilience" in sys.argv:
                        print("[faults]", "\n".join(line for line in relay_output.read_text().splitlines() if "FAULT:" in line))
            finally:
                stop(relay)
    print("All requested driving and network checks passed.")
