extends SceneTree
const World = preload("res://scripts/procedural_world.gd")
const Challenge = preload("res://scripts/road_challenge.gd")
const Wire = preload("res://scripts/wire_protocol.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
var failed := false
func _initialize() -> void:
	call_deferred("run")
func check(value: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if value else "FAIL", message])
	failed = failed or not value
func frontier(world: Node3D) -> Dictionary:
	for road: Dictionary in world.roads:
		if not road.expanded: return road
	return {}
func profile(world: Node3D, kind: String, depth: int) -> Dictionary:
	for road: Dictionary in world.roads:
		if road.profile == kind and road.depth == depth: return road
	return {}
func place_patrol(cop: Node3D, id: int, station: float) -> void:
	cop.phase = "chasing"
	cop.elapsed = 7
	cop.catch_time = 0
	cop.road_id = id
	cop.station = station
	cop.speed = 19
	cop._place(1, 1)
func run() -> void:
	# Sample many generated junctions first, while the physics world is still empty.
	check_middle_holes()
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("solo")
	game.set_process(false)
	game.set_physics_process(false)
	game.world.set_process(false)
	game.car.freeze = true
	game.car.driving_enabled = false
	var world: Node3D = game.world
	var cop: Node3D = game.police
	for _i in 2: world.grow_near(frontier(world).points[-1])
	var scenic := profile(world, "scenic", 3)
	var rough := profile(world, "rough", 3)
	var dead := profile(world, "culdesac", 3)
	check(not scenic.is_empty() and not rough.is_empty() and not dead.is_empty(), "first three-way junction offers two routes and a nonfatal cul-de-sac")
	if scenic.is_empty() or rough.is_empty() or dead.is_empty(): quit(1); return
	cop._sync_roads()
	check(scenic.parent == rough.parent and rough.parent == dead.parent and scenic.points[-1].is_equal_approx(rough.points[-1]), "both through routes share a junction and rejoin at the same endpoint")
	check(cop.cache[scenic.id].length > cop.cache[rough.id].length + 60 and rough.hazards.size() > scenic.hazards.size() * 2, "short route trades a substantial distance saving for heavier hazards")
	var before: int = world.next_id
	world.grow_near(dead.points[-1])
	check(world.next_id == before and world.void_at(dead.points[-1]).is_empty(), "cul-de-sac stays solid and cannot create another frontier")
	var bulb: Vector3 = dead.points[-1]
	var clear := true
	for i in 16:
		var at := bulb + Vector3(cos(i * TAU / 16), 0, sin(i * TAU / 16)) * 12.0
		clear = clear and world.road_distance(at) < 4 and not world.thorn_at(at) and world.void_at(at).is_empty()
	check(clear, "entire turning circle is free of thorns and pits")
	await physics_frame
	await physics_frame
	var solid := true
	for offset: Vector3 in [Vector3.ZERO, Vector3(-10, 0, 0), Vector3(10, 0, 0), Vector3(0, 0, -10)]:
		var at: Vector3 = world.ground_point(bulb.x + offset.x, bulb.z + offset.z)
		var hit := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 8, at + Vector3.DOWN * 3))
		solid = solid and not hit.is_empty() and hit.normal.y > 0.9 and hit.position.y > at.y + 0.08
	check(solid, "cul-de-sac asphalt has upward-facing collision across its turning area")
	world.grow_near(rough.points[-1])
	var continuation := frontier(world)
	check(continuation.depth == 4 and rough.next == continuation.id and scenic.next == continuation.id, "taking the shortcut extends the one shared continuing road")
	before = world.next_id
	world.grow_near(scenic.points[20])
	check(world.next_id == before, "visiting the alternative cannot duplicate the continuation")
	cop._sync_roads()
	game.car.global_position = continuation.points[6] + Vector3.UP
	for approach: Dictionary in [rough, scenic]:
		place_patrol(cop, approach.id, cop.cache[approach.id].length - 5)
		var route: Dictionary = cop._route_to(continuation.id, cop._project(game.car.global_position, continuation.id).station)
		check(route.direction == 1 and route.next == continuation.id and route.distance < 45, "patrol follows the %s route straight through its merge" % approach.profile)
		for _i in 60: cop.advance(1.0 / 60.0, true)
		check(cop.road_id == continuation.id, "patrol physically crosses the %s merge without turning back" % approach.profile)
	place_patrol(cop, continuation.id, 3)
	var back: Dictionary = cop._route_to(rough.id, cop.cache[rough.id].length - 35)
	check(back.direction == -1 and back.next == rough.id and back.next_direction == -1, "backtracking through a merge chooses the connected reverse route")
	place_patrol(cop, dead.id, cop.cache[dead.id].length - 10)
	var out: Dictionary = cop._route_to(rough.id, 40)
	check(out.direction == -1 and out.next == rough.id and out.distance > 150, "police leave a cul-de-sac through its junction instead of cutting through the forest")
	place_patrol(cop, scenic.id, cop.cache[scenic.id].length * 0.5)
	check(cop._route_gap(rough.id, cop.cache[rough.id].length * 0.5) > 200, "parallel roads keep their real route separation for capture checks")
	var bridge: Dictionary = continuation.hazards[0]
	var early_window: float = Challenge.bridge_state(bridge, fposmod(-bridge.position.x * 0.037 - bridge.position.z * 0.019, Challenge.CYCLE)).remaining
	check(early_window > 5.9, "early bridges retain the six-second crossing window")
	var levels := []
	for distance in [0, 749, 750, 1500, 2250, 3000, 9000]: levels.append(World.heat_for_distance(distance))
	check(levels == [0, 0, 1, 2, 3, 4, 4], "heat increases every 750 m and caps at five levels")
	game.car.distance_driven = 3000
	game.ui.in_menu = true
	game._physics_process(0)
	game._process(0)
	check(world.difficulty == 4 and game.ui.heat_label.text == "HEAT 5 / 5", "authoritative distance drives generation difficulty and the dashboard heat display")
	world.grow_near(continuation.points[-1])
	var later_rough := profile(world, "rough", 5)
	var later_scenic := profile(world, "scenic", 5)
	check(later_rough.hazards.size() == 6 and later_scenic.hazards.size() == 3 and rough.hazards.size() == 3, "higher heat adds future obstacles while preserving the quieter route and existing roads")
	var harder_bridge := bridge.duplicate(true)
	harder_bridge.level = 4
	var clock := fposmod(-bridge.position.x * 0.037 - bridge.position.z * 0.019, Challenge.CYCLE)
	check(Challenge.bridge_state(harder_bridge, clock).remaining < 4.1 and Challenge.bridge_state(bridge, clock).remaining > 5.9, "high-heat bridges open for four seconds without changing an existing bridge mid-approach")
	var encoded := Wire.graph_to_json(world.export_graph())
	var decoded := Wire.graph_from_json(JSON.parse_string(JSON.stringify(encoded)))
	check(decoded.size() == encoded.size() and JSON.stringify(Wire.graph_to_json(decoded)) == JSON.stringify(encoded), "route profiles, joins, hazard density, and heat survive the online graph format")
	var receiver := World.new()
	receiver.allow_generation = false
	root.add_child(receiver)
	receiver.import_graph(decoded)
	check(receiver.road_distance(bulb + Vector3(12, 0, 0)) < 4 and profile(receiver, "rough", 5).level == 4, "navigator reconstructs the same cul-de-sac footprint and harder route")
	var invalid: Array = encoded.duplicate(true)
	invalid[0].level = 5
	check(Wire.graph_from_json(invalid).is_empty(), "out-of-range route difficulty is rejected at the client boundary")
	game._restart_run()
	check(world.difficulty == 0 and game.car.distance_driven == 0 and world.roads[0].level == 0, "new ride resets difficulty with the trip distance")
	receiver.queue_free()
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)

