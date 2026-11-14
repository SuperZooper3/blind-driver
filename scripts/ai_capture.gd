extends Node
## Optional file-based screenshot/keyboard adapter. Models only receive JPEGs;
## telemetry is for the recorder/evaluator. No alternate driving controller.

const KEYS := {"W": KEY_W, "S": KEY_S, "A": KEY_A, "D": KEY_D, "SPACE": KEY_SPACE, "M": KEY_M, "C": KEY_C, "B": KEY_B, "H": KEY_H}
var game: Node
var options: Dictionary
var leader: Node
var peer: Node
var active := false
var sim_time := 0.0
var directory := ""
var held: Array = []
var steering_release_sim := -1.0
var sequence := -1
var applied_sequence := -1
var last_error := ""
var finished_reason := ""
var frame_index := 0
var next_capture := 0.0
var capture_due := false
var progress := 0.0
var offroad_seconds := 0.0
var impact_events := 0
var impact_total := 0.0
var input_reassertions := 0
var frames: FileAccess
var events: FileAccess

static func read_options() -> Dictionary:
	var path := OS.get_environment("BLIND_DRIVER_AI_CONFIG")
	if path.is_empty(): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not parsed.has_all(["directory", "role", "speed_percent", "seed", "course", "capture_fps", "max_sim_seconds"]):
		push_error("Invalid AI harness configuration")
		Engine.get_main_loop().quit(2)
		return {}
	if str(parsed.role) not in ["driver", "navigator"] or float(parsed.speed_percent) < 1.0 or float(parsed.speed_percent) > 100.0 or float(parsed.capture_fps) < 1.0 or float(parsed.capture_fps) > 30.0 or str(parsed.course) not in ["basic", "standard"]:
		push_error("AI harness configuration is outside supported bounds")
		Engine.get_main_loop().quit(2)
		return {}
	return parsed

func _ready() -> void:
	process_physics_priority = -100
	directory = str(options.directory)
	DirAccess.make_dir_recursive_absolute(directory.path_join("frames"))
	frames = FileAccess.open(directory.path_join("frames.jsonl"), FileAccess.WRITE)
	events = FileAccess.open(directory.path_join("input_events.jsonl"), FileAccess.WRITE)
	game.session.wall_clock_intervals = not options.get("shared_screens", false)
	game.audio_muted = true
	game.car.driving_enabled = false
	game.car.impacted.connect(func(strength: float):
		impact_events += 1
		impact_total += strength)
	if DisplayServer.get_name() != "headless" and leader == null:
		RenderingServer.viewport_set_update_mode(get_viewport().get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ALWAYS)
		RenderingServer.frame_post_draw.connect(_capture)
	_event("ready", {"pid": OS.get_process_id(), "speed_percent": options.speed_percent})

func _process(_delta: float) -> void:
	_read_command()
	_restore_held()
	if leader != null: return
	var now := Time.get_ticks_usec() / 1000000.0
	if now >= next_capture:
		next_capture = now + 1.0 / float(options.capture_fps)
		capture_due = true
		if DisplayServer.get_name() == "headless":
			_capture()
		else:
			# macOS can stop scheduling redraws for an occluded game window even
			# while physics runs. Force a real rendered frame at capture cadence.
			RenderingServer.force_draw(false)

func _physics_process(delta: float) -> void:
	_restore_held()
	if leader != null:
		sim_time = leader.sim_time
		return
	if steering_release_sim >= 0.0 and sim_time >= steering_release_sim:
		var remaining := held.filter(func(key): return key not in ["A", "D"])
		_set_held(remaining)
		steering_release_sim = -1.0
		_event("steering_pulse_finished", {"hold": held.duplicate()})
	if active and game.car.run_state != "game_over":
		sim_time += delta
		if not game.car.remote:
			var road_distance: float = game.world.road_distance(game.car.global_position)
			if road_distance > 4.6: offroad_seconds += delta
			# Basic roads continue toward -Z. This is deliberately named forward
			# progress, not odometer distance or branch-aware route completion.
			if road_distance <= 6.0 and game.car.grounded_wheels > 0:
				progress = maxf(progress, 12.0 - game.car.global_position.z)
		if sim_time >= float(options.max_sim_seconds):
			_finish("time_limit")
	if active and game.car.run_state == "game_over": _finish("game_over")
	if not game.car.remote:
		game.car.driving_enabled = active and not game.ui.in_menu and game.session.can_drive() and game.car.run_state == "driving"

