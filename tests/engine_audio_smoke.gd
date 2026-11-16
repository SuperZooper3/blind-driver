extends SceneTree
const Motor = preload("res://scripts/engine_audio.gd")
const Siren = preload("res://scripts/police_siren.gd")
var failed := false

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok

func _initialize() -> void:
	call_deferred("run")

func check_loop(tone: AudioStreamWAV, label: String) -> void:
	var stride := 4 if tone.stereo else 2
	check(tone.loop_mode == AudioStreamWAV.LOOP_FORWARD and tone.loop_end * stride == tone.data.size(), label + " uses a complete audio-thread loop")
	var energy := 0.0
	var peak := 0.0
	var max_step := 0.0
	for i in tone.loop_end:
		var sample := tone.data.decode_s16(i * stride) / 32767.0
		var next := tone.data.decode_s16(((i + 1) % tone.loop_end) * stride) / 32767.0
		energy += sample * sample
		peak = maxf(peak, absf(sample))
		max_step = maxf(max_step, absf(sample - next))
	var seam := absf(tone.data.decode_s16(0) - tone.data.decode_s16((tone.loop_end - 1) * stride)) / 32767.0
	check(energy / tone.loop_end > 0.01 and peak < 0.8 and seam <= max_step, label + " is audible, unclipped, and has no discontinuity at its loop seam")

func run() -> void:
	check_loop(preload("res://scripts/bank_intro.gd").build_bell_loop(), "Bank alarm")
	check_loop(Motor.build_loop(), "Engine")
	check_loop(Siren.build_loop(), "Siren")
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.world.set_process(false)
	game.car.freeze = true
	game.car.set_physics_process(false)
	var motor = game.motor
	motor.set_process(false)
	motor.enabled = true
	game.car.throttle = 0.0
	motor._process(1.0)
	check(motor.stream_paused, "idling and coasting are silent")
	game.car.throttle = 1.0
	motor._process(0.1)
	check(not motor.stream_paused and motor.volume_db > -25.0, "throttle produces tonal revs")
	# Capture actual mixed frames while the render/main thread is deliberately blocked.
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(0, capture)
	await create_timer(0.15).timeout
	capture.clear_buffer()
	OS.delay_msec(400)
	var samples := capture.get_buffer(capture.get_frames_available())
	var quiet_blocks := 0
	for start in range(0, samples.size() - 512, 512):
		var energy := 0.0
		for i in range(start, start + 512): energy += samples[i].length_squared()
		if energy < 0.00001: quiet_blocks += 1
	check(samples.size() > 4000 and quiet_blocks == 0, "engine mixing survives a 400 ms main-thread stall without silent buffer underruns")
	AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)
	motor.roughness = 1.0
	for i in 10000: motor._process(60.0)
	check(is_finite(motor.pitch_scale) and motor.flutter_phase >= 0.0 and motor.flutter_phase < TAU, "long-running damaged engine keeps bounded phase and valid pitch")
	game.car.throttle = 0.0
	motor._process(0.1)
	check(motor.stream_paused, "broken engines also become silent when throttle is released")
	game.car.throttle = -1.0
	motor._process(0.1)
	check(not motor.stream_paused, "reverse throttle restarts the loop")
	motor.enabled = false
	motor._process(0.1)
	check(motor.stream_paused, "mute/menu gate silences the engine")
	var siren = game.siren
	siren.enabled = true
	game.police.elapsed = 86400.0 * 30.0
	siren._process(0.1)
	check(is_finite(siren.pitch_scale) and siren.pitch_scale >= 620.0 / Siren.BASE_HZ and siren.pitch_scale <= 1020.0 / Siren.BASE_HZ, "siren remains in pitch range after a month of elapsed chase time")
	check(siren.right_voice.pitch_scale == siren.pitch_scale and siren.right_voice.stream_paused == siren.stream_paused, "stereo siren voices share pitch and pause state")
	var right_voice = weakref(siren.right_voice)
	game.queue_free()
	await process_frame
	check(right_voice.get_ref() == null, "siren releases its second voice on exit")
	quit(1 if failed else 0)
