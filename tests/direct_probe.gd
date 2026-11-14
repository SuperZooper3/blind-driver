extends SceneTree
## Two-process direct-link check, launched by run_checks.py --relay (driver, then navigator).
## They meet through the relay, the driver turns on the direct connection, and the car's
## data must then arrive over the direct link. BLIND_DRIVER_DIRECT_NO_LISTEN=1 on either
## side simulates a firewall that refuses incoming connections (one-way networks).

var game
var creator := false
var elapsed := 0.0
var linked_at := -1.0
var counted_from := 0
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
	game.ui.direct_toggle.set_pressed_no_signal(false)
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
	var session = game.session
	if elapsed > 30.0:
		_finish(false, "no direct link after 30 s (%s)" % game.ui.direct_label.text)
		return
	if creator and session.navigator_id != 0:
		game.police.phase = "escaped"
		Input.action_press("accelerate", 0.6)
		if not session.direct_wanted:
			# The driver flips the switch; the navigator's game follows on its own.
			game.ui.direct_toggle.set_pressed_no_signal(true)
			game.ui.direct_toggled.emit(true)
	if session.direct.is_linked() and linked_at < 0.0:
		linked_at = elapsed
		counted_from = session.direct.received_count
	if linked_at >= 0.0 and elapsed - linked_at > 4.0:
		var direct_messages: int = session.direct.received_count - counted_from
		if creator:
			_finish(session.direct.is_linked() and session.direct_wanted, "driver linked directly to %s (outgoing=%s)" % [session.direct.partner_address(), session.direct.active.outgoing])
		else:
			var latest: Dictionary = session.latest_pose
			var follows: bool = not latest.is_empty() and game.car.global_position.distance_to(latest.transform.origin) < 4.0
			_finish(direct_messages > 60 and follows and game.ui.direct_toggle.button_pressed and session.direct.is_linked(), "navigator got %d car updates over the direct link from %s (outgoing=%s)" % [direct_messages, session.direct.partner_address(), session.direct.active.outgoing])

func _finish(ok: bool, message: String) -> void:
	finished = true
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	Input.action_release("accelerate")
	await create_timer(1.5 if creator else 0.5).timeout
	game.session.stop()
	game.queue_free()
	await process_frame
	quit(0 if ok else 1)
