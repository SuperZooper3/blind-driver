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
                code = wait_output(host, path, r"ROOM_READY=([A-Z0-9]{6})").group(1)
                extra.append("--relay-room=" + code)
            else:
                wait_output(host, path, "HOST_READY")
            client = subprocess.run(command(probe, temporary / (tag + "-client.log"), "--", "--probe-join", *extra), capture_output=True, text=True, timeout=95 if resilience else (45 if hazards else 25))
            print(f"[{tag}]", client.stdout)
            host.wait(timeout=15)
            host_output = path.read_text()
            print(re.sub(r"ROOM_READY=[A-Z0-9]+", "ROOM_READY=(test room)", host_output))
            if client.returncode or host.returncode or "FAIL:" in client.stdout or "SCRIPT ERROR" in client.stderr or "SCRIPT ERROR" in host_output:
                raise RuntimeError(client.stderr + "\nNetwork integration check failed")
    finally:
        stop(host)


def run_lag_check(temporary):
    """Drive through a relay that adds realistic jitter and stalls; the navigator's car
    must stay close to the real one and keep moving (see tests/relay_jitter_server.mjs)."""
    sys.path.insert(0, str(ROOT / "tests"))
    import lag_report
    relay = driver = None
    relay_output = temporary / "jitter-relay.txt"
    driver_path = temporary / "lag-driver-output.txt"
    try:
        with relay_output.open("w+") as output, driver_path.open("w+") as driver_output:
            relay = subprocess.Popen(["node", "../tests/relay_jitter_server.mjs"], cwd=ROOT / "server", env={**os.environ, "PORT": "0", "HOST": "127.0.0.1"}, stdout=output, stderr=subprocess.STDOUT)
            port = wait_output(relay, relay_output, r"listening on 127\.0\.0\.1:(\d+)").group(1)
            url = f"ws://127.0.0.1:{port}/ws"
            probe = lambda name, *extra: [GODOT, "--headless", "--path", str(ROOT), "--max-fps", "60", "--log-file", str(temporary / (name + ".log")), "--script", "tests/lag_probe.gd", "--", "--relay-url=" + url, "--out=" + str(temporary / (name + ".txt")), *extra]
            driver = subprocess.Popen(probe("lag-driver", "--duration=26"), stdout=driver_output, stderr=subprocess.STDOUT)
            code = wait_output(driver, driver_path, r"ROOM_READY=([A-Z0-9]{6})").group(1)
            navigator = subprocess.run(probe("lag-navigator", "--relay-room=" + code, "--duration=22"), capture_output=True, text=True, timeout=60)
            driver.wait(timeout=20)
        if "SCRIPT ERROR" in navigator.stderr + driver_path.read_text():
            raise RuntimeError(navigator.stderr + "\nLag probe failed")
        result = lag_report.report(temporary / "lag-driver.txt", temporary / "lag-navigator.txt")
        passed = result["p99_m"] < 3.0 and result["frozen_pct"] < 5.0 and result["samples"] > 600
        print("[online smoothness] {}: navigator vs real car under jitter and stalls: median {median_m:.2f} m, p99 {p99_m:.2f} m, max {max_m:.2f} m; frozen {frozen_pct:.1f}% of moving frames".format("PASS" if passed else "FAIL", **result))
        if not passed:
            raise RuntimeError("Online smoothness check failed")
    finally:
        stop(driver)
        stop(relay)


def run_direct_pair(temporary, relay_url, blocked=""):
    """Players meet through the relay, then link directly; `blocked` ("driver" or
    "navigator") refuses incoming connections, like a Mac firewall in stealth mode."""
    first = second = None
    tag = "direct-" + (blocked or "open")
    first_path = temporary / (tag + "-driver-output.txt")
    env = {**os.environ, "BLIND_DRIVER_DIRECT_LOOPBACK": "1"}
    no_listen = {**env, "BLIND_DRIVER_DIRECT_NO_LISTEN": "1"}
    try:
        with first_path.open("w+") as first_output:
            first = subprocess.Popen(command("tests/direct_probe.gd", temporary / (tag + "-driver.log"), "--", "--relay-url=" + relay_url), stdout=first_output, stderr=subprocess.STDOUT, env=no_listen if blocked == "driver" else env)
            code = wait_output(first, first_path, r"ROOM_READY=([A-Z0-9]{6})").group(1)
            second = subprocess.run(command("tests/direct_probe.gd", temporary / (tag + "-navigator.log"), "--", "--relay-url=" + relay_url, "--relay-room=" + code), capture_output=True, text=True, timeout=60, env=no_listen if blocked == "navigator" else env)
            first.wait(timeout=20)
        outputs = first_path.read_text() + second.stdout
        print(f"[direct link, {blocked or 'both'} {'blocked' if blocked else 'listening'}]", "\n".join(line for line in outputs.splitlines() if line.startswith(("PASS", "FAIL", "SCRIPT ERROR"))))
        if first.returncode or second.returncode or "FAIL:" in outputs or "SCRIPT ERROR" in outputs + second.stderr:
            raise RuntimeError(second.stderr + "\nDirect link integration failed")
    finally:
        stop(first)


