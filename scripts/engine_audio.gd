extends AudioStreamPlayer
## Tonal engine revs only. Coasting and idling are silent; no rolling hiss.

const MIX_RATE := 22050.0

var car: RigidBody3D
var phase := 0.0
var smoothed_rpm := 32.0
var rng := RandomNumberGenerator.new()
var playback: AudioStreamGeneratorPlayback
var enabled := true
## 0 = healthy; higher values make the revving motor misfire.
var roughness := 0.0
var misfire := 1.0
var rev_gain := 0.0

func _ready() -> void:
	playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = 0.06
	stream = generator
	volume_db = -19.0
	play()
	playback = get_stream_playback()

func _process(delta: float) -> void:
	if not is_instance_valid(car) or playback == null:
		return
	var speed: float = absf(car.signed_speed)
	var gear: int = mini(4, int(speed / 7.0))
	var target := 30.0 + fmod(speed, 7.0) * 5.0 + gear * 3.5 + absf(car.throttle) * 14.0
	smoothed_rpm = lerpf(smoothed_rpm, target, 1.0 - exp(-delta * 7.0))
	var rev: float = absf(car.throttle) if enabled else 0.0
	for _i in playback.get_frames_available():
		var sample := _rev_sample(rev)
		playback.push_frame(Vector2(sample, sample))

func _rev_sample(rev: float) -> float:
	# A 15 ms envelope prevents clicks when the accelerator is pressed/released.
	rev_gain = move_toward(rev_gain, clampf(rev, 0.0, 1.0), 1.0 / (MIX_RATE * 0.015))
	var last_phase := phase
	phase = fmod(phase + smoothed_rpm / MIX_RATE, 1.0)
	if phase < last_phase:
		# Damaged engines can miss a firing cycle without adding broadband static.
		misfire = 1.0 - rng.randf() * roughness * 0.8
	var motor := sin(phase * TAU) * 0.55 + sin(phase * TAU * 2.0) * 0.28 + sin(phase * TAU * 4.0) * 0.12
	return motor * misfire * rev_gain * 0.34
