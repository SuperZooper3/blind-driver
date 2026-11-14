import argparse
import itertools
from pathlib import Path

from .run import ROOT, find_godot, prepare, run_episode
from .recap import build_recap, summarize_runs
from .agents import DEFAULT_MODEL


def main():
    parser = argparse.ArgumentParser(description="One Godot engine with two complete seat views, visual agents, keyboard controls, and recap videos")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="Record one episode")
    batch = sub.add_parser("benchmark", help="Run model-pair × speed × seed comparisons")
    for p in (run, batch):
        p.add_argument("--provider", choices=["scripted", "cohere", "gemini"], default="scripted")
        p.add_argument("--driver-model")
        p.add_argument("--navigator-model")
        p.add_argument("--driver-instructions", help="Optional coaching text appended to the driver's prompt")
        p.add_argument("--navigator-instructions", help="Optional coaching text appended to the navigator's prompt")
        p.add_argument("--speed", type=float, help="Simulation speed percentage (1–100); Gemini defaults to 5, others 25")
        p.add_argument("--seed", type=int, default=72419)
        p.add_argument("--course", choices=["basic", "standard"], default="basic")
        p.add_argument("--sim-seconds", type=float, default=60)
        p.add_argument("--capture-fps", type=int, default=6)
        p.add_argument("--video-fps", type=int, default=15)
        p.add_argument("--review-speed", type=float, help="Override normal-game-speed recap with this multiplier of real capture time")
        p.add_argument("--rpm", type=float, help="Combined API requests/minute; Gemini defaults to 185, others 18")
        p.add_argument("--driver-rpm", type=float, default=180, help="Gemini driver per-model cap (default 180; configure from AI Studio)")
        p.add_argument("--navigator-rpm", type=float, default=5, help="Gemini navigator per-model cap (default 5; includes recaps)")
        p.add_argument("--driver-tpm", type=int, default=40000, help="Gemini rolling input-token/minute budget, with estimated reservations")
        p.add_argument("--navigator-tpm", type=int, default=20000, help="Gemini navigator input-token/minute budget; confirm actual quota in AI Studio")
        p.add_argument("--driver-timeout", type=float, default=5, help="Gemini decision request timeout in real seconds")
        p.add_argument("--max-requests", type=int, default=100)
        p.add_argument("--max-tokens", type=int, default=200000)
        p.add_argument("--max-output-tokens", type=int)
        p.add_argument("--history-turns", type=int, default=32)
        p.add_argument("--memory-every", type=int, help="Background recap every N own turns; default 0 for Gemini, 8 otherwise; Decisions driver never recaps")
        p.add_argument("--decision-interval-sim", type=float, default=0, help="Optional minimum game seconds between observations per seat; new chat wakes it sooner (default: no delay)")
        p.add_argument("--readable-ui", action=argparse.BooleanOptionalAction, default=True)
        p.add_argument("--keep-frames", action="store_true", help="Keep raw screenshots for debugging/rebuilding; otherwise clean them after the recap")
        p.add_argument("--timeout", type=float, help="Request timeout; defaults to 60s for Gemini navigator, 30s otherwise")
        p.add_argument("--max-action-age-sim", type=float, default=5)
        p.add_argument("--scripted-interval", type=float, default=.8)
        p.add_argument("--label", default="baseline", help="Prompt/training revision name for comparisons")
        p.add_argument("--env-file", default=str(ROOT / ".env"))
        p.add_argument("--godot")
        p.add_argument("--output", default=str(ROOT / "runs"))
    batch.add_argument("--speeds", default="5,25,100")
    batch.add_argument("--models", help="Comma-separated models; test every driver/navigator pairing")
    batch.add_argument("--seeds", default="72419")
    batch.add_argument("--repeats", type=int, default=1)
    batch.add_argument("--total-request-budget", type=int, default=120)
    recap = sub.add_parser("recap", help="Rebuild videos from captured frames without making model calls")
    recap.add_argument("directory", type=Path)
    recap.add_argument("--video-fps", type=int, default=15)
    recap.add_argument("--review-speed", type=float, help="Override normal game speed; 1 preserves real recording time")
    watch = sub.add_parser("watch", help="Follow both agents and game status in one read-only terminal")
    watch.add_argument("directory", type=Path)
    watch.add_argument("--latest", action="store_true", help="Follow the newest run under this output directory, including future runs")
    live = sub.add_parser("serve", help="Local game views, messages, New/Stop/Repeat controls")
    live.add_argument("directory", type=Path)
    live.add_argument("--latest", action="store_true")
    live.add_argument("--port", type=int, default=8766)
    live.add_argument("--env-file", default=str(ROOT / ".env"), help="Cohere configuration for new/repeated runs")
    live.add_argument("--provider", choices=["cohere", "gemini"], default="cohere", help="Provider for New run")
    summarize = sub.add_parser("summarize", help="Export CSV and graphs across recorded runs")
    summarize.add_argument("directory", type=Path)
    cleanup = sub.add_parser("cleanup", help="Remove raw screenshots from a successfully rendered run")
    cleanup.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.command == "cleanup":
        from .cleanup import cleanup_frames
        print(cleanup_frames(args.directory))
        return
    if args.command == "serve":
        if not 0 <= args.port <= 65535:
            parser.error("Port must be 0–65535 (0 chooses an available port)")
        from .dashboard import serve
        if args.provider == "cohere":
            serve(args.directory, args.latest, args.port, args.env_file)
        else:
            serve(args.directory, args.latest, args.port, args.env_file, provider=args.provider)
        return
    if args.command == "watch":
        from .monitor import watch
        watch(args.directory, args.latest)
        return
    if args.command in {"run", "benchmark", "recap"} and args.review_speed is not None:
        if not 0 < args.review_speed < float("inf"):
            parser.error("Review speed must be positive and finite")
    if args.command == "recap":
        if not 1 <= args.video_fps <= 60:
            parser.error("Video FPS must be 1–60")
        build_recap(args.directory, args.video_fps, args.review_speed)
        return
    if args.command == "summarize":
        print(summarize_runs(args.directory))
        return
    from .gemini import DRIVER_MODEL, NAVIGATOR_MODEL
    gemini = args.provider == "gemini"
    for field, default in {"driver_model": DRIVER_MODEL if gemini else DEFAULT_MODEL,
            "navigator_model": NAVIGATOR_MODEL if gemini else DEFAULT_MODEL,
            "speed": 5 if gemini else 25, "rpm": 185 if gemini else 18,
            "timeout": 60 if gemini else 30,
            "memory_every": 0 if gemini else 8, "max_output_tokens": 2048 if gemini else 512}.items():
        if getattr(args, field) is None:
            setattr(args, field, default)
    for field in ("speed", "sim_seconds", "rpm", "driver_rpm", "navigator_rpm", "driver_tpm", "navigator_tpm", "driver_timeout", "max_requests", "max_tokens", "max_output_tokens", "history_turns", "timeout", "max_action_age_sim", "scripted_interval"):
        if not 0 < getattr(args, field) < float("inf"):
            parser.error(f"--{field.replace('_','-')} must be positive and finite")
    if not 1 <= args.speed <= 100 or not 1 <= args.capture_fps <= 30 or not 1 <= args.video_fps <= 60:
        parser.error("Speed must be 1–100%; capture FPS 1–30; video FPS 1–60")
    if not 0 <= args.decision_interval_sim <= 5:
        parser.error("Decision interval must be between 0 and 5 game seconds")
    if args.memory_every < 0:
        parser.error("Memory interval must be zero or positive")
    if args.command == "run":
        run_episode(args)
    else:
        import json
        speeds = [float(v) for v in args.speeds.split(",")]
        seeds = [int(v) for v in args.seeds.split(",")]
        if any(not 1 <= speed <= 100 for speed in speeds) or args.repeats < 1 or args.total_request_budget < 1:
            parser.error("Invalid benchmark speeds/repeats/budget")
        models = args.models.split(",") if args.models else None
        pairs = list(itertools.product(models, repeat=2)) if models else [(args.driver_model, args.navigator_model)]
        grid = list(itertools.product(speeds, pairs, seeds, range(args.repeats)))
        # Fixed shuffle improves service-load balance while retaining reproducibility.
        import random
        random.Random(0).shuffle(grid)
        prepare(find_godot(args.godot))
        remaining, per_run = args.total_request_budget, args.max_requests
        for speed, (driver, navigator), seed, repeat in grid:
            if remaining <= 0:
                print("Benchmark request budget exhausted; remaining combinations were not run.")
                break
            args.speed, args.driver_model, args.navigator_model, args.seed = speed, driver, navigator, seed
            args.max_requests = min(per_run, remaining)
            directory = run_episode(args, prepared=True)
            remaining -= json.loads((directory / "result.json").read_text())["requests"]
        print(summarize_runs(Path(args.output)))


if __name__ == "__main__":
    main()
