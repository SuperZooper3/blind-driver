# Visual-agent harness: first sketch

The primary output is a recap video showing **two complete game windows**, agent
dialogue, keyboard inputs, timestamps, and live metrics. Python alternates the
navigator and driver while Godot keeps running. Both seats use ordinary keyboard
inputs. No split-screen crops, reconstructed dashboards, or world-state observations
are sent to the models.

This is an evaluation prototype, not reinforcement-learning training yet. It can
establish baselines and collect demonstrations for later coaching/fine-tuning.

## Install and run

Requirements: the project's Godot version, Python 3.10+, FFmpeg on PATH, and Pillow.
From the repository root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/ai_harness/requirements.txt

# No API key or model calls: exercise both seats and make a short recap.
.venv/bin/python -m tools.ai_harness run \
  --provider scripted --speed 25 --sim-seconds 4

# With COHERE_API_KEY already exported in this terminal:
.venv/bin/python -m tools.ai_harness run \
  --provider cohere --speed 25 --sim-seconds 30 --max-requests 36
```

Set `GODOT` or pass `--godot /path/to/Godot` if the executable is not detected.
Keep the key in `COHERE_API_KEY`; alternatively an ignored `.env` can contain that
variable, with `--env-file` selecting its path. Never place keys in tracked files
or CLI arguments. The key is removed from the Godot child-process environments
and is not included in manifests, screenshots, provider error bodies, or logs.

Each command launches and cleans up its own two processes, uses a free localhost
LAN port, and saves personal-best records within the run. It does not control
existing game instances. Use Ctrl-C to stop; the captured portion is still compiled
into a recap. API requests already in flight may take up to `--timeout` to finish.
Do not operate the game controls during a scored run: this sketch does not block
physical keyboard or mouse input. Runs stopped with an outstanding request mark
token accounting as incomplete rather than claiming unreturned usage is zero.

The default output is `runs/<timestamp-id>/`, ignored by Git. The initial provider
default is `scripted` so an accidental invocation does not spend API quota. A
scripted result is prominently labeled and is not a model-performance claim.

## Model choices, prompts, and speeds

Both seats default to `c4ai-aya-vision-32b`, our initial smaller-model baseline.
The stronger-model candidate is `command-a-plus-05-2026`; these are experiment
choices, not an established performance ranking. Both support image input.
[Aya Vision documentation](https://docs.cohere.com/docs/aya-vision).

```sh
.venv/bin/python -m tools.ai_harness run --provider cohere \
  --driver-model command-a-plus-05-2026 \
  --navigator-model c4ai-aya-vision-32b \
  --speed 10 --sim-seconds 20 --max-requests 60
```

Supported simulation percentages are 1–100. Speed is fixed for an episode;
changing it means a separate recorded benchmark condition. Five percent means
one simulated minute takes about twenty real minutes. The recorder also measures
actual clock advancement, because rendering and host load can change it.

Each seat has its own history, model ID, prompt, and received messages. Only the
current full-window JPEG is sent on each request. The last 16 role-local text
turns are retained by default; old visual frames are not repeatedly resent.
The history policy and exact prompts are saved. Use `--history-turns` to change it.
Optional `--driver-instructions file.txt` and `--navigator-instructions file.txt`
append coaching instructions; use `--label coached-v1` to identify the experiment.

Cohere is the first implemented provider. Command A+ uses JSON Schema output and
disables thinking for the initial latency baseline. Aya Vision and Command A Vision use JSON
instructions plus the same local validation. A future Google adapter can use the
same contract; it is not implemented in this sketch.
Aya also receives the same role/action instructions in each image-bearing user
turn: the first live trial described images when instructions appeared only in
the system preamble. This formatting adjustment does not repair or invent actions;
invalid output still counts as an error.
[Cohere Chat API](https://docs.cohere.com/v2/reference/chat),
[structured output](https://docs.cohere.com/docs/structured-outputs),
[reasoning controls](https://docs.cohere.com/docs/reasoning).

The shared limiter defaults to 18 requests/minute across both seats. Latency can
make the actual rate lower. Bound runs with `--max-requests`, `--max-tokens`, and
`--timeout`; the token cap is checked between requests and can overshoot by one
response. Three consecutive provider/format errors stop the trial. No hidden
provider/model fallback occurs. Dollar cost is recorded as unknown, not zero;
token usage is retained for calculating it using the account's actual pricing.

## Live terminal

`run` now prints a single chronological stream for both agents: requests, inference
latency, proposed keys, accepted messages, errors, token usage, and periodic game
status (simulation/real time, speed, progress, hits, held keys, and fallback).
These are completed responses, not token-by-token generation or private reasoning.
Messages are shown as delivered only after the game acknowledges their action.

To open the same live timeline in a separate terminal, without an API key:

```sh
# Start before or during the run; follows new runs until you close the viewer.
.venv/bin/python -m tools.ai_harness watch runs --latest

