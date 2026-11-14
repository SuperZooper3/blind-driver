extends SceneTree
## Probe visible/collidable pavement at bends, including the seams between records.
const World = preload("res://scripts/procedural_world.gd")
var failed := false

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if value else "FAIL", message])
	failed = failed or not value

func record(id: int, points: PackedVector3Array) -> Dictionary:
	return {"id": id, "parent": id - 1, "points": points, "hazards": [], "profile": "main", "depth": 1, "heading": 0.0, "expanded": true, "danger": false, "level": 0, "next": -1, "merge_with": -1}

func run() -> void:
	var world := World.new()
	world.allow_generation = false
	root.add_child(world)
	world.set_process(false)
	var probes: Array[Dictionary] = []
	for split in [false, true]:
		for turn in [-0.55, 0.55]:
			var center := Vector3(-45 if turn < 0 else 45, 0, -60 if split else 40)
			var incoming := Vector3.FORWARD
			var outgoing := incoming.rotated(Vector3.UP, turn)
			var points := PackedVector3Array([center - incoming * 20, center, center + outgoing * 20])
			for i in points.size(): points[i] = world.ground_point(points[i].x, points[i].z, 0.17)
			var road := record(world.roads.size(), points.slice(0, 2) if split else points)
			world._render_road(road)
			world.roads.append(road)
			if split:
				road = record(world.roads.size(), points.slice(1))
				world._render_road(road)
				world.roads.append(road)
			var outward := (incoming + outgoing).normalized().cross(Vector3.UP) * signf(turn)
			for fraction in [0.2, 0.65, 0.99]:
				probes.append({"point": center + outward * 4.0 * fraction, "shoulder": false, "split": split})
			probes.append({"point": center + outward * 5.08, "shoulder": true, "split": split})
	# A long straight section crosses a crest between its endpoints. Its pavement
	# must follow the hill, rather than becoming a chord buried in the terrain.
	var hill := PackedVector3Array([world.ground_point(0, 55, 0.17), world.ground_point(0, 10, 0.17)])
	var hill_road := record(world.roads.size(), hill)
	world._render_road(hill_road)
	world.roads.append(hill_road)
	for z in range(11, 55, 2):
		for x in [-3.9, 0.0, 3.9, 5.0]:
			probes.append({"point": Vector3(x, 0, z), "shoulder": x == 5.0, "split": false})
	await physics_frame
	await physics_frame
	var continuous := probe_surfaces(world, probes)
	check(continuous[0], "bends and hill crests have continuous pavement and shoulders across their full width")
	check(continuous[1], "separately generated road sections meet without exposed terrain at their corners")
	var graph := world.export_graph()
	world.free()
	var receiver := World.new()
	receiver.allow_generation = false
	root.add_child(receiver)
	receiver.set_process(false)
	# The whole graph is available, even when a child precedes its parent on import.
	graph.reverse()
	receiver.import_graph(graph)
	await physics_frame
	await physics_frame
	continuous = probe_surfaces(receiver, probes)
	check(continuous[0] and continuous[1], "imported roads reproduce the same continuous surface regardless of record order")
	receiver.free()
	quit(1 if failed else 0)

func probe_surfaces(world: Node3D, probes: Array[Dictionary]) -> Array:
	var continuous := [true, true]
	for probe: Dictionary in probes:
		var at: Vector3 = world.ground_point(probe.point.x, probe.point.z)
		var hit := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 5, at - Vector3.UP))
		var surface: Node = hit.collider.get_parent() if not hit.is_empty() else null
		var material: Material = world.shoulder_material if probe.shoulder else world.road_material
		var paved: bool = surface is MeshInstance3D and surface.material_override == material and hit.normal.y > 0.9
		continuous[int(probe.split)] = continuous[int(probe.split)] and paved
	return continuous
