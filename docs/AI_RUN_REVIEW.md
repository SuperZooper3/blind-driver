# Aya baseline review — 14 November 2026

Reviewed the complete conversation, action events, request observations and saved
frames for `20261114-104844-469d88` (source `7e2891d`, both seats
`c4ai-aya-vision-32b`, basic course, 25% speed).

## What happened

- 30.004 simulation seconds, 120.018 real seconds; 34 accepted actions, no format
  errors. All 17 driver actions held W with no steering, brake or reverse.
- All 17 navigator actions tapped M. They alternated between the road and map;
  the map toggle was actually being applied.
- Every navigator message was “Checking map for route ahead.” The driver's first
  was “Starting to accelerate forward.” and its remaining messages were
  “Continuing to accelerate forward.” No useful recovery instruction was exchanged.
- About 283 m odometer distance, 247 m forward road progress, one significant
  collision and 18.67 off-road simulation seconds. The car became stuck around
  13 simulation seconds; later observations showed almost zero speed.
- After the first request, every request log contained the partner's preceding
  message. Frames and timestamps advanced normally. The driver held W on all 648
  active captured frames after its first accepted action; holds were not expiring.

## What this establishes

The request loop delivered messages and fresh screenshots. The adapter retained
each seat's recent text history (then 16 own turns); it did not restart a fresh
conversation on every request. Full provider request bodies were not saved, so
the history-retention conclusion also relies on inspecting the adapter code.
These logs do not prove the model made effective use of that context.

The failure was repeated unhelpful decisions, rather than a demonstrated input
hold failure or missing partner messages. This single run cannot separate small
text, blurred perception, weak spatial understanding, or instruction-following as
the dominant cause. The repeated map requests also prevented continuous road
observation. A stronger model comparison remains an experiment, not a result.

## Harness changes to evaluate next

Use one current screenshot only, as requested. Retain 32 recent text turns by
default and concise own notes. Update a short factual recap of earlier turns in
the background while the partner chooses its action, preserving timestamps and
uncertainties. Log recap latency, usage and the turn watermark so stale summaries
are visible. No hidden map geometry or driving advice enters model observations.

The game supplies a larger HUD/map, clear movement status, a north-up map with a
rotating heading arrow, and text equivalents of audible events. Its camera uses
a narrower field of view to make scene objects larger. The scoring, roadside
thorns, display and memory configuration are new benchmark conditions, so compare
new runs separately from this baseline. Improvements in readability or plumbing
are not evidence of improved driving until matched trials establish that.

See [AI_HARNESS.md](AI_HARNESS.md) for controls, score weights and recorded artifacts.
