"""Local spectator page with run-scoped Stop/Restart; never exposes credentials."""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import secrets
from pathlib import Path
from urllib.parse import urlsplit

from .recap import json_lines
from .run import read_json
from .scoring import score_frame
from .controls import RunController


def run_directory(root: Path, latest: bool):
    if not latest:
        return root if (root / "manifest.json").exists() else None
    candidates = sorted(root.glob("*/manifest.json"), key=lambda p: p.parent.name)
    return candidates[-1].parent if candidates else None


def snapshot(directory):
    if directory is None:
        return {"waiting": True}
    manifest = read_json(directory / "manifest.json")
    # Explicit public-view fields. Never serve arbitrary run files/config/env.
    run = {k: manifest.get(k) for k in ("run_id", "provider", "speed", "course", "seed",
          "driver_model", "navigator_model", "git_commit", "hold_policy")}
    events = json_lines(directory / "events.jsonl")
    starts = [e["unix_time"] for e in events if e["event"] == "episode_started"]
    seats = {}
    fields = ("frame", "sim_time", "unix_time", "speed_kmh", "forward_progress_m", "distance_m",
              "held", "fallback", "impact_events", "active", "finished_reason", "hold_policy")
    for role in ("driver", "navigator"):
        state = read_json(directory / role / "latest.json")
        seats[role] = {k: state.get(k) for k in fields}
        if role == "driver":
            seats[role].update(score_frame(state, manifest.get("scoring")))
            seats[role]["offroad_sim_seconds"] = state.get("offroad_sim_seconds", 0)
    timeline = [{k: e[k] for k in ("event", "unix_time", "sim_time", "role", "to", "message",
                "request_id", "latency_seconds", "action", "usage", "error", "reason", "requests", "memory", "through_turn", "concurrent_action") if k in e}
                for e in events if e["event"] in {"request", "response", "message", "request_error",
                    "infrastructure_error", "episode_started", "episode_finished", "recap_error", "recap_ready",
                    "memory_request", "memory_response", "memory_error", "response_discarded"}]
    result = read_json(directory / "result.json")
    return {"run": run, "seats": seats, "events": timeline, "started": starts[0] if starts else None,
            "result": {k: result.get(k) for k in ("reason", "requests", "input_tokens", "output_tokens", "usage_complete")},
            "recap_ready": any(e["event"] == "recap_ready" for e in events)}


def handler_for(root: Path, latest: bool, controller=None):
    controller = controller or RunController()
    token = secrets.token_urlsafe(32)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            route = urlsplit(self.path).path
            directory = run_directory(root, latest) if latest else (controller.selected or run_directory(root, False))
            if route == "/":
                return self.send_content(Path(__file__).with_name("dashboard.html").read_bytes(), "text/html; charset=utf-8")
            if route == "/state":
                return self.send_content(json.dumps({**snapshot(directory), "controls": controller.state(directory), "control_token": token}).encode(), "application/json")
            if directory and route in {"/image/driver", "/image/navigator"}:
                role = route.rsplit("/", 1)[1]
                seat = directory / role
                name = read_json(seat / "latest.json").get("image", "")
                path = (seat / name).resolve()
                if path.is_relative_to((seat / "frames").resolve()) and path.suffix == ".jpg" and path.is_file():
                    return self.send_content(path.read_bytes(), "image/jpeg")
            if directory and route == "/recap.mp4" and snapshot(directory)["recap_ready"]:
                path = directory / "recap.mp4"
                if path.is_file():
                    return self.send_content(path.read_bytes(), "video/mp4")
            self.send_error(404)

        def do_POST(self):
            host = f"127.0.0.1:{self.server.server_port}"
            if (urlsplit(self.path).path != "/control" or self.headers.get("Host") != host
                    or self.headers.get("Origin") != "http://" + host
                    or not secrets.compare_digest(self.headers.get("X-Control-Token", ""), token)):
                return self.send_error(403)
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 2048:
                    raise ValueError("Invalid control body")
                body = json.loads(self.rfile.read(size))
                directory = run_directory(root, latest) if latest else (controller.selected or run_directory(root, False))
                controller.request(body.get("action"), directory, body.get("run_id"))
            except (ValueError, TypeError, AttributeError) as exc:
                return self.send_content(json.dumps({"error": str(exc)}).encode(), "application/json", 409)
            return self.send_content(b'{"accepted":true}', "application/json", 202)

        def send_content(self, data, content_type, status=200):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
    return Handler


def serve(root: Path, latest=False, port=8766):
    server = ThreadingHTTPServer(("127.0.0.1", port), handler_for(root.expanduser().resolve(), latest))
    print(f"Live spectator: http://127.0.0.1:{server.server_port}/ — Stop/Restart controls enabled; Ctrl-C closes the viewer server.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
