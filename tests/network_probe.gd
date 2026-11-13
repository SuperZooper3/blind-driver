extends SceneTree
## Integration probe, launched twice by run_checks.py over real localhost WebSockets.

var game: Node3D
var is_host := false
var elapsed := 0.0
var reset_sent := false
var finished := false
var streamed_fork := false
var duration := 10.0
var expect_recovery := false
var repeated_recovery := 15.0
var saw_braking := false
var lan_cut := false
var expect_lan_recovery := false
var lan_recovered := false
var cut_before_driver := false
var waiting_cut := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	is_host = OS.get_cmdline_user_args().has("--probe-host")
	var relay_url := ""
	var room := ""
	var lobby := ""
	cut_before_driver = OS.get_cmdline_user_args().has("--cut-before-driver")
	expect_recovery = OS.get_cmdline_user_args().has("--expect-recovery")
	expect_lan_recovery = OS.get_cmdline_user_args().has("--expect-lan-recovery")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--lobby-name="):
			lobby = argument.trim_prefix("--lobby-name=")
		if argument.begins_with("--probe-duration="):
			duration = float(argument.trim_prefix("--probe-duration="))
		if argument.begins_with("--relay-url="):
			relay_url = argument.trim_prefix("--relay-url=")
		elif argument.begins_with("--relay-room="):
			room = argument.trim_prefix("--relay-room=")
	if not relay_url.is_empty():
		if is_host:
			game.session.room_created.connect(func(code: String): print("ROOM_READY=", code))
			game._host_online(relay_url, lobby)
		else:
			game.session.relay.waiting.connect(func(_message: String): print("WAITING_FOR_DRIVER"))
			game._join_online(relay_url, room, lobby)
		process_frame.connect(_tick)
		return
	if is_host:
		game.mode = "host"
		game.started = true
		game.ui.show_menu(false)
		game.car.driving_enabled = true
		if game.session.host("127.0.0.1") != OK:
			print("FAIL: could not bind test host")
			quit(1)
		else:
			print("HOST_READY")
	else:
		game._join("127.0.0.1")
	process_frame.connect(_tick)

func _tick() -> void:
	if finished:
		return
	elapsed += root.get_process_delta_time()
	if expect_lan_recovery and game.session.recovering:
		lan_recovered = true
	if is_host:
		if expect_lan_recovery and elapsed > 4.0 and not lan_cut and game.session.navigator_id != 0:
			lan_cut = true
			game.session.peer.disconnect_peer(game.session.navigator_id)
		if game.session.navigator_id != 0 and (elapsed < 6.0 or duration > 10.0):
			Input.action_press("accelerate")
		else:
			Input.action_release("accelerate")
		if elapsed > 3.0 and not streamed_fork:
			streamed_fork = true
			var points: PackedVector3Array = game.world.roads[1].points
			game.world.update_stream(points[-1], true)
			# Include a timed bridge in every transport/recovery check, even before
			# this short drive reaches it. The shared clock moves its real deck.
			for _i in 2:
				for road: Dictionary in game.world.roads.duplicate():
					if not road.danger and not road.expanded: game.world.grow_near(road.points[-1])
			game.car.recover(points[-1], points[-1] - points[-2])
			game.car.toggle_lights()
		if elapsed > 6.5 and not reset_sent:
			reset_sent = true
			game._recover()
		if game.session.recovering and not game.car.driving_enabled:
			saw_braking = true
		if duration > 10.0 and elapsed > repeated_recovery:
			repeated_recovery += 8.0
			game._recover()
		if elapsed > duration:
			var passed: bool = not expect_recovery or (saw_braking and game.session.relay.reconnects >= 2 and game.session.relay.is_ready and game.session.role == "host")
			print("%s: host recovery checks, reconnects=%d, braked=%s" % ["PASS" if passed else "FAIL", game.session.relay.reconnects, saw_braking])
			_finish(0 if passed else 1)
	else:
		if cut_before_driver and not waiting_cut and game.session.relay.is_ready and not game.started:
			waiting_cut = true
			game.session.relay.socket.close()
			print("WAITING_RECONNECT")
		if elapsed > duration - 2.0:
			var session = game.session
			var latest: Dictionary = session.snapshots.back() if not session.snapshots.is_empty() else {}
			var follows_host: bool = not latest.is_empty() and game.car.global_position.distance_to(latest.transform.origin) < 4.0
			var patrol_matches: bool = not latest.is_empty() and game.police.global_position.distance_to(Vector3(latest.police.position[0], latest.police.position[1], latest.police.position[2])) < 5.0 and game.police.phase == latest.police.phase
			var clock_matches: bool = not latest.is_empty() and game.world.challenge_time > 0 and absf(game.world.challenge_time - latest.challenge_time) < 0.3
			var bridge_matches := false
			for road: Dictionary in game.world.roads:
				for visual: Node3D in road.node.get_meta("challenges", []):
					if visual.hazard.kind == "timed_bridge":
						var state = preload("res://scripts/road_challenge.gd").bridge_state(visual.hazard, game.world.challenge_time)
						bridge_matches = visual.deck.position.is_equal_approx(visual.deck_origin + Vector3.RIGHT * state.shift * 17.0)
			var passed: bool = clock_matches and bridge_matches and patrol_matches and session.snapshots_received > 90 and session.graph_received and session.received_reset >= 2 and game.car.distance_driven > 20.0 and game.car.remote and game.car.freeze and game.world.roads.size() >= 5 and follows_host and game.car.headlights[0].visible
			if cut_before_driver:
				passed = passed and waiting_cut and game.started and not game.ui.in_menu and session.relay.reconnects >= 1
			if expect_lan_recovery:
				passed = passed and lan_recovered and not session.recovering and not session.stale
			if expect_recovery:
				passed = passed and session.relay.reconnects >= 1 and session.relay.is_ready and not session.stale and session.last_sequence > 1000
			print("%s: navigator received %d snapshots, %d roads, reset=%d, distance=%.1f, remote=%s, bridge=%s, clock=%s" % ["PASS" if passed else "FAIL", session.snapshots_received, game.world.roads.size(), session.received_reset, game.car.distance_driven, game.car.remote, bridge_matches, clock_matches])
			_finish(0 if passed else 1)

func _finish(code: int) -> void:
	finished = true
	Input.action_release("accelerate")
	game.session.stop()
	game.queue_free()
	await process_frame
	quit(code)
