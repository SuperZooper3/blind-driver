extends SceneTree
## Persistent real key holds, explicit release, and a basic course at 5% speed.
var failures := 0
var directory := "/tmp/blind-driver-ai-smoke-%d" % OS.get_process_id()
var game: Node

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, label: String) -> void:
	print(("PASS: " if condition else "FAIL: ") + label)
	if not condition: failures += 1

func write_command(value: Dictionary, navigator := false) -> void:
	var target := directory.path_join("navigator") if navigator else directory
	var file := FileAccess.open(target.path_join("input.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func frames(count: int) -> void:
	for _i in count: await physics_frame

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(directory.path_join("navigator"))
	var config := {"directory": directory, "role": "driver", "speed_percent": 5, "seed": 123,
		"shared_screens": true, "navigator_directory": directory.path_join("navigator"),
		"course": "basic", "readable_ui": true, "capture_fps": 6, "max_sim_seconds": 10, "max_action_age_sim": 1}
	var file := FileAccess.open(directory.path_join("config.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(config))
	file.close()
	OS.set_environment("BLIND_DRIVER_AI_CONFIG", directory.path_join("config.json"))
	OS.set_environment("BLIND_DRIVER_RECORDS_PATH", directory.path_join("records.cfg"))
	game = load("res://scripts/main.gd").new()
	root.add_child(game)
	await process_frame
	game._start("split")
	check(is_equal_approx(Engine.time_scale, 0.05), "configured 5% simulation speed")
	check(game.world.basic_course, "basic course enabled")
	check(game.session.role == "local" and not game.car.remote and game.ai_capture.peer != null, "both seats share one car without networking")
	check(game.world.thorn_at(Vector3(100, 0, 100)), "basic course restores deep roadside thorns")
	check(not game.world.thorn_at(Vector3(0, 0, 0)), "road center remains clear of thorns")
	check(game.ui.readable_hud != null and game.ui.map.readable_ui, "readable HUD and larger map enabled")
	# North-up map orientation must not rotate the road when the car turns.
	var north_before: Vector2 = game.ui.map._project(game.car.global_position + Vector3(0, 0, -10))
	game.car.rotation.y = 1.0
	check(game.ui.map._project(game.car.global_position + Vector3(0, 0, -10)).is_equal_approx(north_before), "map stays north up while car heading changes")
	game.car.rotation.y = 0.0
	for road in game.world.roads:
		check(not road.danger, "basic route has no fatal branch")
		for hazard in road.hazards:
			check(hazard.kind == "rock", "only basic static obstacles")
	write_command({"type": "start", "sequence": 1})
	write_command({"type": "start", "sequence": 1}, true)
	await frames(4)
	game.car.impacted.emit(0.5)
	check(game.ui.readable_hud.sounds[-1].text.begins_with("CRASH"), "crash sound has a human-visible text caption")
	write_command({"type": "keys", "sequence": 2, "hold": ["W", "A"], "tap": ["H"], "observation_sim": 0})
	await frames(4)
	check(Input.is_action_pressed("accelerate") and Input.is_action_pressed("steer_left"), "driver keys use normal Input map")
	check(game.car.headlights[0].visible, "driver H tap dispatched")
	# Emulate the key releases Godot generates when its window loses focus,
	# without replacing the harness's persistent requested hold.
	game.ai_capture._key("W", false)
	game.ai_capture._key("A", false)
	await frames(4)
	check(Input.is_action_pressed("accelerate") and Input.is_action_pressed("steer_left") and game.car.throttle > 0.0, "driver hold restores actual inputs after focus loss")
	check(game.ai_capture.input_reassertions >= 2, "focus-loss restoration is measured")
	var before: float = game.ai_capture.sim_time
	# Wait beyond BOTH the old maximum two-second lease and the observation-age
	# bound. That bound validates new commands; it must not expire held keys.
	await frames(2700)
	check(game.ai_capture.sim_time > before + 2, "simulation continues without model responses")
	check(Input.is_action_pressed("accelerate") and Input.is_action_pressed("steer_left") and not Input.is_action_pressed("handbrake"), "driver holds persist until replaced, without automatic braking")
	write_command({"type": "keys", "sequence": 3, "hold": [], "tap": [], "observation_sim": -20})
	await frames(4)
	check(game.ai_capture.last_error == "stale_observation", "stale action rejected")
	check(Input.is_action_pressed("accelerate") and Input.is_action_pressed("steer_left"), "rejected command preserves the current hold")
	write_command({"type": "keys", "sequence": 4, "hold": ["W"], "tap": [], "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(Input.is_action_pressed("accelerate") and not Input.is_action_pressed("steer_left"), "next instruction releases omitted keys and keeps W held")
	write_command({"type": "keys", "sequence": 5, "hold": [], "tap": [], "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(not Input.is_action_pressed("accelerate") and not Input.is_action_pressed("handbrake"), "empty hold releases all keys without automatic braking")
	write_command({"type": "keys", "sequence": 6, "hold": ["W", "D"], "tap": [], "steering_pulse_sim": 0.1, "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(Input.is_action_pressed("accelerate") and Input.is_action_pressed("steer_right"), "explicit steering pulse begins with normal keys")
	await frames(150)
	check(Input.is_action_pressed("accelerate") and not Input.is_action_pressed("steer_right"), "steering pulse releases only steering after game-time deadline")
	write_command({"type": "keys", "sequence": 7, "hold": [], "tap": [], "steering_pulse_sim": 0.2, "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(game.ai_capture.last_error == "invalid_steering_pulse" and Input.is_action_pressed("accelerate"), "invalid pulse is rejected without changing holds")
	var instrument_text: Dictionary = game.ui.readable_hud.instrument_text()
	check(instrument_text.size() == 5 and instrument_text.speed.ends_with(" km/h") and instrument_text.trip.ends_with(" m"), "accessibility exports only the five rendered instrument strings")
	# Isolate key persistence from the newly lethal roadside course.
	game.car.freeze = true
	game.car.position = Vector3(0, 5, 0)
	var navigator: Node = game.ai_capture.peer
	check(is_equal_approx(game.ai_capture.sim_time, navigator.sim_time), "both seats use the same simulation clock")
	write_command({"type": "keys", "sequence": 6, "hold": [], "tap": ["M", "C"], "observation_sim": game.ai_capture.sim_time}, true)
	await frames(4)
	check(game.ui.map_open and game.chase_camera, "navigator M and C keys reach normal UI handlers")
	write_command({"type": "keys", "sequence": 6, "hold": [], "tap": ["M"], "observation_sim": game.ai_capture.sim_time}, true)
	await frames(4)
	check(game.ui.map_open, "duplicate sequence cannot toggle twice")
	check(game.ui.map_panel.position.x >= game.ui.root.size.x * 0.5, "navigator map cannot cover the driver seat")
	write_command({"type": "keys", "sequence": 7, "hold": ["W"], "tap": [], "observation_sim": game.ai_capture.sim_time}, true)
	await frames(4)
	check(navigator.last_error == "invalid_held_key", "navigator cannot drive")
	write_command({"type": "keys", "sequence": 8, "hold": ["B"], "tap": [], "observation_sim": game.ai_capture.sim_time}, true)
	await frames(4)
	navigator._key("B", false)
	await frames(2700)
	check(Input.is_action_pressed("look_back"), "navigator look-back also stays held until replaced")
	write_command({"type": "stop", "sequence": 9, "reason": "operator_stop"})
	await frames(4)
	check(not Input.is_action_pressed("look_back") and game.ai_capture.held.is_empty() and navigator.held.is_empty(), "ending the run releases held keys")
	game.ai_capture.active = true
	game.car.recovery_grace = 0
	game.car.reset_pending = false
	game.car.wear_tires(15, 1.1)
	await frames(5)
	check(game.car.punctured_tires == 15 and game.car.run_state == "game_over", "all four thorn punctures end the basic course")
	check(game.car.crash_reason.contains("Thorns"), "thorn failure has an explicit cause")
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
