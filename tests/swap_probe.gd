extends SceneTree
## Two-process seat swap over a real relay, launched by run_checks.py --relay.
## The first driver ends a run; the navigator presses Swap. Afterwards each game
## must play the other seat, with the new driver's ride reaching the new navigator.

var game
var creator := false
var elapsed := 0.0
var phase := 0
var phase_at := 0.0
var first_run_id := -1
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
	if elapsed > 40.0:
		_finish(false, "timed out in phase %d (mode=%s role=%s)" % [phase, game.mode, game.session.role])
		return
	var session = game.session
	if creator:
		# Phase 0: drive until the navigator is mirroring us, then end the run.
		if phase == 0 and session.navigator_id != 0 and elapsed > 4.0:
			game.police.phase = "escaped"
			first_run_id = game.car.run_id
			game.car.finish_run("Test crash")
			phase = 1
		# Phase 1: wait to be swapped into the navigator seat by our partner.
		elif phase == 1 and game.mode == "join":
			phase = 2
			phase_at = elapsed
		elif phase == 2 and elapsed - phase_at > 4.0:
			var latest: Dictionary = session.snapshots.back() if not session.snapshots.is_empty() else {}
			var ok: bool = session.role == "join" and game.car.remote and game.car.freeze and not latest.is_empty() \
				and int(latest.run_id) != first_run_id and latest.run_state == "driving" and session.relay.seat_role == "navigator" \
				and game.car.global_position.distance_to(latest.transform.origin) < 4.0 and not game.ui.result_panel.visible
			_finish(ok, "former driver now navigates the new driver's ride (run %s, mode=%s)" % [latest.get("run_id", "?"), game.mode])
	else:
		# Phase 0: see the run end, then press Swap on the result screen.
		if phase == 0 and game.car.run_state == "game_over" and game.ui.result_panel.visible:
			if not game.ui.swap_button.visible:
				return
			game.ui.swap_button.pressed.emit()
			phase = 1
			phase_at = elapsed
		elif phase == 1 and game.mode == "host":
			phase = 2
			phase_at = elapsed
			Input.action_press("accelerate")
		elif phase == 2 and elapsed - phase_at > 4.0:
			Input.action_release("accelerate")
			var ok: bool = session.role == "host" and not game.car.remote and not game.car.freeze and game.car.run_state == "driving" \
				and game.car.distance_driven > 5.0 and session.navigator_id != 0 and session.relay.seat_role == "driver" and not game.ui.result_panel.visible
			_finish(ok, "former navigator now drives a fresh ride (%.1f m, mode=%s)" % [game.car.distance_driven, game.mode])

func _finish(ok: bool, message: String) -> void:
	finished = true
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	Input.action_release("accelerate")
	# Let the partner finish its own checks before the room closes.
	await create_timer(1.5 if creator else 0.5).timeout
	game.session.stop()
	game.queue_free()
	await process_frame
	quit(0 if ok else 1)