# Follow/replay one run's event log; exits after its recap is ready.
.venv/bin/python -m tools.ai_harness watch runs/RUN_ID
```

Closing this read-only viewer does not stop the run. Ctrl-C in the terminal
running the `run` command does stop it and compiles the captured portion.
The viewer retains scrollback, while `events.jsonl` and `transcript.txt` preserve
the timeline on disk. It does not expose API keys or image payloads.

## Keyboard contract

Both models return the same shape:

```json
{
  "hold": ["W", "A"],
  "tap": [],
  "hold_sim_seconds": 1.0,
  "message": "Turning left; tell me when to straighten."
}
```

| Seat | Held keys | Tap keys |
| --- | --- | --- |
| Driver | W, S, A, D, SPACE | H (headlights) |
| Navigator | B (look back) | M (map), C (seat/chase camera) |

`hold` replaces all held keys; `[]` releases them. `tap` generates one real Godot
key-down/key-up pair. Toggles retain normal semantics: tapping M twice opens then
closes the map. The normal map animation/occlusion is preserved. S brakes, then
reverses after stopping. Opposite inputs, duplicate keys, cross-role controls,
malformed responses, and stale observations are rejected. Messages are capped at
240 characters. Durations are 0.05–2 simulation seconds.

The navigator observes, sends a message and keys, then the driver observes a new
frame, chooses keys and replies. The previous controls stay applied during
inference until their lease expires. Expiry releases driving keys and holds SPACE;
the navigator releases B. This is an ordinary handbrake fallback, not an invisible
autopilot. All fallback time is logged. The world continues moving. Pause/restart
and changes to speed are not model actions.

## Small game-side adapter

[`ai_capture.gd`](../scripts/ai_capture.gd) is activated only by
`BLIND_DRIVER_AI_CONFIG`. It saves complete root-window JPEGs, reads atomically
written keyboard commands, dispatches them through `Input.parse_input_event`, and
records telemetry. It forces a redraw at capture cadence so macOS window occlusion
does not silently freeze one camera. Captures include the real HUD, driver blur,
windshield damage, and the navigator's map. Python never assembles observations
from game internals.

This intentionally uses local files rather than another server/API protocol.
Each process has its own directory and monotonically increasing command sequence.
Acknowledgments record what was applied. PNG/JPEG processing and video composition
stay separate from model inference. The first sketch stores every captured JPEG;
long runs need a disk-space budget or a streaming-video upgrade.

The existing LAN connection supplies the navigator's world. Only harness instances
use wall-clock LAN send intervals, so 5% simulation speed does not reduce snapshot
frequency to 1.5 Hz. Existing network interpolation still adds its normal delay.
The two captured windows are aligned by timestamps rather than claimed to be
pixel-simultaneous. A capture stall over three seconds invalidates the run.

## Courses and measurement

`--course basic` gives one continuing road with gentle bends and sparse rocks,
without police, forks, jumps, timed bridges, lakes, thorns, or heat escalation.
Vehicle physics, blur, collisions, rollover, and modular damage remain active.
The full map is accessible but route planning is limited on this first course.
`--course standard` selects the existing human game and all its hazards.

The basic profile's progress measure is the maximum new forward (-Z) displacement
while grounded within six meters of the road. Its roads continue in that direction.
Odometer distance is retained separately because it includes backtracking. The
forward metric is explicitly a proxy on the standard branching course; do not
interpret it as branch-aware route completion. Stalling earns no new progress;
this sketch uses a time limit rather than an additional stall-failure rule.

Telemetry includes speed, distance, progress, vehicle position/velocity/rotation
rate, steering, throttle/brake/handbrake, grounding, distance from road, off-road
time, impact-event count and strength, individual part health, tire state,
rollover, failure, map/camera state, police gap, heat, snapshots, connection state,
FPS, capture cost, applied keys, fallback, and real/simulation clocks. Impact
events come from the game's impact signal, not every physics contact. Per-request
logs include observations, image references, dialogue, latencies, tokens,
responses, validation failures, and acknowledgments. Precise telemetry is never
included in model inputs.

| Artifact | Purpose |
| --- | --- |
| `recap.mp4` | Main video at normal game speed, two complete views with conversation/controls/metrics |
| `recap_simulation.mp4` | Same normal-speed video; retained separately when an explicit review-speed override is used |
| `recap.jpg` | Final recap still |
| `recap_settings.json` | Playback/export settings used by the latest recap rebuild |
| `metrics.png` | Speed, progress, road deviation, and distance plots |
| `metrics.csv`, `summary.json` | Detailed driver telemetry and episode statistics |
| `transcript.txt`, `events.jsonl` | Delivered dialogue and causal request/action events |
| `driver/`, `navigator/` | Full screenshots, per-frame telemetry, prompts, input acknowledgments, and game logs |
| `manifest.json`, `result.json` | Source hash, models, configuration, budgets, end reason, validity, termination/truncation |

The default recap compensates for game slowdown using the measured simulation
clock: a 25% run plays approximately 4× faster than its recording, and a 5% run
approximately 20×. Thirty simulation seconds produce a roughly thirty-second
video, independent of inference/recording wall time. This also removes simulation
stalls from the default replay. The live terminal continues at real recording time.

The review has a rolling transcript; accelerated messages can be brief.
Rebuild at the default normal game speed or explicitly slow it to read dialogue,
without making any new API calls:

```sh
.venv/bin/python -m tools.ai_harness recap runs/RUN_ID
# 1× real recording time; overrides speed compensation for recap.mp4 only.
.venv/bin/python -m tools.ai_harness recap runs/RUN_ID --review-speed 1
```

Videos are silent in this sketch. Captures are sampled, not a promise of perfect
frame pacing. The normal-pace video follows the measured simulation clock. Frames
and logs preserve what happened; repeating controls does not guarantee identical
physics. Seeds reproduce course configuration in fresh processes, not model output.

## Benchmarks and graphs

```sh
# Small pipeline check at different speeds, without API calls.
.venv/bin/python -m tools.ai_harness benchmark --provider scripted \
  --speeds 5,25,100 --seeds 72419 --sim-seconds 2