func _finish(reason: String) -> void:
	active = false
	finished_reason = reason
	_set_held([])
	steering_release_sim = -1.0
	if not game.car.remote: game.car.freeze = true
	_event("finished", {"reason": reason})
	if peer != null and peer.active: peer._finish(reason)
	if leader != null and leader.active: leader._finish(reason)

func _read_command() -> void:
	var path := directory.path_join("input.json")
	if not FileAccess.file_exists(path): return
	var command: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not command is Dictionary: return
	var incoming := int(command.get("sequence", -1))
	if incoming <= sequence: return
	sequence = incoming
	last_error = ""
	var kind := str(command.get("type", ""))
	if kind == "start" and not active and finished_reason.is_empty():
		active = true
		sim_time = 0.0
		_event("started", {})
		return
	if kind == "stop":
		if finished_reason.is_empty(): _finish(str(command.get("reason", "operator_stop")))
		return
	if kind != "keys" or not active:
		_reject("episode_not_active")
		return
	var hold: Variant = command.get("hold", null)
	var tap: Variant = command.get("tap", null)
	var observed := float(command.get("observation_sim", -1000))
	if not hold is Array or not tap is Array:
		_reject("invalid_controls")
		return
	if not is_finite(observed) or sim_time - observed > float(options.get("max_action_age_sim", 5.0)) or observed > sim_time + 0.1:
		_reject("stale_observation")
		return
	var hold_allowed: Array = ["W", "S", "A", "D", "SPACE"] if options.role == "driver" else ["B"]
	var tap_allowed: Array = ["H"] if options.role == "driver" else ["M", "C"]
	for key in hold:
		if key not in hold_allowed:
			_reject("invalid_held_key")
			return
	for key in tap:
		if key not in tap_allowed:
			_reject("invalid_tapped_key")
			return
	if hold.size() != _unique_count(hold) or tap.size() != _unique_count(tap):
		_reject("duplicate_keys")
		return
	if ("W" in hold and "S" in hold) or ("A" in hold and "D" in hold) or ("B" in hold and "M" in tap):
		_reject("conflicting_keys")
		return
	var pulse: Variant = command.get("steering_pulse_sim", null)
	if pulse != null:
		if options.role != "driver" or not ("A" in hold or "D" in hold) or not (pulse is float or pulse is int) or not is_finite(float(pulse)) or float(pulse) < 0.05 or float(pulse) > 1.0:
			_reject("invalid_steering_pulse")
			return
	steering_release_sim = sim_time + float(pulse) if pulse != null else -1.0
	_set_held(hold)
	for key in tap:
		_key(str(key), true)
		_key.call_deferred(str(key), false)
	applied_sequence = sequence
	_event("keys_applied", {"hold": held.duplicate(), "tap": tap, "observation_sim": observed, "hold_policy": "until_replaced"})

func _unique_count(values: Array) -> int:
	var unique: Dictionary = {}
	for value in values: unique[value] = true
	return unique.size()

func _reject(reason: String) -> void:
	last_error = reason
	_event("rejected", {"reason": reason})

