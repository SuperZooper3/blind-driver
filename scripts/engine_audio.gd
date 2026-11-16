extends AudioStreamPlayer
## A baked tonal loop runs on the audio thread, even during terrain/frame stalls.
## Coasting and idling remain silent; damage modulates revs without adding static.

const MIX_RATE := 22050
const LOOP_FRAMES := 690
const BASE_HZ := float(MIX_RATE) / LOOP_FRAMES
var car: RigidBody3D
var smoothed_rpm := 32.0
var enabled := true
var roughness := 0.0
var rev_gain := 0.0
var flutter_phase := 0.0

func _ready() -> void:
	playback_type = AudioServer.PLAYBACK_TYPE_SAMPLE if OS.has_feature("web") else AudioServer.PLAYBACK_TYPE_STREAM
	stream = build_loop()
	volume_db = -80.0
	play()

static func build_loop() -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(LOOP_FRAMES * 2)
	for i in LOOP_FRAMES:
		var phase := float(i) / LOOP_FRAMES * TAU
		var value := (sin(phase) * 0.55 + sin(phase * 2.0) * 0.28 + sin(phase * 4.0) * 0.12) * 0.34
		data.encode_s16(i * 2, roundi(value * 32767.0))
	var tone := AudioStreamWAV.new()
	tone.format = AudioStreamWAV.FORMAT_16_BITS
	tone.mix_rate = MIX_RATE
	tone.data = data
	tone.loop_mode = AudioStreamWAV.LOOP_FORWARD
	tone.loop_end = LOOP_FRAMES
	return tone

func _process(delta: float) -> void:
	if not is_instance_valid(car): return
	var speed: float = absf(car.signed_speed)
	var gear: int = mini(4, int(speed / 7.0))
	var target := 30.0 + fmod(speed, 7.0) * 5.0 + gear * 3.5 + absf(car.throttle) * 14.0
	smoothed_rpm = lerpf(smoothed_rpm, target, 1.0 - exp(-delta * 7.0))
	flutter_phase = fposmod(flutter_phase + delta * 19.0, TAU)
	var misfire := 1.0 - clampf(roughness, 0.0, 1.0) * 0.6 * pow(maxf(0.0, sin(flutter_phase)), 4.0)
	rev_gain = move_toward(rev_gain, absf(car.throttle) if enabled else 0.0, delta / 0.015)
	pitch_scale = smoothed_rpm / BASE_HZ
	volume_db = -19.0 + linear_to_db(maxf(0.00001, rev_gain * misfire))
	stream_paused = rev_gain == 0.0
