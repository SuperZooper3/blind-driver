extends SceneTree
## Online smoothness probe, launched twice by run_checks.py --relay (driver, then navigator).
## Both log the car's position every frame against the shared wall clock: the driver its
## real car, the navigator the car it shows. run_checks.py compares them at equal times.

var game
var creator := false
var out := ""
var duration := 20.0
var elapsed := 0.0
var driving_since := -1.0
var lines := PackedStringArray()
var finished := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var url := ""
	var room := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--relay-url="):
			url = argument.trim_prefix("--relay-url=")
		elif argument.begins_with("--relay-room="):
			room = argument.trim_prefix("--relay-room=")
		elif argument.begins_with("--out="):
			out = argument.trim_prefix("--out=")
		elif argument.begins_with("--duration="):
			duration = float(argument.trim_prefix("--duration="))
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	creator = room.is_empty()
	if creator:
		game.session.room_created.connect(func(code: String): print("ROOM_READY=", code))
		game._host_online(url)
	else:
		game._join_online(url, room)
	process_frame.connect(_tick)

func _tick() -> void:
	if finished:
		return
	elapsed += root.get_process_delta_time()
	var now := Time.get_unix_time_from_system()
	var session = game.session
	if creator and session.navigator_id != 0:
		if driving_since < 0.0:
			driving_since = elapsed
			game.police.phase = "escaped"
		var t := elapsed - driving_since
		# Follow the road with a gentle weave, so prediction has turns and speed changes to follow.
		var car = game.car
		var forward: Vector3 = -car.global_basis.z
		var target: Vector3 = game.world.nearest_road(car.global_position + forward * 14.0).point
		var to_target: Vector3 = target - car.global_position
		var yaw := Vector2(forward.x, forward.z).angle_to(Vector2(to_target.x, to_target.z))
		var steer := clampf(-yaw * 2.5 + sin(t * 1.7) * 0.35, -1.0, 1.0)
		# Hold about 65 km/h so the whole run is spent driving, not crashing.
		if car.signed_speed < 18.0:
			Input.action_press("accelerate")
		else:
			Input.action_release("accelerate")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		if steer > 0.03:
			Input.action_press("steer_left", steer)
		elif steer < -0.03:
			Input.action_press("steer_right", -steer)
	var p: Vector3 = game.car.global_position
	if creator == (session.role == "host") and (not creator or session.navigator_id != 0):
		lines.append("%s %.4f %.3f %.3f %.3f" % ["H" if creator else "N", now, p.x, p.y, p.z])
	if elapsed > duration:
		finished = true
		Input.action_release("accelerate")
		var file := FileAccess.open(out, FileAccess.WRITE)
		file.store_string("\n".join(lines))
		file.close()
		print("LAG_PROBE_DONE %d samples" % lines.size())
		await create_timer(0.5).timeout
		session.stop()
		game.queue_free()
		await process_frame
		quit()
