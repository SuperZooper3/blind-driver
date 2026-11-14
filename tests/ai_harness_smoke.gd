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

func write_command(value: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join("input.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func frames(count: int) -> void:
	for _i in count: await physics_frame

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var config := {"directory": directory, "role": "driver", "speed_percent": 5, "seed": 123,
		"course": "basic", "capture_fps": 6, "max_sim_seconds": 10, "max_action_age_sim": 1}
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
	check(not game.world.thorn_at(Vector3(100, 0, 100)), "basic course has no thorns")
	for road in game.world.roads:
		check(not road.danger, "basic route has no fatal branch")
		for hazard in road.hazards:
			check(hazard.kind == "rock", "only basic static obstacles")
	write_command({"type": "start", "sequence": 1})
	await frames(4)
	write_command({"type": "keys", "sequence": 2, "hold": ["W", "A"], "tap": ["H"], "observation_sim": 0})
	await frames(4)
	check(Input.is_action_pressed("accelerate") and Input.is_action_pressed("steer_left"), "driver keys use normal Input map")
	check(game.car.headlights[0].visible, "driver H tap dispatched")
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
	game.ai_capture.options.role = "navigator"
	write_command({"type": "keys", "sequence": 6, "hold": [], "tap": ["M", "C"], "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(game.ui.map_open and game.chase_camera, "navigator M and C keys reach normal UI handlers")
	write_command({"type": "keys", "sequence": 6, "hold": [], "tap": ["M"], "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(game.ui.map_open, "duplicate sequence cannot toggle twice")
	write_command({"type": "keys", "sequence": 7, "hold": ["W"], "tap": [], "observation_sim": game.ai_capture.sim_time})
	await frames(4)
	check(game.ai_capture.last_error == "invalid_held_key", "navigator cannot drive")
	write_command({"type": "keys", "sequence": 8, "hold": ["B"], "tap": [], "observation_sim": game.ai_capture.sim_time})
	await frames(2700)
	check(Input.is_action_pressed("look_back"), "navigator look-back also stays held until replaced")
	write_command({"type": "stop", "sequence": 9, "reason": "operator_stop"})
	await frames(4)
	check(not Input.is_action_pressed("look_back") and game.ai_capture.held.is_empty(), "ending the run releases held keys")
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
