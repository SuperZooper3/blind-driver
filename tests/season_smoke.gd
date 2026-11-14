extends SceneTree
const World = preload("res://scripts/procedural_world.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
const Wire = preload("res://scripts/wire_protocol.gd")
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok

func _run() -> void:
	var world := World.new()
	root.add_child(world)
	world.set_process(false)
	var graph := world.export_graph().duplicate(true)
	var old_key := Vector2i(0, -1)
	var old_trees: Node3D = world.tiles[old_key].get_node("SeasonalTrees")
	var old_mesh: Mesh = old_trees.get_node("EarlyLeaves").multimesh.mesh
	var spring_color: Color = world.season_styles[0].terrain_material.get_shader_parameter("ground_low")
	var sample := World.ground_point(15, -20)
	var surface := world.surface_height(sample)
	var road_distance := world.road_distance(sample)
	var thorn := world.thorn_at(sample)
	# Remember terrain that has already streamed away before heat rises.
	var scouted_key := Vector2i(0, -20)
	world._build_tile(scouted_key)
	world.tiles[scouted_key].queue_free()
	world.tiles.erase(scouted_key)
	await process_frame
	var region_keys := [old_key]
	for stage in 5:
		check(World.heat_for_distance(stage * 750.0) == stage and World.heat_for_distance((stage + 1) * 750.0 - 0.01) == stage, "heat %d follows its distance boundary" % stage)
		var bodies := world.find_children("*", "StaticBody3D", true, false)
		world.set_season(stage)
		check(world.find_children("*", "StaticBody3D", true, false) == bodies, "heat %d changes no existing collision bodies" % stage)
		if stage == 0: continue
		check(old_trees.get_node("EarlyLeaves").visible and old_trees.get_node("EarlyLeaves").multimesh.mesh == old_mesh and world.season_styles[0].terrain_material.get_shader_parameter("ground_low") == spring_color, "heat %d leaves the generated spring forest unchanged" % stage)
		var edge: float = world.season_edges[-1]
		var key := Vector2i(12, floori(edge / World.TILE_SIZE) - 1)
		world._build_tile(key)
		region_keys.append(key)
		var trees: Node3D = world.tiles[key].get_node("SeasonalTrees")
		check(trees.get_meta("season") == stage and trees.get_node("LateLeaves").visible == (stage < 3) and trees.get_node("EarlyLeaves").visible == (stage < 2) and trees.get_node("Branches").visible == (stage >= 2) and trees.get_node("Flames").visible == (stage == 4), "new terrain enters %s beyond the previous forest" % World.Seasons.NAMES[stage])
	check(world.season_at(Vector3(20, 0, -1560)) == 0, "previously generated terrain stays spring after unloading before the heat change")
	var records_unchanged := true
	for i in graph.size():
		records_unchanged = records_unchanged and graph[i].points == world.roads[i].points and graph[i].hazards == world.roads[i].hazards and graph[i].level == world.roads[i].level
	check(records_unchanged, "region changes preserve existing roads, hazards, and difficulty")
	check(world.surface_height(sample) == surface and world.road_distance(sample) == road_distance and world.thorn_at(sample) == thorn, "snow and fire leave surfaces and thorn mechanics unchanged")
	world.tiles[old_key].queue_free()
	world.tiles.erase(old_key)
	world._build_tile(old_key)
	check(world.tiles[old_key].get_meta("season") == 0, "rebuilding or revisiting an old tile preserves spring even at heat five")
	var old_hazard := Node3D.new()
	world.add_child(old_hazard)
	Hazards.render(old_hazard, {"kind": "tree", "position": sample, "yaw": 0.0}, world.tree_mesh, world.style_at(sample))
	check(old_hazard.get_node("tree/SeasonalTrees/EarlyLeaves").visible, "reconstructed roadside trees keep the region's original appearance")
	var encoded := Wire.graph_to_json(world.export_graph())
	var decoded := Wire.graph_from_json(JSON.parse_string(JSON.stringify(encoded)))
	check(decoded.size() == encoded.size() and decoded[0].season_edges == world.season_edges, "permanent region boundaries survive the relay graph format")
	var client := World.new()
	client.allow_generation = false
	root.add_child(client)
	client.set_process(false)
	# Even a pruned graph carries the entire small region map for a late joiner.
	client.import_graph([decoded[-1]])
	var matched := true
	for i in region_keys.size():
		var key: Vector2i = region_keys[i]
		client._build_tile(key)
		matched = matched and client.tiles[key].get_meta("season") == i
	check(matched, "a late navigator reconstructs every old region from a pruned graph")
	var invalid: Array = encoded.duplicate(true)
	invalid[0].season_edges = [0, 1]
	check(Wire.graph_from_json(invalid).is_empty(), "out-of-order region boundaries are rejected")
	invalid[0].season_edges = [0, -80, -160, -240, -320]
	check(Wire.graph_from_json(invalid).is_empty(), "an oversized region history is rejected")
	client.queue_free()
	await process_frame
	world.reset_world()
	check(world.seasons.stage == 0 and world.season_edges.is_empty() and world.season_at(Vector3(0, 0, -10000)) == 0, "new run clears the old region map and restores spring")
	world.set_season(4)
	check(world.season_styles[4].terrain_material.get_shader_parameter("previous_low") == Color(World.Seasons.PALETTES[0].ground_low), "skipped regions blend from the last scenery that actually existed")
	var sign := Node3D.new()
	root.add_child(sign)
	Hazards.render(sign, {"kind": "spike_sign", "position": Vector3.ZERO, "yaw": 0.0}, world.tree_mesh)
	var labels := sign.find_children("*", "Label3D", true, false)
	check(labels.size() == 2 and labels.all(func(label): return label.text == "100 m"), "spike sign has only the distance on both faces")
	world.queue_free()
	sign.queue_free()
	await process_frame
	quit(1 if failed else 0)