# Cross both role assignments and repeat across seeds. Budget applies to the batch.
.venv/bin/python -m tools.ai_harness benchmark --provider cohere \
  --models command-a-plus-05-2026,c4ai-aya-vision-32b \
  --speeds 5,10 --seeds 72419,72420 --repeats 2 \
  --sim-seconds 10 --total-request-budget 120

.venv/bin/python -m tools.ai_harness summarize runs
```

The benchmark randomizes combination order with a fixed shuffle seed. A batch cap
may leave combinations unrun; it never fabricates missing results. Exports are
`runs.csv`, `benchmark.json`, and `benchmark.png`. Groups separate provider, model
pair, speed, course, label, and a configuration/source/prompt fingerprint. Invalid
infrastructure/provider runs are counted but excluded from progress averages.
Time/budget truncations remain explicit in the per-run data: inspect durations
before claiming improvement. These are descriptive statistics, not confidence
intervals or proof that one model is better.

For performance research, use the same held-out seeds, episode limits, controls,
blur, message budget, source revision, and provider settings. Compare role swaps
and speed sweeps. Later compare original/coached prompts on unseen seeds with the
coach absent, then collect demonstrations for imitation learning. Actual RL needs
trainable policy weights, rewards, and a training loop; none is claimed here.

## Verification

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_ai_harness.py' -v
godot --headless --path . --fixed-fps 60 --script tests/ai_harness_smoke.gd
python3 tests/run_checks.py --relay
npm --prefix server test
```

The smoke check verifies real key dispatch for both roles, stale/duplicate/invalid
actions, lease expiry, continued simulation, and the basic course at 5% speed.
Rendered scripted runs verify the full-window capture/recap path. Live provider
trials are separate from those deterministic checks.
