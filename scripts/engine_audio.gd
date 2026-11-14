extends AudioStreamPlayer
## Synthesized motor + tire noise: no downloaded audio or runtime dependencies.

var car: RigidBody3D
var phase := 0.0
var smoothed_rpm := 32.0
var rng := RandomNumberGenerator.new()
var playback: AudioStreamGeneratorPlayback
var enabled := true
## 0 = healthy; higher values make the motor misfire and rattle (exposed, damaged engine).
var roughness := 0.0
var misfire := 1.0

func _ready() -> void:
	playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050.0
	generator.buffer_length = 0.12
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
	var amplitude := 0.22 + absf(car.throttle) * 0.12
	var tire_volume := minf(speed / 30.0, 1.0) * (0.12 if car.on_road else 0.32)
	for _i in playback.get_frames_available():
		var last_phase := phase
		phase = fmod(phase + smoothed_rpm / 22050.0, 1.0)
		if roughness > 0.0 and phase < last_phase:
			# Each engine cycle may misfire and come in weaker.
			misfire = 1.0 - (rng.randf() * roughness * 2.2 if rng.randf() < roughness * 1.5 else 0.0)
		var motor := (sin(phase * TAU) * 0.55 + sin(phase * TAU * 2.0) * 0.28 + sin(phase * TAU * 4.0) * 0.12) * misfire
		motor += rng.randf_range(-1.0, 1.0) * roughness * 0.35
		var sample := (motor * amplitude + rng.randf_range(-1.0, 1.0) * tire_volume) if enabled else 0.0
		playback.push_frame(Vector2(sample, sample))
