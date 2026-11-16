extends AudioStreamPlayer
## The audio thread loops a seamless tone; frames only control pitch/gain/pan.
const MIX_RATE := 22050
const LOOP_FRAMES := 30
const BASE_HZ := float(MIX_RATE) / LOOP_FRAMES
var pursuit: Node3D
var car: RigidBody3D
var enabled := false
var gain := 0.0
var right_voice: AudioStreamPlayer

func _ready() -> void:
	# Two pre-panned channels preserve stereo on Web Sample playback, which
	# bypasses AudioEffectPanner. Neither voice needs a per-frame sample buffer.
	playback_type = AudioServer.PLAYBACK_TYPE_SAMPLE if OS.has_feature("web") else AudioServer.PLAYBACK_TYPE_STREAM
	stream = build_loop()
	volume_db = -80.0
	right_voice = AudioStreamPlayer.new()
	right_voice.playback_type = playback_type
	right_voice.stream = build_loop(true)
	right_voice.volume_db = -80.0
	add_child(right_voice)
	play()
	right_voice.play()

static func build_loop(right_channel: bool = false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(LOOP_FRAMES * 4)
	for i in LOOP_FRAMES:
		var phase := float(i) / LOOP_FRAMES * TAU
		var value := (sin(phase) + sin(phase * 3.0) * 0.15) * 0.45
		data.encode_s16(i * 4 + (2 if right_channel else 0), roundi(value * 32767.0))
	var tone := AudioStreamWAV.new()
	tone.format = AudioStreamWAV.FORMAT_16_BITS
	tone.mix_rate = MIX_RATE
	tone.stereo = true
	tone.data = data
	tone.loop_mode = AudioStreamWAV.LOOP_FORWARD
	tone.loop_end = LOOP_FRAMES
	return tone

func _process(delta: float) -> void:
	if not is_instance_valid(pursuit) or not is_instance_valid(car): return
	gain = move_toward(gain, pursuit.siren_gain() if enabled else 0.0, delta * 3.0)
	var fast: bool = pursuit.gap < 65.0
	var sweep := (sin(fposmod(pursuit.elapsed * (7.0 if fast else 2.2), TAU)) + 1.0) * 0.5
	pitch_scale = lerpf(620, 1020, sweep) / BASE_HZ
	var relative: Vector3 = pursuit.global_position - car.global_position
	var pan := clampf(relative.normalized().dot(car.global_basis.x), -0.7, 0.7)
	volume_db = -15.0 + linear_to_db(maxf(gain * (1.0 - pan * 0.5), 0.00001))
	right_voice.volume_db = -15.0 + linear_to_db(maxf(gain * (1.0 + pan * 0.5), 0.00001))
	right_voice.pitch_scale = pitch_scale
	stream_paused = gain == 0.0
	right_voice.stream_paused = stream_paused

func _exit_tree() -> void:
	stop()
	if is_instance_valid(right_voice): right_voice.stop()
