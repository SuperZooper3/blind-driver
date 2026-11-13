extends AudioStreamPlayer
## A local stereo siren driven by the shared patrol clock and physical separation.
var pursuit: Node3D
var car: RigidBody3D
var enabled := false
var playback: AudioStreamGeneratorPlayback
var phase := 0.0
var gain := 0.0
func _ready() -> void:
	playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050
	generator.buffer_length = 0.12
	stream = generator
	volume_db = -15
	play()
	playback = get_stream_playback()
func _process(delta: float) -> void:
	if playback == null or not is_instance_valid(pursuit): return
	gain = move_toward(gain, pursuit.siren_gain() if enabled else 0.0, delta * 3.0)
	var fast: bool = pursuit.gap < 65.0
	var sweep := (sin(pursuit.elapsed * (7.0 if fast else 2.2)) + 1.0) * 0.5
	var frequency := lerpf(620, 1020, sweep)
	var relative: Vector3 = pursuit.global_position - car.global_position
	var pan := clampf(relative.normalized().dot(car.global_basis.x), -0.7, 0.7)
	for _i in playback.get_frames_available():
		phase = fmod(phase + frequency / 22050.0, 1.0)
		var sample := (sin(phase * TAU) + sin(phase * TAU * 3) * 0.15) * gain * 0.45
		playback.push_frame(Vector2(sample * (1.0 - pan * 0.5), sample * (1.0 + pan * 0.5)))

func _exit_tree() -> void:
	stop()
	playback = null
