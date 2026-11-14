# Visual-agent harness: first sketch

The primary output is a recap video showing **two complete seat views in one Godot engine**, agent
dialogue, keyboard inputs, timestamps, and live metrics. Python alternates the
navigator and driver while Godot keeps running. Both seats use ordinary keyboard
inputs. Each agent receives its full 1280×800 half of a 2560×800 game-rendered canvas.
The HUD is duplicated per seat; cropping never removes instruments. Hidden world
state is not sent to the models.
A game-rendered large-display profile and audible-event captions improve readability.

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
  --provider cohere --speed 5 --sim-seconds 60 --max-tokens 200000 --max-requests 200
```

Set `GODOT` or pass `--godot /path/to/Godot` if the executable is not detected.
Keep the key in `COHERE_API_KEY`; alternatively an ignored `.env` can contain that
variable, with `--env-file` selecting its path. Never place keys in tracked files
or CLI arguments. The key is removed from the Godot child-process environments
and is not included in manifests, screenshots, provider error bodies, or logs.

Each command launches and cleans up one Godot process. Both seats share the same
car, physics clock and world, with no LAN/relay transport or pose prediction.
Personal-best records are saved within the run. It does not control
existing game instances. Use Ctrl-C to stop; the captured portion is still compiled
into a recap. API requests already in flight may take up to `--timeout` to finish.
Do not operate the game controls during a scored run: this sketch does not block
physical keyboard or mouse input. Runs stopped with an outstanding request mark
token accounting as incomplete rather than claiming unreturned usage is zero.

The default output is `runs/<timestamp-id>/`, ignored by Git. The initial provider
default is `scripted` so an accidental invocation does not spend API quota. A
scripted result is prominently labeled and is not a model-performance claim.

## Model choices, prompts, and speeds

Both seats default to `command-a-plus-05-2026` (Command A+) with **512 thinking
tokens**, a 1,536-token total response limit, and local action validation. The
1,024-token margin leaves room for the final JSON after thinking. Thinking blocks
are never logged or sent to the partner; their token usage is counted. Command A
Vision (`command-a-vision-07-2025`) and Aya remain explicit alternatives, without
reasoning-specific API options. There is no silent model fallback.
[Cohere reasoning controls](https://docs.cohere.com/docs/reasoning).

The default speed is **5% (1/20)**. One simulated minute takes about twenty real
minutes. Each episode allows 60 game seconds, 200,000 combined input/output tokens,
and 200 API calls. The token cap is checked between requests and can overshoot by
an in-flight group. `--decision-interval-sim .6` spaces consecutive observations
by at least 0.6 game seconds; navigator and driver alternate, so each normally acts
about once per 1.2 game seconds. This avoids spending the budget repeatedly
observing almost identical frames at slow speed. Provider latency and the shared
18-request/minute limiter may lengthen that interval; the game keeps running.
Set the interval to zero for immediate successive requests.

The game still captures each **complete 1280×800 seat**. Provider inputs are
uniformly resized to at most 768 pixels wide, with no crop. The navigator uses
`high` image detail to retain road/map detail; the driver's already blurred view
uses `low` detail. Change `--image-width`, `--driver-image-detail`, or
`--navigator-image-detail` explicitly for comparisons. All settings enter the
manifest and benchmark fingerprint. Original screenshots remain at full size.
[Cohere image detail and token accounting](https://docs.cohere.com/docs/image-inputs).

Each observation includes a transcript of the five instruments actually drawn
in that seat: rounded speed and trip, surface, motion (including reversing), and
damage text. Drawing and transcription share the same function. No precise
position, road geometry, steering angle, hidden obstacle, or evaluator score is
passed to either agent. The previous visible-instrument snapshot helps distinguish
motion from stalling. Discrete own-seat view labels and audible-event captions
remain available. The map itself must still be interpreted visually.

The `grounded-copilot-v6` instructions and context:

- Plan with the map before departure, read a later fully opened frame, close it,
  and remember the upcoming bend. A map-check reminder tracks the last offered
  open view; it does not claim the model understood it.
- Use the current road view for immediate car alignment and obstacles. The next
  task changes with the visible UI: opening map, readable map, rear view,
  off-road/impact, route check due, or ordinary road watching.
- Give the driver an actionable speed/steering correction. The driver cannot use
  navigator controls. Map-check narration and visual notes stay private.
- Reassess after impact/off-road evidence; identify the road side, use chase view
  if obscured, inspect rear clearance before reversing, and verify each recovery
  step. Do not repeat an unresolved “stop and assess” message.
- Use short explicit steering/pedal pulses when appropriate. These are model-selected
  keyboard durations, not an automatic lane follower, speed governor, or brake.

Each seat keeps its last two short factual notes by default. Requests are fresh
image tasks rather than a long conversation of repetitive assistant answers.
The current context includes recent delivered speech, the newest partner message,
actual held keys, rejected-action feedback, and repetition feedback. Private notes
never cross seats. The full accepted dialogue and action history remain on disk.
Speech is optional: empty/whitespace messages create no chat event; repeated urgent
warnings remain deliverable. Invalid controls/format do not deliver speech.

`--history-turns` controls factual-note history. Optional background text recaps
are disabled by default (`--memory-every 0`) to avoid reinforcing stale visual
claims and spending extra calls. Set a positive interval to enable them; they use
immutable snapshots, count toward budgets, and do not delay an action waiting for
a second rate slot. A recap is explicitly older evidence, never a current sensor.
Optional `--driver-instructions` / `--navigator-instructions` files append experiment
coaching; `--label` identifies the experiment. Exact prompts and their hashes are saved.

Three consecutive provider/format errors from either seat end the trial; valid
replies from the other seat cannot reset that counter. Rejected responses receive
concise feedback next turn. Dollar cost is recorded as unknown; billed tokens are
retained for the account's pricing. A formatted response is not proof of good driving:
inspect the live run, saved images, actions, and measured road progress.

## Live terminal or browser

`run` now prints a single chronological stream for both agents: requests, inference
latency, proposed keys, accepted messages, errors, token usage, and periodic game
status (simulation/real time, speed, progress, hits, and held keys).
These are completed responses and factual working recaps, not token-by-token generation or private reasoning.
Messages are shown as delivered only after the game acknowledges their action.

To open the same live timeline in a separate terminal, without an API key:

```sh
# Start before or during the run; follows new runs until you close the viewer.
.venv/bin/python -m tools.ai_harness watch runs --latest