def run_swap_pair(temporary, relay_url):
    """After a run ends, the navigator swaps seats and the two games trade driver and navigator."""
    first = second = None
    first_path = temporary / "swap-first-output.txt"
    try:
        with first_path.open("w+") as first_output:
            first = subprocess.Popen(command("tests/swap_probe.gd", temporary / "swap-first.log", "--", "--relay-url=" + relay_url), stdout=first_output, stderr=subprocess.STDOUT)
            code = wait_output(first, first_path, r"ROOM_READY=([A-Z0-9]{6})").group(1)
            second = subprocess.run(command("tests/swap_probe.gd", temporary / "swap-second.log", "--", "--relay-url=" + relay_url, "--relay-room=" + code), capture_output=True, text=True, timeout=60)
            first.wait(timeout=20)
        outputs = first_path.read_text() + second.stdout
        print("[swap roles]", "\n".join(line for line in outputs.splitlines() if line.startswith(("PASS", "FAIL", "SCRIPT ERROR"))))
        if first.returncode or second.returncode or "FAIL:" in outputs or "SCRIPT ERROR" in outputs + second.stderr:
            raise RuntimeError(second.stderr + "\nSeat swap integration failed")
    finally:
        stop(first)


def run_code_pair(temporary, relay_url):
    """The navigator creates the room; the driver joins with only the short code and is given the driver seat."""
    host = client = None
    extra = ["--relay-url=" + relay_url, "--probe-duration=14"]
    client_path = temporary / "code-client-output.txt"
    host_path = temporary / "code-host-output.txt"
    try:
        with client_path.open("w+") as client_output, host_path.open("w+") as host_output:
            client = subprocess.Popen(command("tests/network_probe.gd", temporary / "code-client.log", "--", "--probe-join", "--create-as-navigator", "--cut-before-driver", *extra), stdout=client_output, stderr=subprocess.STDOUT)
            code = wait_output(client, client_path, r"ROOM_READY=([A-Z0-9]{6})").group(1)
            wait_output(client, client_path, "WAITING_RECONNECT")
            host = subprocess.Popen(command("tests/network_probe.gd", temporary / "code-host.log", "--", "--probe-host", "--relay-room=" + code, *extra), stdout=host_output, stderr=subprocess.STDOUT)
            client.wait(timeout=25)
            host.wait(timeout=20)
        outputs = client_path.read_text() + host_path.read_text()
        print("[room code]", re.sub(r"ROOM_READY=[A-Z0-9]+", "ROOM_READY=(test room)", outputs))
        if client.returncode or host.returncode or "FAIL:" in outputs or "SCRIPT ERROR" in outputs:
            raise RuntimeError("Room code integration failed")
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
        radio = subprocess.run(command("tests/radio_smoke.gd", temporary / "radio.log"), capture_output=True, text=True, timeout=20)
        print(radio.stdout)
        if radio.returncode or "FAIL:" in radio.stdout or "SCRIPT ERROR" in radio.stderr:
            sys.exit(radio.stderr or "Driving radio check failed")
        surface = subprocess.run(command("tests/road_surface_smoke.gd", temporary / "road-surface.log"), capture_output=True, text=True, timeout=20)
        print(surface.stdout)
        if surface.returncode or "FAIL:" in surface.stdout or "SCRIPT ERROR" in surface.stderr:
            sys.exit(surface.stderr or "Road surface continuity check failed")
        direction = subprocess.run(command("tests/direction_warning_smoke.gd", temporary / "direction.log"), capture_output=True, text=True, timeout=20)
        print(direction.stdout)
        if direction.returncode or "FAIL:" in direction.stdout or "SCRIPT ERROR" in direction.stderr:
            sys.exit(direction.stderr or "Wrong-way warning check failed")
        harness = subprocess.run(command("tests/ai_harness_smoke.gd", temporary / "ai-harness.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=30)
        print(harness.stdout)
        if harness.returncode or "FAIL:" in harness.stdout or "SCRIPT ERROR" in harness.stderr:
            sys.exit(harness.stderr or "AI harness input/course check failed")
        routes = subprocess.run(command("tests/route_choices_smoke.gd", temporary / "routes.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=30)
        print(routes.stdout)
        if routes.returncode or "FAIL:" in routes.stdout or "SCRIPT ERROR" in routes.stderr:
            sys.exit(routes.stderr or "Route choice check failed")
        challenges = subprocess.run(command("tests/challenge_smoke.gd", temporary / "challenges.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=60)
        print(challenges.stdout)
        if challenges.returncode or "FAIL:" in challenges.stdout or "SCRIPT ERROR" in challenges.stderr:
            sys.exit(challenges.stderr or "Crossing challenge check failed")
        police = subprocess.run(command("tests/police_smoke.gd", temporary / "police.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(police.stdout)
        if police.returncode or "FAIL:" in police.stdout or "SCRIPT ERROR" in police.stderr:
            sys.exit(police.stderr or "Police check failed")
        survival = subprocess.run(command("tests/survival_smoke.gd", temporary / "survival.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(survival.stdout)
        if survival.returncode or "FAIL:" in survival.stdout or "SCRIPT ERROR" in survival.stderr:
            sys.exit(survival.stderr or "Survival check failed")
        prediction = subprocess.run(command("tests/prediction_smoke.gd", temporary / "prediction.log"), capture_output=True, text=True, timeout=20)
        print(prediction.stdout)
        if prediction.returncode or "FAIL:" in prediction.stdout or "SCRIPT ERROR" in prediction.stderr:
            sys.exit(prediction.stderr or "Prediction check failed")
        lobby_ui = subprocess.run(command("tests/lobby_ui_smoke.gd", temporary / "lobby-ui.log"), capture_output=True, text=True, timeout=15)
        print(lobby_ui.stdout)
        if lobby_ui.returncode or "FAIL:" in lobby_ui.stdout or "SCRIPT ERROR" in lobby_ui.stderr:
            sys.exit(lobby_ui.stderr or "Lobby UI check failed")
        ai_solo = subprocess.run(command("tests/ai_single_player_smoke.gd", temporary / "ai-single-player.log"), capture_output=True, text=True, timeout=15)
        print(ai_solo.stdout)
        if ai_solo.returncode or "FAIL:" in ai_solo.stdout or "SCRIPT ERROR" in ai_solo.stderr:
            sys.exit(ai_solo.stderr or "AI single-player check failed")
        physics = subprocess.run(command("tests/drive_smoke.gd", temporary / "physics.log", "--fixed-fps", "60", "--quit-after", "2600"), capture_output=True, text=True, timeout=45)
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
        repair = subprocess.run(command("tests/repair_smoke.gd", temporary / "repair.log", "--fixed-fps", "60"), capture_output=True, text=True, timeout=45)
        print(repair.stdout)
        if repair.returncode or "FAIL:" in repair.stdout or "SCRIPT ERROR" in repair.stderr:
            sys.exit(repair.stderr or "Repair check failed")
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
                        run_code_pair(temporary, f"ws://127.0.0.1:{port}/ws")
                        run_swap_pair(temporary, f"ws://127.0.0.1:{port}/ws")
                        run_lag_check(temporary)
                        for blocked in ("", "navigator", "driver"):
                            run_direct_pair(temporary, f"ws://127.0.0.1:{port}/ws", blocked)
                        run_pair(temporary, f"ws://127.0.0.1:{port}/ws", hazards=True)
                    if "--resilience" in sys.argv:
                        print("[faults]", "\n".join(line for line in relay_output.read_text().splitlines() if "FAULT:" in line))
            finally:
                stop(relay)
    print("All requested driving and network checks passed.")
