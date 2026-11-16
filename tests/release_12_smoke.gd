extends SceneTree
const World = preload("res://scripts/procedural_world.gd")
const Wire = preload("res://scripts/wire_protocol.gd")
var failed := false

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.intro_enabled = false
	game._start("split")
	game.set_process(false)
	game.set_physics_process(false)
	game.car.freeze = true
	game.car.set_physics_process(false)
	var car = game.car
	var ui = game.ui
	for i in car.damage.PART_COUNT: car.damage.set_part(i, 0.99)
	ui.update_damage(car, true)
	check(ui.damage_overlays.size() == 2 and ui.damage_overlays[0].visible and ui.damage_overlays[1].visible and ui.damage_overlays[0].entries.size() == 8 and ui.damage_overlays[0].entries == ui.damage_overlays[1].entries, "both seat panels list all eight parts, including minor damage")
	car.damage.wear_tire(0, 1.0)
	car.damage.set_part(car.damage.ENGINE, 0.0)
	ui.update_damage(car, true)
	check(ui.damage_overlays[0].entries[0].status == "Flat" and ui.damage_overlays[1].entries[4].status == "Wrecked", "panels distinguish flat tires and wrecked components")
	ui.map_open = true
	ui.update_damage(car, true)
	check(ui.damage_overlays[1].visible and ui.damage_overlays[1].z_index > ui.map_clip.z_index, "navigator damage remains readable above the open map")
	var receiver = preload("res://scripts/car.gd").new()
	root.add_child(receiver)
	receiver.freeze = true
	receiver.remote = true
	receiver.punctured_tires = car.punctured_tires
	receiver.damage.set_health_array(car.damage.health_array())
	check(receiver.damage.status_entries() == car.damage.status_entries(), "snapshot damage produces the same complete text on the remote seat")
	car.repairing = true
	ui.update_damage(car, true)
	check(not ui.damage_overlays[0].visible and not ui.damage_overlays[1].visible, "repair progress takes over cleanly during repairs")
	car.repairing = false
	car.damage.reset()
	ui.update_damage(car, true)
	check(not ui.damage_overlays[0].visible and not ui.damage_overlays[1].visible, "repaired car clears both damage panels")
	var world = game.world
	world.set_process(false)
	world.difficulty = 4
	world.season_edges.assign([-100.0, -300.0, -600.0, -1000.0])
	world._configure_season_edges()
	var previous_count := 0
	var previous_radius := 19.0
	var original: Array = world.roads[1].hazards.duplicate(true)
	for depth in [0.0, 3000.0, 9000.0, 30000.0]:
		var at := Vector3(0, 0, -1000.0 - depth)
		var id: int = world._add_road(at, 0.2, 1, 0, 180.0, false, "rough")
		var road: Dictionary = world.roads[-1]
		var count := 0
		var positions := {}
		for hazard: Dictionary in road.hazards:
			if hazard.kind == "spike_sign": continue
			count += 1
			positions[hazard.position] = true
		check(count > previous_count and positions.size() == count and road.id == id, "Hell depth %.0f m adds distinct obstacles (%d)" % [depth, count])
		var radius: float = world.thorn_distance_at(at)
		check(radius < previous_radius and radius > world.ROAD_WIDTH * 0.5, "Hell thorns move inward while retaining a central corridor (%.2f m)" % radius)
		previous_count = count
		previous_radius = radius
	check(world.roads[1].hazards == original, "deeper Hell leaves existing road obstacles unchanged")
	check(world.obstacle_count("scenic", Vector3(0, 0, -10000)) < world.obstacle_count("rough", Vector3(0, 0, -10000)), "quiet routes retain fewer obstacles deep into Hell")
	var encoded := Wire.graph_to_json(world.export_graph())
	var decoded := Wire.graph_from_json(JSON.parse_string(JSON.stringify(encoded)))
	check(decoded.size() == encoded.size() and decoded[-1].hazards.size() > 60, "dense Hell roads round-trip through protocol 13")
	var remote := World.new()
	remote.allow_generation = false
	root.add_child(remote)
	remote.import_graph(decoded)
	var matching := true
	for z in range(-31200, -31000, 8):
		for x in range(-24, 24, 2):
			var at := Vector3(x, 0, z)
			matching = matching and world.thorn_at(at) == remote.thorn_at(at)
	check(matching and remote.thorn_distance_at(Vector3(0, 0, -31000)) == world.thorn_distance_at(Vector3(0, 0, -31000)), "navigator and late joiners reconstruct identical encroaching thorns")
	var invalid: Array = encoded.duplicate(true)
	while invalid[-1].hazards.size() <= 64: invalid[-1].hazards.append(invalid[-1].hazards[0])
	check(Wire.graph_from_json(invalid).is_empty(), "oversized hazard arrays remain rejected")
	receiver.queue_free()
	remote.queue_free()
	await process_frame
	world.reset_world()
	check(world.hell_depth(Vector3(0, 0, -31000)) == 0.0 and world.thorn_distance_at(Vector3(0, 0, -31000)) == world.THORN_DISTANCE, "new ride resets Hell progression and thorn clearance")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
