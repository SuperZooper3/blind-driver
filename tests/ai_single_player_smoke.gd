extends SceneTree
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition
func accept(ai: Node, text: String) -> void:
	ai.active = true
	ai.busy = true
	ai.run_id = ai.game.car.run_id
	ai.sent_epoch = ai.epoch
	ai.sent_at = Time.get_ticks_msec() - 125
	ai._completed(HTTPRequest.RESULT_SUCCESS, 200, [], JSON.stringify({"instruction": text}).to_utf8_buffer())
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	var ai: Node = game.ai_navigator
	# Deterministic response injection: rendering/provider calls are tested separately.
	ai.set_process(false)
	game._start("ai")
	check(game.mode == "ai" and game.session.role == "local" and game.ui.driver_screen.visible and not game.ui.navigator_screen.visible, "AI mode is a local human driver with only the blurred view")
	check(game.navigator_view.render_target_update_mode == SubViewport.UPDATE_ALWAYS and game.navigator_view.size == Vector2i(768, 480), "AI retains a clear offscreen passenger camera")
	game.ui.toggle_map()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_C
	key.pressed = true
	game._unhandled_input(key)
	check(not game.ui.map_open and not game.ui.map_panel.visible and not game.chase_camera, "map and camera controls cannot expose the clear AI view")
	await process_frame
	check(not game.car.driving_enabled and game.world.challenge_time == 0, "ride waits for initial advice before driving or pursuit")
	accept(ai, "Accelerate gently (W).")
	ai.busy = true # prevent a new capture during presentation assertions
	ai._process(0)
	await process_frame
	check(game.car.driving_enabled and ai.ready_to_drive and ai.instruction == "Accelerate gently (W)." and ai.latency_ms >= 125, "accepted instruction enables human driving and measures round trip latency")
	check(ai.panel.visible and ai.panel.thinking and ai.panel.instruction.text == ai.instruction and ai.panel.detail.text.contains("ms"), "top strip keeps current advice and spins while next request is in flight")
	await create_timer(6.1).timeout
	ai._process(0)
	check(ai.panel.detail.text.contains("stale"), "old guidance is identified while waiting")
	game.ui.show_menu(true)
	ai._process(0)
	accept(ai, "This paused reply must be discarded.")
	check(ai.instruction.is_empty() and not ai.ready_to_drive and not ai.panel.visible, "pause cancels guidance and rejects a late response")
	game._resume()
	accept(ai, "Turn left briefly.")
	game._restart_run()
	ai._completed(HTTPRequest.RESULT_SUCCESS, 200, [], '{"instruction":"Old ride"}'.to_utf8_buffer())
	check(ai.instruction.is_empty() and not ai.ready_to_drive, "restart invalidates advice from the old run")
	accept(ai, "Go straight.")
	ai._completed(HTTPRequest.RESULT_SUCCESS, 429, [], '{"error":"Quota reached","retry_after":60}'.to_utf8_buffer())
	check(ai.retry_at - Time.get_ticks_msec() >= 59000 and ai.instruction == "Go straight." and not ai.busy, "quota backoff preserves last advice without a thinking spinner")
	game._start("solo")
	ai._process(0)
	check(not ai.active and not ai.panel.visible and game.ui.navigator_screen.visible and game.chase_camera, "leaving AI mode restores ordinary solo practice")
	game._start("split")
	check(game.ui.driver_screen.visible and game.ui.navigator_screen.visible, "shared screen still shows both seats")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