func check_middle_holes() -> void:
	var middle := 0
	var straight := 0
	var clear := true
	for seed in 3:
		var w := World.new()
		w.world_seed = 5000 + seed * 977
		root.add_child(w)
		var seen := {}
		for _i in 16:
			var f := frontier(w)
			if f.is_empty(): break
			w.grow_near(f.points[-1])
			for road: Dictionary in w.roads:
				if seen.has(road.id) or road.profile != "rough": continue
				seen[road.id] = true
				var hole: Dictionary = {}
				var scenic: Dictionary = {}
				for other: Dictionary in w.roads:
					if other.parent != road.parent or other.depth != road.depth: continue
					if other.profile == "scenic": scenic = other
					elif other.danger and not other.hazards.is_empty() and other.hazards[0].size == World.MIDDLE_HOLE_SIZE: hole = other
				if hole.is_empty():
					straight += 1
					continue
				middle += 1
				var start: Vector3 = hole.points[0]
				clear = clear and absf(hole.points[-1].x - start.x) < 0.5 and signf(road.points[16].x - start.x) != signf(scenic.points[16].x - start.x)
				clear = clear and road.points[-1].is_equal_approx(scenic.points[-1]) and Hazards.contains(hole.hazards[0], hole.points[-1] + Vector3(0, 0, -20))
				for route: Dictionary in [road, scenic]:
					for point: Vector3 in route.points:
						clear = clear and not Hazards.contains(hole.hazards[0], point, 12.0)
		w.free()
	print("Three-way forks: %d straight middle, %d middle hole" % [straight, middle])
	check(middle > 0 and straight > middle, "later three-way forks sometimes put the pit in the middle, but not usually")
	check(clear, "a middle pit sits straight ahead while both through routes swing around it and rejoin")
