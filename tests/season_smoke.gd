extends SceneTree
const World = preload("res://scripts/procedural_world.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
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
	var bodies := world.find_children("*", "StaticBody3D", true, false)
	var sample := World.ground_point(15, -20)
	var surface := world.surface_height(sample)
	var road_distance := world.road_distance(sample)
	var thorn := world.thorn_at(sample)
	var hazard := Node3D.new()
	world.add_child(hazard)
	Hazards.render(hazard, {"kind": "tree", "position": Vector3.ZERO, "yaw": 0.0}, world.tree_mesh, world.seasons)
	for stage in 5:
		check(World.heat_for_distance(stage * 750.0) == stage and World.heat_for_distance((stage + 1) * 750.0 - 0.01) == stage, "season %d follows its heat boundary" % stage)
		world.set_season(stage)
		var foliage_ok := true
		for trees: Node3D in world.find_children("SeasonalTrees", "Node3D", true, false):
			foliage_ok = foliage_ok and trees.get_node("LateLeaves").visible == (stage < 3)
			foliage_ok = foliage_ok and trees.get_node("EarlyLeaves").visible == (stage < 2)
			foliage_ok = foliage_ok and trees.get_node("Branches").visible == (stage >= 2)
			foliage_ok = foliage_ok and trees.get_node("Flames").visible == (stage == 4)
		check(foliage_ok, "forest and obstacle trees follow %s" % World.Seasons.NAMES[stage])
	check(world.export_graph() == graph, "seasons preserve road graph and hazard records")
	# The extra obstacle contributes one collider; every existing body stays in place.
	var after := world.find_children("*", "StaticBody3D", true, false)
	check(after.size() == bodies.size() + 1 and bodies.all(func(body): return after.has(body)), "seasons preserve existing collision bodies")
	check(world.surface_height(sample) == surface and world.road_distance(sample) == road_distance and world.thorn_at(sample) == thorn, "snow and fire leave surfaces and thorn mechanics unchanged")
	world.set_season(3)
	world._build_tile(Vector2i(12, 12))
	var new_trees: Node3D = world.tiles[Vector2i(12, 12)].get_node("SeasonalTrees")
	check(not new_trees.get_node("LateLeaves").visible and new_trees.get_node("Branches").visible, "newly streamed winter trees arrive bare")
	world.reset_world()
	check(world.seasons.stage == 0, "new run restores spring")
	var sign := Node3D.new()
	root.add_child(sign)
	Hazards.render(sign, {"kind": "spike_sign", "position": Vector3.ZERO, "yaw": 0.0}, world.tree_mesh)
	var labels := sign.find_children("*", "Label3D", true, false)
	check(labels.size() == 2 and labels.all(func(label): return label.text == "100 m"), "spike sign has only the distance on both faces")
	world.queue_free()
	sign.queue_free()
	await process_frame
	quit(1 if failed else 0)