# Follow/replay one run's event log; exits after its recap is ready.
.venv/bin/python -m tools.ai_harness watch runs/RUN_ID

# Full screenshots, messages, actions, and metrics together in a local browser.
.venv/bin/python -m tools.ai_harness serve runs --latest --port 8766
# Open http://127.0.0.1:8766/
```

The page is a control panel for a local Godot process; it is not the browser-export
game. **New run (current defaults)** starts Cohere using this server checkout's
current models and limits, without copying an older recording's overrides. It
also works with an empty recordings folder. The dashboard version and each run's
version/model/limits are shown separately. After updating the checkout, restart
the viewer server and refresh the page so its controls use the new code.

Closing the viewer does not stop the run. **Stop run** releases both agents’ keys,
ends the episode, and saves its partial recap. **Repeat saved run** first stops/saves
the selected run, then starts a fresh episode with the same models, seed, speed,
and budgets. Conversation and working memory start fresh. Existing artifacts remain.
Both launch buttons stop/save an active selected run before starting its replacement.
Repeat uses the current checkout revision, recorded in the new manifest. Ctrl-C in the terminal
running the `run` command does stop it and compiles the captured portion.
The viewer retains scrollback, while `events.jsonl` and `transcript.txt` preserve
the timeline on disk. It does not expose API keys or image payloads.
The browser page includes both complete screenshots and updates once per second.
It serves only on localhost. Viewing and stopping require no provider key; Cohere
launches read `COHERE_API_KEY` from the server's environment or the checkout's ignored
`.env` file. `serve --env-file /path/to/.env` selects a different file. The child reads
that file afresh on each launch; the key is never put in source, CLI arguments, or
browser responses. Restrict the local file with `chmod 600 .env` and never commit it.
An environment variable takes precedence over the file. Controls use
a same-origin token, a specific run ID, and fixed argument lists, never browser-supplied
commands. They cannot control unrelated game instances.
The newest run appears automatically. **Follow latest** scrolls only when a new
partner message arrives, never on image refreshes or bookkeeping updates. Disable
it to keep reading older messages; the recap link appears after video rendering finishes.

## Keyboard contract

Both models return the same shape:

```json
{
  "hold": ["W", "A"],
  "tap": [],
  "message": "Turning left; tell me when to straighten.",
  "notes": "Road bends left. Need the next view to confirm alignment."
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
240 characters; optional notes at 600. Driver actions can additionally select
`steering_pulse_sim` (release A/D) and `pedal_pulse_sim` (release W/S), each 0.05–1
**game seconds** after acceptance. Omitted pulses preserve ordinary persistent
holds. Zero or a pulse for keys not held is a no-op and is omitted by the Python
validator. A pulse releases only its own key group; other held keys persist.
New accepted actions replace pending timers. Failed actions do not change them.
The game checks time during physics, so expiry does not wait for another model call.
If the game window loses focus and Godot clears keyboard state, the adapter
restores the requested held keys before physics. It never repeats taps. Telemetry
records both requested `held` keys and actual `pressed_keys`, plus an
`input_reassertions` counter, so control delivery can be checked separately from
the model's decisions.

The navigator observes, sends a message and keys, then the driver observes a new
frame, chooses keys and replies. **Held keys remain pressed until that same agent's
next accepted instruction replaces them.** Inference, the partner's turn, quota
waits, and rejected/failed responses do not release keys or apply automatic brakes.
For example, `hold: ["W", "A"]` keeps accelerating left; a later `hold: ["W"]`
straightens while continuing to accelerate; `hold: []` releases everything.
This also applies to the navigator's B key. Explicit driver pulses are the exception
above; taps remain momentary.

The observation-age limit rejects stale *new* decisions; it does not expire an
already accepted hold. Ending the episode (including errors, Ctrl-C, and limits)
releases every held key. Game menus/network recovery retain their ordinary pause
behavior. Pause/restart and changes to speed are not model actions.

Schema version 4 adds the shared local engine, working recaps and readable-display settings; new runs record `hold_policy: until_replaced_with_optional_key_pulses`. Older timed-hold runs remain
readable, with their fallback metrics retained, but should not be pooled with new
runs. The source/configuration fingerprint keeps those benchmark groups separate.

## Small game-side adapter

[`ai_capture.gd`](../scripts/ai_capture.gd) is activated only by
`BLIND_DRIVER_AI_CONFIG`. It reads one 2560×800 root-viewport image per capture and saves its two complete
1280×800 seat halves as JPEGs. It reads atomically
written keyboard commands, dispatches them through `Input.parse_input_event`, and
records telemetry. It forces a redraw at capture cadence so macOS window occlusion
does not silently freeze one camera. Each capture includes that seat’s real HUD, driver blur where appropriate,
windshield damage, and the navigator's map. Python does not derive driving advice from game internals; the visible-instrument
transcript is the explicit accessibility exception described above.

This intentionally uses local files rather than another server/API protocol.
Each process has its own directory and monotonically increasing command sequence.
Acknowledgments record what was applied. PNG/JPEG processing and video composition
stay separate from model inference. Raw frame folders are removed after a successful recap. The harness verifies the
video before removing frames; failed exports keep them for recovery. All recording
directories contain `.gdignore`, and the repository’s `runs/.gdignore` prevents
Godot from scanning/importing recordings. `--keep-frames` opts out for debugging.
The final video, recap still, metrics and text logs remain. The browser derives
finished seat previews from the recap still, without retaining raw screenshots.

Both captures come from the same GPU readback and share frame ID, simulation/real
timestamp, car state and process ID. Two role-specific command readers dispatch
normal input events into the same engine. Navigator keys never replace held driver
keys. Stop from either reader releases both. The visible window can be smaller
than the render canvas; its recording resolution remains fixed. No game network
connection, synchronization, interpolation, or prediction is used. The localhost
browser viewer is only a recorder/control interface. A capture stall over three
seconds invalidates the run.

## Courses and measurement

`--course basic` gives one continuing road with gentle bends and sparse rocks,
without police, forks, jumps, timed bridges, lakes, or heat escalation. Roadside
thorns start roughly 18 metres from the road center. In this basic course, all
four tires punctured by thorns ends the run. The normal human/standard course
retains its existing crippled-car behavior; flat tires alone do not end that mode.
Vehicle physics, blur, collisions, rollover, and modular damage remain active.
The full map is accessible but route planning is limited on this first course.

`--readable-ui` is on by default for harness runs; `--no-readable-ui` keeps the original map orientation/scale and
camera field of view, while retaining complete duplicated instruments. The default profile uses large digital speed/odometer/surface/movement readouts,
a narrower 60° camera field of view (objects appear larger), and a map with doubled
text/line/icon scale, north-up orientation, and a larger rotating car arrow plus
heading degrees. The map still covers the road but leaves the instruments visible.
Collision, tire-pop, engine-knock and siren captions appear in the game itself;
unheard caption events with timestamps also accompany the next model request.
No map obstacle detector, angle advice, or hidden damage/location values are added
to model inputs. The five visible instrument strings are also delivered as text. Ordinary human sessions retain their existing UI.
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
FPS, capture cost, applied keys, hold policy, and real/simulation clocks. Impact
events come from the game's impact signal, not every physics contact. Per-request
logs include observations, image references, dialogue, latencies, tokens,
responses, validation failures, and acknowledgments. Precise telemetry is never
included in model inputs. Sound captions, the exact rounded instrument strings, and discrete own-seat view labels are
explicit accessibility exceptions; exact map-reveal fractions stay in telemetry.

The versioned evaluation score is:

`forward progress metres − 25 × significant hits − 2 × off-road simulation seconds
− 100 × mean fraction of part health lost − 100 if Game Over`.

The hit count uses audible collision events (roughly above 3 m/s closing speed,
with contact/cooldown deduplication), not every persistent physics contact. The
weights are a first evaluation choice, recorded in each manifest; raw measurements
remain available for alternative scoring. A time/token/request limit or operator
stop is a truncation, not a failure penalty. Negative scores are valid. Scoring is
for evaluation only; no policy is being trained. Score and penalty components
appear in the live page, video, CSV and summary. Background recap counts, tokens,
and latency are also exported separately from action latency.

| Artifact | Purpose |
| --- | --- |
| `recap.mp4` | Main video at normal game speed, two complete synchronized views with conversation/controls/metrics |
| `recap_simulation.mp4` | Same normal-speed video; retained separately when an explicit review-speed override is used |
| `recap.jpg` | Final recap still |
| `recap_settings.json` | Playback/export settings used by the latest recap rebuild |
| `metrics.png` | Speed, progress, road deviation, distance, score and penalty plots |
| `metrics.csv`, `summary.json` | Detailed driver telemetry and episode statistics |
| `transcript.txt`, `events.jsonl` | Delivered dialogue and causal request/action events |
| `driver/`, `navigator/` | Per-frame telemetry, prompts and input logs; raw screenshots only during a run or with `--keep-frames` |
| `cleanup.json` | Removed file count and recovered disk space |
| `godot.log` | Shared engine log |
| `manifest.json`, `result.json` | Source hash, models, configuration, budgets, end reason, validity, termination/truncation |

The default recap compensates for game slowdown using the measured simulation
clock: a 25% run plays approximately 4× faster than its recording, and a 5% run
approximately 20×. Thirty simulation seconds produce a roughly thirty-second
video, independent of inference/recording wall time. This also removes simulation
stalls from the default replay. The live terminal continues at real recording time.

The review has a rolling transcript; accelerated messages can be brief.
If the run was made with `--keep-frames`, rebuild at normal game speed or slow it
to read dialogue without new model calls. After automatic cleanup, use the saved
video’s playback-speed control instead; raw-frame rebuilds are no longer available:

```sh
.venv/bin/python -m tools.ai_harness recap runs/RUN_ID
# 1× real recording time; overrides speed compensation for recap.mp4 only.
.venv/bin/python -m tools.ai_harness recap runs/RUN_ID --review-speed 1
```

Use `python -m tools.ai_harness cleanup runs/RUN_ID` to clean an older completed
run after verifying its recap. Failed/unrendered runs are kept.

Videos are silent in this sketch; on-screen sound captions remain visible. Captures are sampled, not a promise of perfect
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
.venv/bin/python -m unittest discover -s tests -p 'test_navigator_context.py' -v
.venv/bin/python -m unittest discover -s tests -p 'test_dashboard_launch.py' -v
godot --headless --path . --fixed-fps 60 --script tests/ai_harness_smoke.gd
python3 tests/run_checks.py --relay
npm --prefix server test
```

The smoke check verifies real key dispatch for both roles, stale/duplicate/invalid
actions, holds persisting beyond the old timeout, explicit release, stop cleanup,
continued simulation, the readable map/captions, roadside thorns, and terminal
all-tire punctures in the basic course at 5% speed. Unit tests cover one-image
requests, resizing, reasoning budgets, bounded notes/dialogue, concurrent immutable
recaps, score terms, and scoped HTTP controls. Native checks verify steering and
pedal pulses release only their own keys on the game clock.
Navigator regressions cover the repeated-map conversation, crash captions, dialogue
ages, silent/rejected delivery, map animation labels, and exclusion of hidden telemetry.
Rendered scripted runs verify the complete-seat capture/recap path. Live provider
trials are separate from those deterministic checks.
