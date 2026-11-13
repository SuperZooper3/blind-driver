extends SceneTree
const Records = preload("res://scripts/run_records.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition
func frames(count: int) -> void:
	for _i in count: await physics_frame
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	var path := "user://survival-check-%d.cfg" % OS.get_process_id()
	game.records.path = path
	root.add_child(game)
	game._start("solo")
	var car = game.car
	var world = game.world
	await frames(90)
	check(not world.thorn_at(Vector3(12, 0, 12)) and world.thorn_at(Vector3(26, 0, 12)), "road shoulders allow evasive driving before dense thorn forest")
	car.distance_driven = 2468.0
	car.recover(world.ground_point(26, 12, 0.17), Vector3.FORWARD)
	await frames(120)
	check(car.punctured_tires != 0 and car.run_state == "game_over" and car.crash_reason.contains("Thorns"), "grounded tires in deep forest puncture and end the run")
	check(car.linear_velocity.length() < 0.7 and game.ui.result_panel.visible, "punctured tires stop the car and show failure")
	check(game.records.best_distance >= 2468.0 and game.ui.result_detail.text.contains("PERSONAL BEST"), "failure records distance and celebrates a personal best")
	var loaded = Records.new()
	loaded.path = path
	loaded.load_record()
	check(loaded.best_distance >= 2468.0, "personal best survives a fresh load from disk")
	game._restart_run()
	await frames(90)
	check(car.punctured_tires == 0 and car.wheel_pivots[0].scale.y == 1.0 and game.records.best_distance >= 2468.0, "new ride repairs tires and retains the personal best")
	# Flip physically onto the roof, using the same body and terrain as normal driving.
	car.reset_transform = Transform3D(Basis(Vector3.FORWARD, PI), world.ground_point(0, 12, 4.0))
	car.reset_pending = true
	car.recovery_grace = 3
	await frames(180)
	var head: Vector3 = car.global_transform * Vector3(-0.43, 1.23, -0.05)
	check(car.run_state == "game_over" and car.crash_reason.contains("rolled") and game.ui.result_panel.visible, "landing upside down automatically shows failure")
	check(head.y > world.height_at(head.x, head.z) + 0.2 and game.driver_camera.global_position.y > world.height_at(head.x, head.z), "roof collision holds occupants and first-person camera above terrain")
	loaded.observe(12.0)
	loaded.save_record()
	loaded.load_record()
	check(loaded.best_distance >= 2468.0, "a shorter run cannot replace the best distance")
	game.started = false
	world.set_process(false)
	var hole: Dictionary = world.roads[2].hazards[0]
	var original_position: Vector3 = hole.position
	hole.position = Vector3(1000, -36, 1000)
	var void_tile := Vector2i(12, 12)
	world._build_tile(void_tile)
	var has_terrain := false
	for child in world.tiles[void_tile].get_children():
		has_terrain = has_terrain or child is MeshInstance3D
	check(not has_terrain, "a tile wholly inside the ravine has no terrain lid or empty collider")
	world.tiles[void_tile].queue_free()
	world.tiles.erase(void_tile)
	hole.position = original_position
	var valid_chain := true
	var safe_clear := true
	var no_branch_growth := true
	for step in 80:
		var frontier: Dictionary = {}
		var leaves := 0
		var children := {}
		for road: Dictionary in world.roads:
			if not road.danger and not road.expanded:
				leaves += 1
				frontier = road
			if road.id != road.parent and not road.danger:
				children[road.parent] = int(children.get(road.parent, 0)) + 1
			if road.danger:
				var before: int = world.next_id
				world.grow_near(road.points[-1])
				no_branch_growth = no_branch_growth and world.next_id == before
		for count in children.values():
			valid_chain = valid_chain and count == 1
		valid_chain = valid_chain and leaves == 1
		for road: Dictionary in world.roads:
			if road.danger: continue
			for point: Vector3 in road.points:
				for other: Dictionary in world.roads:
					for hazard: Dictionary in other.hazards:
						if Hazards.is_void(hazard) and Hazards.contains(hazard, point, 8):
							safe_clear = false
		if not frontier.is_empty(): world.grow_near(frontier.points[-1])
		await process_frame
	check(valid_chain and no_branch_growth, "80 extensions retain exactly one safe frontier; dead ends never generate more paths")
	check(safe_clear, "enlarged ravines never intersect the safe road or its shoulder")
	game.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	quit(1 if failed else 0)
