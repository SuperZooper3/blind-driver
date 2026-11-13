extends SceneTree
const Challenge = preload("res://scripts/road_challenge.gd")
const Wire = preload("res://scripts/wire_protocol.gd")
var failed := false
var game: Node3D
func _initialize() -> void:
	call_deferred("run")
func check(value: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if value else "FAIL", message])
	failed = failed or not value
func frames(count: int) -> void:
	for _i in count: await physics_frame
func find_challenge(kind: String) -> Dictionary:
	for _i in 8:
		for road: Dictionary in game.world.roads:
			for hazard: Dictionary in road.hazards:
				if hazard.kind == kind: return {"road": road, "hazard": hazard}
		for road: Dictionary in game.world.roads.duplicate():
			if not road.danger and not road.expanded:
				game.world.grow_near(road.points[-1])
	return {}
func prepare(hazard: Dictionary, lead: float, speed: float) -> void:
	game.car.run_state = "driving"
	game.car.crash_reason = ""
	game.car.punctured_tires = 0
	game.car.driving_enabled = true
	game.police.phase = "escaped"
	game.world.jumped_gaps.clear()
	var at := Vector3(hazard.lane_x, 0, hazard.position.z + hazard.size.z * 0.5 + lead)
	at.y = game.world.height_at(at.x, at.z) + 0.17
	game.world.update_stream(at, true)
	game.car.recover(at, Vector3.FORWARD)
	await frames(45)
	game.car.driving_enabled = true
	game.car.linear_velocity = Vector3(0, 0, -speed)
func run() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("solo")
	game.set_process(false)
	game.world.set_process(false)
	var jump := find_challenge("jump_gap")
	check(not jump.is_empty(), "safe route generates a dedicated jump with an uncluttered run-up")
	var gap: Dictionary = jump.hazard
	for approach_speed in [18.0, 25.0]:
		await prepare(gap, 28, approach_speed)
		var airborne := false
		var landed := false
		var max_height := 0.0
		for _i in 360:
			await physics_frame
			max_height = maxf(max_height, game.car.global_position.y - game.world.height_at(game.car.global_position.x, game.car.global_position.z))
			if absf(game.car.global_position.z - gap.position.z) < gap.size.z * 0.5:
				airborne = airborne or game.car.grounded_wheels == 0
			if game.car.global_position.z < gap.position.z - gap.size.z * 0.5 - 6 and game.car.grounded_wheels >= 2:
				landed = game.car.run_state == "driving" and game.car.global_basis.y.dot(Vector3.UP) > 0.7
				break
			if game.car.run_state == "game_over": break
		print("Jump at %.0f km/h: airborne=%s landed=%s height=%.2f position=%s reason=%s" % [approach_speed * 3.6, airborne, landed, max_height, game.car.global_position, game.car.crash_reason])
		check(airborne and landed and game.world.jumped_gaps.has(jump.road.id), "ramp jump at %.0f km/h clears the pit and lands upright" % (approach_speed * 3.6))
	await prepare(gap, 28, 10)
	await frames(480)
	check(game.car.run_state == "game_over" and game.car.crash_reason.contains("jump"), "too little speed drops the car into the real pit and ends the run")
	var bridge := find_challenge("timed_bridge")
	check(not bridge.is_empty(), "route also generates a timed sliding bridge")
	var crossing: Dictionary = bridge.hazard
	var node: Node3D = bridge.road.node.get_meta("challenges")[0]
	var offset: float = crossing.position.x * 0.037 + crossing.position.z * 0.019
	var open_clock := 240.0 + fposmod(-offset, Challenge.CYCLE)
	game.world.set_challenge_time(open_clock)
	var open_pose: Vector3 = node.deck.global_position
	game.world.set_challenge_time(open_clock + 8.0)
	check(node.deck.global_position.distance_to(open_pose) > 16 and not Challenge.bridge_state(crossing, game.world.challenge_time).open, "red phase physically retracts the bridge and changes its signal")
	await prepare(crossing, 12, 14)
	game.world.set_challenge_time(open_clock)
	var crossed := false
	for _i in 240:
		await physics_frame
		if game.car.global_position.z < crossing.position.z - crossing.size.z * 0.5 - 5:
			crossed = game.car.run_state == "driving" and game.car.grounded_wheels >= 2
			break
		if game.car.run_state == "game_over": break
	print("Bridge: crossed=%s position=%s reason=%s" % [crossed, game.car.global_position, game.car.crash_reason])
	check(crossed, "a green-window approach crosses the real bridge collider")
	await prepare(crossing, 10, 14)
	game.world.set_challenge_time(open_clock + 8.0)
	await frames(240)
	check(game.car.run_state == "game_over" and game.car.crash_reason.contains("bridge"), "entering while the bridge is absent falls into its pit")
	game.car.freeze = true
	game.car.run_state = "driving"
	game.ui.in_menu = true
	var paused_time: float = game.world.challenge_time
	await frames(60)
	check(is_equal_approx(game.world.challenge_time, paused_time), "driver menus pause the crossing clock")
	var encoded := Wire.graph_to_json(game.world.export_graph())
	var decoded := Wire.graph_from_json(JSON.parse_string(JSON.stringify(encoded)))
	check(decoded.size() == encoded.size() and JSON.stringify(Wire.graph_to_json(decoded)) == JSON.stringify(encoded), "both set pieces and their road alignment survive the online graph format")
	var receiver = load("res://scripts/procedural_world.gd").new()
	receiver.allow_generation = false
	root.add_child(receiver)
	receiver.import_graph(decoded)
	receiver.set_challenge_time(paused_time)
	var peer_deck: Node3D
	for road: Dictionary in receiver.roads:
		for visual: Node3D in road.node.get_meta("challenges", []):
			if visual.hazard.kind == "timed_bridge": peer_deck = visual.deck
	check(peer_deck != null and peer_deck.global_position.is_equal_approx(node.deck.global_position), "receiver reconstructs the exact moving deck from the shared clock")
	receiver.queue_free()
	game.set_physics_process(false)
	game.car.global_position = Vector3(crossing.lane_x, game.world.height_at(crossing.lane_x, crossing.position.z - 40) + 1.1, crossing.position.z - 40)
	game.police.reset()
	game.police.road_id = bridge.road.id
	game.police.station = game.police._project(Vector3(crossing.lane_x, 0, crossing.position.z + crossing.size.z * 0.5 + 24), bridge.road.id).station
	game.police.phase = "chasing"
	game.police.elapsed = 7
	game.police.speed = 22
	game.police._place(1, 1)
	game.world.set_challenge_time(open_clock + 8)
	for _i in 180: game.police.advance(1.0 / 60.0, true)
	print("Patrol at red: position=%s lip=%.2f speed=%.2f phase=%s" % [game.police.global_position, crossing.position.z + crossing.size.z * 0.5, game.police.speed, game.police.phase])
	check(game.police.global_position.z > crossing.position.z + crossing.size.z * 0.5 + 6 and game.police.speed < 1, "police wait on firm ground for a closed crossing")
	game.world.set_challenge_time(open_clock)
	for _i in 360: game.police.advance(1.0 / 60.0, true)
	check(game.police.global_position.z < crossing.position.z - crossing.size.z * 0.5, "police resume and cross when the bridge opens")
	game._restart_run()
	check(game.world.challenge_time == 0 and game.world.jumped_gaps.is_empty(), "new ride resets bridge timing and jump assists")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
