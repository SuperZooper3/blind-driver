extends SceneTree
## Exercise the real main/car wiring as well as the audio-thread loop boundary.
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	var car = game.car
	car.freeze = true
	car.set_physics_process(false)
	var radio = game.radio
	game._update_radio(0.016)
	check(not radio.music.playing, "radio is silent in the start menu")
	game._start("solo")
	car.signed_speed = 0.0
	game._update_radio(0.016)
	check(not radio.music.playing, "starting a ride waits for movement")
	game.intro_enabled = true
	game._update_intro()
	car.signed_speed = 2.0
	game._update_radio(0.016)
	check(not radio.music.playing, "bank opening keeps radio silent even if the car rolls")
	game.intro.time = game.intro.DURATION
	car.signed_speed = -2.0
	game._update_radio(0.016)
	check(radio.music.playing and not radio.music.stream_paused, "forward or reverse movement starts the music")
	check(absf(radio.music.stream.get_length() - 124.0) < 0.01, "music ends at exactly 2:04")
	check(radio.music.stream.loop and radio.music.stream.loop_offset == 13.5, "loop continues at 0:13.5 after the baked 0:13–0:13.5 crossfade")
	# Use a real audio clock, not simulated frame deltas, to cross the boundary twice.
	for iteration in 2:
		radio.music.play(123.8)
		await create_timer(0.65).timeout
		var position: float = radio.music.get_playback_position()
		check(position >= 13.5 and position < 15.0, "audio-thread loop %d returns to the music without ending" % (iteration + 1))
	game.ui.show_menu(true)
	game._update_radio(0.016)
	check(radio.music.stream_paused, "menu pauses the music")
	game.ui.show_menu(false)
	game.session.recovering = true
	game._update_radio(0.016)
	check(radio.music.stream_paused, "connection recovery pauses the music")
	game.session.recovering = false
	game.audio_muted = true
	game._update_radio(0.016)
	check(AudioServer.is_bus_mute(AudioServer.get_bus_index(radio.bus_name)), "V mute covers music and radio noise")
	game.audio_muted = false
	game._update_radio(0.016)
	car.impacted.emit(0.6)
	check(radio.music.stream_paused and radio.burst.playing, "crash signal immediately cuts music and plays radio static")
	car.signed_speed = 0.0
	game._update_radio(2.0)
	check(radio.music.stream_paused, "radio waits for movement after the crash")
	car.signed_speed = 2.0
	game._update_radio(0.016)
	check(not radio.music.stream_paused, "surviving the crash and driving resumes music")
	car.damage.set_part(car.damage.ENGINE, 0.5)
	game._update_radio(0.016)
	var mild: float = radio.distortion.drive
	var cutoff: float = radio.low_pass.cutoff_hz
	car.damage.set_part(car.damage.ENGINE, 0.1)
	car.damage.set_part(car.damage.WINDSHIELD, 0.2)
	game._update_radio(0.016)
	check(radio.distortion.drive > mild and radio.low_pass.cutoff_hz < cutoff, "more damage increases garbling and narrows reception")
	car.damage.reset()
	game._update_radio(0.016)
	check(radio.damage_amount == 0.0 and not AudioServer.is_bus_effect_enabled(AudioServer.get_bus_index(radio.bus_name), 0), "repairs restore clean music")
	car.remote = true
	var mirrored: Array = car.damage.health_array()
	mirrored[car.damage.FRONT_BUMPER] = 0.5
	car.damage.set_health_array(mirrored)
	check(radio.music.stream_paused, "navigator's mirrored crash cuts its radio too")
	car.remote = false
	game._update_radio(2.0)
	car.finish_run("Test crash")
	game._update_radio(0.016)
	check(radio.terminal and radio.music.stream_paused and radio.burst.playing, "terminal failure cuts the radio with static")
	game._update_radio(10.0)
	check(radio.music.stream_paused, "Game Over cannot resume the radio")
	game._restart_run()
	check(not radio.music.playing and not radio.burst.playing and radio.damage_amount == 0.0, "new ride immediately stops old music/static and clears distortion")
	car.reset_pending = false
	car.recovery_grace = 0
	car.signed_speed = 2.0
	game._update_radio(0.016)
	check(radio.music.playing and radio.music.get_playback_position() < 1.0, "new ride starts the intro from zero")
	var name: StringName = radio.bus_name
	game.queue_free()
	await process_frame
	check(AudioServer.get_bus_index(name) == -1, "radio removes its private audio bus on exit")
	quit(1 if failed else 0)
