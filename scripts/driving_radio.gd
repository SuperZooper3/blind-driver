extends Node
## The loop crossfade is baked into the Ogg: audio-thread looping stays smooth
## even when rendering stalls. Only this radio's bus receives damage effects.

const MUSIC = preload("res://assets/audio/driving_music.ogg")
const LOOP_FROM := 13.0
const LOOP_END := 124.0
const CROSSFADE := 0.5
const MOVE_SPEED := 0.5
const MUSIC_DB := -13.0
const NOISE_RATE := 22050

var music: AudioStreamPlayer
var static_noise: AudioStreamPlayer
var burst: AudioStreamPlayer
var distortion := AudioEffectDistortion.new()
var low_pass := AudioEffectLowPassFilter.new()
var bus_name: StringName
var run_id := -1
var has_started := false
var interrupted := false
var terminal := false
var active := false
var muted := false
var retune_left := 0.0
var damage_amount := 0.0
var flutter_time := 0.0

func _ready() -> void:
	bus_name = StringName("DrivingRadio_%d" % get_instance_id())
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, &"Master")
	distortion.mode = AudioEffectDistortion.MODE_LOFI
	distortion.keep_hf_hz = 0.0
	AudioServer.add_bus_effect(index, distortion)
	AudioServer.add_bus_effect(index, low_pass)
	music = _voice()
	var track := MUSIC.duplicate() as AudioStreamOggVorbis
	track.loop = true
	track.loop_offset = LOOP_FROM + CROSSFADE
	music.stream = track
	music.volume_db = MUSIC_DB
	static_noise = _voice()
	static_noise.stream = _noise(false)
	burst = _voice()
	burst.stream = _noise(true)
	burst.volume_db = -16.0
	_set_damage(0.0)

func _voice() -> AudioStreamPlayer:
	var voice := AudioStreamPlayer.new()
	# Web's Sample mode bypasses bus effects; Stream keeps damage audible there.
	voice.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	voice.bus = bus_name
	add_child(voice)
	return voice

func reset(next_run: int) -> void:
	run_id = next_run
	music.stop()
	static_noise.stop()
	burst.stop()
	has_started = false
	interrupted = false
	terminal = false
	retune_left = 0.0
	flutter_time = 0.0
	music.pitch_scale = 1.0
	_set_damage(0.0)

## Called with the same shared car state on driver and navigator. Pausing or
## reconnecting preserves the playhead; a fresh run starts the intro again.
func update(delta: float, next_run: int, available: bool, driving: bool, speed: float, health: PackedFloat32Array, silent: bool) -> void:
	if next_run != run_id:
		reset(next_run)
	active = available
	muted = silent
	AudioServer.set_bus_mute(AudioServer.get_bus_index(bus_name), muted or not active)
	var lost := 0.0
	for value in health:
		lost += 1.0 - clampf(value, 0.0, 1.0)
	_set_damage(lost / maxf(health.size(), 1.0))
	if not driving and not terminal:
		crash(1.0)
		terminal = true
	if active and not terminal:
		flutter_time += delta
		retune_left = maxf(0.0, retune_left - delta)
		if absf(speed) >= MOVE_SPEED and retune_left == 0.0:
			if not has_started:
				music.play()
				static_noise.play()
				has_started = true
			interrupted = false
	var paused := not active or terminal or interrupted
	music.stream_paused = paused
	static_noise.stream_paused = paused
	burst.stream_paused = not active
	# Failing reception: pitch wobble and rapid dropouts grow with overall damage.
	var wobble := sin(flutter_time * 19.0) * sin(flutter_time * 7.3)
	music.pitch_scale = 1.0 + wobble * damage_amount * 0.035
	var dropout := pow(maxf(0.0, sin(flutter_time * 31.0)), 8.0) * damage_amount
	music.volume_db = MUSIC_DB - dropout * 18.0
	static_noise.volume_db = linear_to_db(maxf(0.00001, damage_amount * 0.09))

## Cut synchronously on impact, before any recovery fade/timer. Multiple damaged
## parts in one remote snapshot must not keep restarting the same static burst.
func crash(strength: float) -> void:
	if not has_started or not active or terminal:
		return
	music.stream_paused = true
	static_noise.stream_paused = true
	if not interrupted:
		burst.pitch_scale = lerpf(1.15, 0.8, clampf(strength, 0.0, 1.0))
		burst.play()
	interrupted = true
	retune_left = maxf(retune_left, lerpf(0.8, 1.5, clampf(strength, 0.0, 1.0)))

func _set_damage(amount: float) -> void:
	damage_amount = clampf(amount, 0.0, 1.0)
	distortion.drive = damage_amount * 0.85
	low_pass.cutoff_hz = lerpf(18000.0, 1300.0, sqrt(damage_amount))
	var index := AudioServer.get_bus_index(bus_name)
	AudioServer.set_bus_effect_enabled(index, 0, damage_amount > 0.001)
	AudioServer.set_bus_effect_enabled(index, 1, damage_amount > 0.001)

func _noise(one_shot: bool) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4917
	var seconds := 0.65 if one_shot else 2.0
	var frames := int(seconds * NOISE_RATE)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var low := 0.0
	for i in frames:
		var t := float(i) / NOISE_RATE
		var white := rng.randf_range(-1.0, 1.0)
		low = lerpf(low, white, 0.15)
		var value := (white - low) * 0.7
		if one_shot:
			# Electrical crack, sputtering static, and a falling tuning whistle.
			value = value * (0.4 + 0.6 * absf(sin(t * 73.0))) + sin(TAU * (1800.0 * t - 1000.0 * t * t)) * 0.13
			value *= exp(-t * 5.0) * minf(1.0, (seconds - t) * 40.0)
			value += white * exp(-t * 95.0) * 0.3
		data.encode_s16(i * 2, int(clampf(value, -1.0, 1.0) * 30000.0))
	var result := AudioStreamWAV.new()
	result.format = AudioStreamWAV.FORMAT_16_BITS
	result.mix_rate = NOISE_RATE
	result.data = data
	if not one_shot:
		result.loop_mode = AudioStreamWAV.LOOP_FORWARD
		result.loop_end = frames
	return result

func _exit_tree() -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index > 0:
		AudioServer.remove_bus(index)