func _key(key: String, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEYS[key]
	event.keycode = KEYS[key]
	event.pressed = pressed
	Input.parse_input_event(event)

func _set_held(keys: Array) -> void:
	for key in held:
		if key not in keys: _key(str(key), false)
	for key in keys:
		if key not in held: _key(str(key), true)
	held = keys.duplicate()

func _restore_held() -> void:
	# Godot clears keyboard state on window focus loss. Our role-local lease
	# still owns these held keys until the next command, so restore normal key
	# events before physics/capture. Never replay taps or touch the other seat.
	if not active: return
	for key in held:
		if not Input.is_physical_key_pressed(KEYS[key]):
			_key(str(key), true)
			input_reassertions += 1

func _event(kind: String, extra: Dictionary) -> void:
	var value := {"event": kind, "role": options.role, "sequence": sequence, "sim_time": sim_time, "unix_time": Time.get_unix_time_from_system()}
	value.merge(extra)
	events.store_line(JSON.stringify(value))
	events.flush()

func _capture() -> void:
	if not capture_due: return
	capture_due = false
	var started_us := Time.get_ticks_usec()
	var stamp := Time.get_unix_time_from_system()
	var picture: Image
	if DisplayServer.get_name() != "headless":
		picture = get_viewport().get_texture().get_image()
		if picture.is_empty():
			push_error("AI screenshot capture failed")
			_finish("capture_error")
			return
	if peer != null:
		# One GPU readback, one rendered frame, one physics state. Crop only the
		# two complete seats; both already contain their own game-rendered HUD.
		if picture != null and picture.get_size() != Vector2i(2560, 800):
			push_error("Shared capture must render at 2560x800")
			_finish("capture_error")
			return
		peer.sim_time = sim_time
		peer.progress = progress
		peer.offroad_seconds = offroad_seconds
		peer._save_capture(picture.get_region(Rect2i(1280, 0, 1280, 800)) if picture != null else null, started_us, stamp)
		_save_capture(picture.get_region(Rect2i(0, 0, 1280, 800)) if picture != null else null, started_us, stamp)
	else:
		_save_capture(picture, started_us, stamp)

func _save_capture(picture: Image, started_us: int, stamp: float) -> void:
	var name := ""
	if picture != null:
		name = "frames/%07d.jpg" % frame_index
		if picture.save_jpg(directory.path_join(name), 0.88) != OK:
			_finish("capture_error")
			return
	var car: RigidBody3D = game.car
	var pressed_keys: Array = []
	for key in held:
		if Input.is_physical_key_pressed(KEYS[key]): pressed_keys.append(key)
	var connected: bool = game.session.navigator_id != 0 if options.role == "driver" else game.session.graph_received and game.session.snapshots_received > 0
	if options.get("shared_screens", false): connected = game.session.role == "local"
	var data := {
		"frame": frame_index, "image": name, "role": options.role, "unix_time": stamp,
		"image_size": [picture.get_width(), picture.get_height()] if picture != null else [],
		"monotonic_us": started_us, "sim_time": sim_time, "world_time": game.world.challenge_time,
		"active": active, "connected": connected, "finished_reason": finished_reason,
		"sequence": sequence, "applied_sequence": applied_sequence, "input_error": last_error,
		"held": held, "hold_policy": "until_replaced",
		"steering_release_sim": steering_release_sim,
		"pressed_keys": pressed_keys, "input_reassertions": input_reassertions,
		"engine_pid": OS.get_process_id(), "session_role": game.session.role,
		"sound_events": game.ui.readable_hud.sounds.duplicate(true) if game.ui.readable_hud != null else [],
		"hud": game.ui.readable_hud.instrument_text() if game.ui.readable_hud != null else {},
		"speed_kmh": absf(car.signed_speed) * 3.6, "signed_speed_mps": car.signed_speed,
		"distance_m": car.distance_driven, "forward_progress_m": maxf(0.0, progress),
		"position": [car.position.x, car.position.y, car.position.z],
		"velocity": [car.linear_velocity.x, car.linear_velocity.y, car.linear_velocity.z],
		"angular_velocity": [car.angular_velocity.x, car.angular_velocity.y, car.angular_velocity.z],
		"steering": car.steering, "throttle": car.throttle, "brake": car.brake_input,
		"handbrake": car.handbrake, "grounded_wheels": car.grounded_wheels,
		"on_road": car.on_road, "road_distance_m": game.world.road_distance(car.position),
		"offroad_sim_seconds": offroad_seconds, "rollover_time": car.rollover_time,
		"impact_events": impact_events, "impact_total": impact_total,
		"part_health": car.damage.health_array(), "punctured_tires": car.punctured_tires,
		"run_state": car.run_state, "crash_reason": car.crash_reason,
		"map_open": game.ui.map_open if options.role == "navigator" else false, "map_reveal": game.ui.map_reveal if options.role == "navigator" else 0.0,
		"camera": "chase" if game.chase_camera and options.role == "navigator" else "seat", "look_back": game.looking_back and options.role == "navigator",
		"police_gap_m": game.police.gap, "heat": game.world.difficulty,
		"snapshots_received": game.session.snapshots_received, "network_stale": game.session.stale,
		"fps": Engine.get_frames_per_second(), "capture_ms": (Time.get_ticks_usec() - started_us) / 1000.0
	}
	frames.store_line(JSON.stringify(data))
	frames.flush()
	var temporary := directory.path_join("latest.tmp")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(temporary, directory.path_join("latest.json"))
	frame_index += 1

func _exit_tree() -> void:
	_set_held([])
	if frames != null: frames.close()
	if events != null: events.close()
