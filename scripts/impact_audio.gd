extends Node
## Synthesized crash and tire-pop sounds: no downloaded audio. Both are built once
## into short PCM buffers and replayed through a few voices so hits can overlap.

const MIX_RATE := 22050
var enabled := true
var crash_stream: AudioStreamWAV
var pop_stream: AudioStreamWAV
var voices: Array[AudioStreamPlayer] = []
var next_voice := 0

func _ready() -> void:
	crash_stream = _build(0.75, _crash_sample)
	pop_stream = _build(0.7, _pop_sample)
	for _i in 4:
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		voices.append(voice)

## strength 0..1: louder, lower and longer for harder hits.
func crash(strength: float) -> void:
	_play(crash_stream, linear_to_db(lerpf(0.25, 1.0, strength)) - 4.0, lerpf(1.25, 0.85, strength) + randf_range(-0.06, 0.06))

func pop() -> void:
	_play(pop_stream, -3.0, randf_range(0.95, 1.08))

func _play(stream: AudioStream, volume: float, pitch: float) -> void:
	if not enabled:
		return
	var voice := voices[next_voice]
	next_voice = (next_voice + 1) % voices.size()
	voice.stream = stream
	voice.volume_db = volume
	voice.pitch_scale = pitch
	voice.play()

func _build(seconds: float, sample: Callable) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2207
	var frames := int(seconds * MIX_RATE)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var state := {"low": 0.0, "rng": rng}
	for i in frames:
		var value := clampf(sample.call(float(i) / MIX_RATE, state), -1.0, 1.0)
		data.encode_s16(i * 2, int(value * 32000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Thump of the body, crunch of noise, and a few clanking metal partials.
func _crash_sample(t: float, state: Dictionary) -> float:
	var rng: RandomNumberGenerator = state.rng
	var noise := rng.randf_range(-1.0, 1.0)
	state.low = lerpf(state.low, noise, 0.18)
	var thump := sin(TAU * (48.0 + 40.0 * exp(-t * 30.0)) * t) * exp(-t * 9.0)
	var crunch: float = state.low * exp(-t * 7.0) * 1.4 + noise * exp(-t * 35.0) * 0.5
	var clank := (sin(TAU * 410.0 * t) * 0.5 + sin(TAU * 687.0 * t) * 0.35 + sin(TAU * 1130.0 * t) * 0.25) * exp(-t * 11.0)
	var rattle := noise * 0.25 * exp(-t * 4.0) * (0.5 + 0.5 * sin(TAU * 23.0 * t))
	return thump * 0.8 + crunch * 0.6 + clank * 0.35 + rattle

## A sharp crack followed by escaping air.
func _pop_sample(t: float, state: Dictionary) -> float:
	var rng: RandomNumberGenerator = state.rng
	var noise := rng.randf_range(-1.0, 1.0)
	state.low = lerpf(state.low, noise, 0.35)
	var crack := noise * exp(-t * 90.0) * 1.2 + sin(TAU * 160.0 * t) * exp(-t * 40.0) * 0.6
	var hiss: float = (noise - state.low) * 0.45 * exp(-t * 4.5) * smoothstep(0.0, 0.03, t)
	return crack + hiss
