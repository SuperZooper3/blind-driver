extends SceneTree
## Survival physics, graph round trips, map behavior, and bounded generation.
const Wire = preload("res://scripts/wire_protocol.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition

func frames(count: int) -> void:
	for _i in count:
		await physics_frame

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("solo")
	await frames(60)
	var world = game.world
	var car = game.car
	var ui = game.ui
	check(ui.map_panel.position.y == ui.root.size.y - ui.FOOTER_HEIGHT - 64 and ui.map_panel.size.y == ui.root.size.y, "folded map exposes only the top of the full-size sheet")
	ui.toggle_map()
	await frames(12)
	check(ui.map_panel.position.y > 0 and ui.map_panel.position.y < ui.root.size.y - ui.FOOTER_HEIGHT - 64, "map slides through intermediate positions")
	await frames(30)
	check(ui.map_panel.position == Vector2.ZERO and ui.map_panel.size == ui.root.size, "open navigator map covers the full screen")
	ui.set_mode("split")
	check(ui.map_panel.position.x == ui.root.size.x / 2 and ui.map_panel.size.x == ui.root.size.x / 2, "shared-screen sheet covers only the navigator's entire half")
	ui.set_mode("host")
	check(not ui.map_panel.visible, "driver cannot see the map")
	ui.set_mode("solo")
	ui.close_map()
	var cliff: Dictionary = {}
	var cliff_road: Dictionary = {}
	for road: Dictionary in world.roads:
		if road.danger:
			cliff_road = road
			cliff = road.hazards[0]
	check(not cliff.is_empty() and cliff_road.expanded, "wrong branch ends at a cliff and never extends")
	world.update_stream(cliff.position, true)
	await frames(3)
	var ray := PhysicsRayQueryParameters3D.create(cliff.position + Vector3.UP * 45, cliff.position - Vector3.UP * 2)
	var hit: Dictionary = world.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and absf(hit.position.y - cliff.position.y) < 0.1, "pit has no terrain lid and has a physical floor 36 m below the surface")
	car.distance_driven = 1234.0
	var edge: Vector3 = cliff_road.points[-1]
	car.recover(edge + Vector3(0, 0, 8), Vector3.FORWARD)
	await frames(45)
	Input.action_press("accelerate")
	var saw_fall := false
	var lowest: float = car.global_position.y
	for _i in 420:
		await physics_frame
		lowest = minf(lowest, car.global_position.y)
		if car.run_state == "falling":
			saw_fall = true
			game._recover()
		if car.run_state == "game_over":
			break
	Input.action_release("accelerate")
	# Game Over is announced within 2.5 m of the floor, before impact. Let the
	# still-physical wreck land instead of depending on the final fall frame's y.
	await frames(60)
	lowest = minf(lowest, car.global_position.y)
	check(saw_fall and lowest < cliff.position.y + 2, "car physically drives off the edge and falls to the pit bottom")
	check(car.run_state == "game_over" and not car.reset_pending, "fatal fall cannot be recovered and ends the run")
	await frames(2)
	check(ui.result_panel.visible and ui.result_detail.text.contains("1.2"), "Game Over reports the distance driven")
	var score: float = car.distance_driven
	await frames(60)
	check(is_equal_approx(car.distance_driven, score), "crash distance stops accumulating")
	game._restart_run()
	check(car.distance_driven == 0.0, "restart clears the previous score immediately")
	await frames(90)
	check(car.run_id == 1 and car.run_state == "driving" and car.distance_driven < 1.0 and car.grounded_wheels == 4, "restart resets the run and returns to a stable starting road")
	var encoded := Wire.graph_to_json(world.export_graph())
	var decoded := Wire.graph_from_json(JSON.parse_string(JSON.stringify(encoded)))
	check(decoded.size() == world.roads.size() and JSON.stringify(Wire.graph_to_json(decoded)) == JSON.stringify(encoded), "JSON preserves every hazard, cliff, and road exactly")
	var client = load("res://scripts/procedural_world.gd").new()
	client.allow_generation = false
	root.add_child(client)
	client.import_graph(decoded)
	check(JSON.stringify(Wire.graph_to_json(client.export_graph())) == JSON.stringify(encoded), "navigator constructs the driver's exact hazard graph")
	client.queue_free()
	var kinds: Dictionary = {}
	var safe_clear := true
	world.set_process(false)
	game.started = false
	for step in 50:
		var newest: Dictionary = {}
		for road: Dictionary in world.roads:
			for hazard: Dictionary in road.hazards:
				kinds[hazard.kind] = true
			if not road.danger and not road.expanded:
				newest = road
		for road: Dictionary in world.roads:
			if road.danger:
				continue
			for point: Vector3 in road.points:
				for other: Dictionary in world.roads:
					for hazard: Dictionary in other.hazards:
						if Hazards.is_void(hazard) and (not hazard.kind in ["jump_gap", "timed_bridge"] or other.id != road.id) and Hazards.contains(hazard, point, 6.0):
							safe_clear = false
		if not newest.is_empty():
			world.grow_near(newest.points[-1])
		await process_frame
	check(safe_clear, "voids never cut another safe route; jump and bridge gaps stay on their own road")
	check(kinds.size() == Hazards.KINDS.size(), "long run includes every obstacle, jump gap, timed bridge, cliff, and lake")
	check(world.roads.size() <= world.MAX_ROADS, "hazards unload with their bounded road graph")
	var lake: Dictionary = {}
	for road: Dictionary in world.roads:
		for hazard: Dictionary in road.hazards:
			if hazard.kind == "lake": lake = hazard
	check(not lake.is_empty(), "streamed route retains a nearby lake")
	if not lake.is_empty():
		game.started = true
		world.update_stream(lake.position, true)
		car.recover(lake.position + Vector3.UP * (lake.size.y + 1.0), Vector3.FORWARD)
		await frames(180)
		check(car.run_state == "game_over" and car.crash_reason.contains("lake"), "falling into water ends the run")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
