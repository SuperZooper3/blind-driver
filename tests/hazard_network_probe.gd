extends SceneTree
## Real two-process proof of authoritative obstacles, fall, death, reconnect, and restart.
const Wire = preload("res://scripts/wire_protocol.gd")
var game: Node3D
var host := false
var elapsed := 0.0
var phase := 0
var phase_at := 0.0
var saw_fall := false
var saw_over := false
var saw_restart := false
var saw_puncture := false
var saw_rollover := false
var saw_caught := false
var saw_graph := false
var saw_reconnect := false
var finished := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	host = OS.get_cmdline_user_args().has("--probe-host")
	var url := ""
	var room := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--relay-url="): url = arg.trim_prefix("--relay-url=")
		if arg.begins_with("--relay-room="): room = arg.trim_prefix("--relay-room=")
	if host:
		# This deliberate non-default position proves clients consume host records.
		game.world.roads[1].hazards[0].position.x += 0.375
		game.world.graph_revision += 1
		if url.is_empty():
			game._host("127.0.0.1")
			print("HOST_READY")
		else:
			game.session.room_created.connect(func(code: String): print("ROOM_READY=", code))
			game._host_online(url)
	else:
		if url.is_empty(): game._join("127.0.0.1")
		else: game._join_online(url, room)
	process_frame.connect(_tick)

func _tick() -> void:
	if finished: return
	elapsed += root.get_process_delta_time()
	if host:
		if phase == 0 and game.session.navigator_id != 0:
			phase = 1
			phase_at = elapsed
		if phase == 1 and elapsed - phase_at > 2.0:
			var hole: Dictionary = game.world.roads[2].hazards[0]
			game.world.update_stream(hole.position, true)
			game.car.distance_driven = 1234.0
			game.car.recover(hole.position + Vector3.UP * (hole.size.y + 1.0), Vector3.FORWARD)
			phase = 2
		if phase == 2 and game.car.run_state == "game_over":
			phase = 3
			phase_at = elapsed
		if phase == 3 and elapsed - phase_at > 6.0:
			game._restart_run()
			phase = 4
			phase_at = elapsed
		if phase == 4 and elapsed - phase_at > 1.5:
			game.car.distance_driven = 2345.0
			game.car.recover(game.world.ground_point(26, 12, 0.17), Vector3.FORWARD)
			phase = 5
		if phase == 5 and game.car.run_state == "game_over":
			phase = 6
			phase_at = elapsed
		if phase == 6 and elapsed - phase_at > 2.0:
			game._restart_run()
			phase = 7
			phase_at = elapsed
		if phase == 7 and elapsed - phase_at > 1.5:
			game.car.reset_transform = Transform3D(Basis(Vector3.FORWARD, PI), game.world.ground_point(0, 12, 4.0))
			game.car.reset_pending = true
			game.car.recovery_grace = 3
			phase = 8
		if phase == 8 and game.car.run_state == "game_over":
			phase = 9
			phase_at = elapsed
		if phase == 9 and elapsed - phase_at > 2.0:
			game._restart_run()
			phase = 10
			phase_at = elapsed
		if phase == 10 and elapsed - phase_at > 1.0:
			game.car.distance_driven = 3456.0
			game.police.phase = "chasing"
			game.police.elapsed = 7.0
			game.police.station = game.police._project(game.car.global_position, game.police.road_id).station - 13.0
			game.police.speed = 15.0
			game.police._place(1, 1.0)
			phase = 11
		if phase == 11 and game.car.run_state == "game_over":
			phase = 12
			phase_at = elapsed
		if phase == 12 and elapsed - phase_at > 2.0:
			game._restart_run()
			phase = 13
			phase_at = elapsed
		if phase == 13 and elapsed - phase_at > 2.0:
			_finish(true, "driver completes cliff, puncture, rollover, police capture, and restarts")
	else:
		if game.session.graph_received and phase == 0:
			var record: Dictionary = game.world.roads[1].hazards[0]
			var expected_world = load("res://scripts/procedural_world.gd").new()
			root.add_child(expected_world)
			var expected: Vector3 = expected_world.roads[1].hazards[0].position + Vector3(0.375, 0, 0)
			saw_graph = record.position.is_equal_approx(expected)
			expected_world.queue_free()
			phase = 1
		saw_fall = saw_fall or game.car.run_state == "falling"
		if game.car.run_state == "game_over" and game.car.run_id == 0:
			saw_over = absf(game.car.distance_driven - 1234.0) < 1.0 and game.ui.result_panel.visible and not game.ui.restart_button.visible
			if phase == 1:
				# Drop this socket during Game Over. Normal recovery must restore that same outcome.
				phase = 2
				if game.session.online:
					game.session.relay.socket.close()
				else:
					game.session.peer.close()
					game.session._schedule_lan_retry()
			elif phase == 2 and not game.session.recovering and game.session.snapshots_received > 120:
				saw_reconnect = true
		if game.car.run_id == 1 and game.car.run_state == "game_over":
			saw_puncture = game.car.punctured_tires != 0 and game.car.crash_reason.contains("Thorns") and absf(game.car.distance_driven - 2345.0) < 1.0 and game.ui.result_panel.visible
			for i in game.car.wheel_pivots.size():
				if game.car.punctured_tires & (1 << i):
					saw_puncture = saw_puncture and is_equal_approx(game.car.wheel_pivots[i].scale.y, 0.55)
		if game.car.run_id == 2 and game.car.run_state == "game_over":
			saw_rollover = game.car.crash_reason.contains("rolled") and game.car.punctured_tires == 0 and game.ui.result_panel.visible
		if game.car.run_id == 3 and game.car.run_state == "game_over":
			saw_caught = game.car.crash_reason.contains("police") and game.police.phase == "caught" and game.ui.result_panel.visible and absf(game.car.distance_driven - 3456.0) < 1.0
		if game.car.run_id == 4 and game.car.run_state == "driving":
			saw_restart = game.car.distance_driven < 2.0 and game.car.punctured_tires == 0 and game.world.roads[0].id > 0 and game.car.global_position.distance_to(Vector3(0, 1.6, 12)) < 2.0 and game.records.best_distance >= 3456.0 and game.police.phase == "waiting" and game.police.catch_time == 0
			_finish(saw_graph and saw_fall and saw_over and saw_restart and saw_reconnect and saw_puncture and saw_rollover and saw_caught, "navigator matches hazards=%s fall=%s result=%s reconnect=%s restart=%s puncture=%s rollover=%s caught=%s" % [saw_graph, saw_fall, saw_over, saw_reconnect, saw_restart, saw_puncture, saw_rollover, saw_caught])
	if elapsed > 38.0:
		_finish(false, "hazard network probe timed out at phase %d" % phase)

func _finish(passed: bool, message: String) -> void:
	finished = true
	print("%s: %s" % ["PASS" if passed else "FAIL", message])
	game.session.stop()
	game.queue_free()
	await process_frame
	quit(0 if passed else 1)
