extends SceneTree
## Exercise the real automatic child-process launcher, not two manual test clients.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("local_windows")
	var child_pid: int = game.local_navigator_pid
	var deadline := Time.get_ticks_msec() + 12000
	while game.session.navigator_id == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	var passed: bool = child_pid > 0 and OS.is_process_running(child_pid) and game.session.navigator_id != 0
	print("%s: local co-op launches an independent navigator and connects through WebSocket" % ("PASS" if passed else "FAIL"))
	# Repeated clicks should resume the same pair, not create extra game windows.
	game._start("local_windows")
	passed = passed and game.local_navigator_pid == child_pid
	print("%s: local co-op reuses its connected navigator" % ("PASS" if passed else "FAIL"))
	game._start("solo")
	for _frame in 30:
		await process_frame
	passed = passed and game.local_navigator_pid == -1 and game.session.role == "local"
	print("%s: changing mode cleans up only the automatically launched navigator" % ("PASS" if passed else "FAIL"))
	var blocker := WebSocketMultiplayerPeer.new()
	if blocker.create_server(18765, "127.0.0.1") == OK:
		game._start("local_windows")
		passed = passed and game.local_navigator_pid == -1 and game.ui.in_menu and game.session.role == "local"
		print("%s: a busy host port fails safely without spawning another window" % ("PASS" if passed else "FAIL"))
		blocker.close()
	else:
		passed = false
		print("FAIL: could not set up occupied-port check")
	game.queue_free()
	await process_frame
	quit(0 if passed else 1)
