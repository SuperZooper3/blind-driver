extends Node3D
## A bounded road graph over deterministic terrain. Both forks are real roads.
## Geometry/decoration are disposable; road records are also used by the map/network.

const Geo = preload("res://scripts/geometry.gd")
const TILE_SIZE := 80.0
const TILE_RADIUS := 3
const ROAD_WIDTH := 8.0
const KEEP_DISTANCE := 720.0
const MAX_ROADS := 100
var world_seed := 72419
var roads: Array[Dictionary] = []
var tiles: Dictionary = {}
var pending_tiles: Array[Vector2i] = []
var next_id := 0
var graph_revision := 0
var allow_generation := true
var focus := Vector3.ZERO
var road_material: StandardMaterial3D
var shoulder_material: StandardMaterial3D
var stripe_material: StandardMaterial3D
var terrain_material: StandardMaterial3D
var trunk_material: StandardMaterial3D
var leaf_material: StandardMaterial3D
var rock_material: StandardMaterial3D
var timer := 0.0
var last_tile := Vector2i(99999, 99999)
var tree_mesh: ArrayMesh
var trunk_mesh: CylinderMesh
var rock_mesh: SphereMesh

func _ready() -> void:
	road_material = Geo.material(Color("726b57"))
	shoulder_material = Geo.material(Color("9b9271"))
	stripe_material = Geo.material(Color("dbcb91"))
	terrain_material = Geo.material(Color.WHITE)
	terrain_material.vertex_color_use_as_albedo = true
	trunk_material = Geo.material(Color("4a4234"))
	leaf_material = Geo.material(Color.WHITE)
	leaf_material.vertex_color_use_as_albedo = true
	rock_material = Geo.material(Color("838a7e"))
	_build_tree_mesh()
	if allow_generation:
		_add_road(Vector3(0, 0, 30), 0.0, 0, 0, 180.0)
		grow_near(Vector3.ZERO)
	update_stream(Vector3.ZERO, true)

static func height_at(x: float, z: float) -> float:
	return sin(x * 0.018) * 1.6 + sin(z * 0.014) * 2.2 + sin((x + z) * 0.037) * 0.45

static func ground_point(x: float, z: float, lift: float = 0.0) -> Vector3:
	return Vector3(x, height_at(x, z) + lift, z)

func _process(delta: float) -> void:
	timer += delta
	if timer > 0.5:
		timer = 0.0
		update_stream(focus)
	# Amortize terrain construction so crossing a tile boundary doesn't stall driving.
	if not pending_tiles.is_empty():
		var key: Vector2i = pending_tiles.pop_front()
		if not tiles.has(key):
			_build_tile(key)

func update_stream(at: Vector3, immediate: bool = false) -> void:
	focus = at
	if allow_generation:
		grow_near(at)
	var center := Vector2i(floori(at.x / TILE_SIZE), floori(at.z / TILE_SIZE))
	if center != last_tile:
		last_tile = center
		pending_tiles.clear()
		for radius in range(TILE_RADIUS + 1):
			for x in range(-radius, radius + 1):
				for z in range(-radius, radius + 1):
					if maxi(absi(x), absi(z)) != radius:
						continue
					var key := center + Vector2i(x, z)
					if not tiles.has(key):
						pending_tiles.append(key)
		for key: Vector2i in tiles.keys():
			if maxi(absi(key.x - center.x), absi(key.y - center.y)) > TILE_RADIUS + 1:
				tiles[key].queue_free()
				tiles.erase(key)
	if immediate:
		while not pending_tiles.is_empty():
			_build_tile(pending_tiles.pop_front())

func grow_near(at: Vector3) -> void:
	var expanded := 0
	for road: Dictionary in roads.duplicate():
		if road.expanded or roads.size() >= MAX_ROADS:
			continue
		var end: Vector3 = road.points[-1]
		if end.distance_to(at) > 235.0:
			continue
		road.expanded = true
		var depth: int = road.depth + 1
		if road.depth % 2 == 0:
			_add_road(end, clampf(road.heading + 0.48, -1.05, 1.05), depth, road.id)
			_add_road(end, clampf(road.heading - 0.48, -1.05, 1.05), depth, road.id)
		else:
			_add_road(end, road.heading, depth, road.id)
		expanded += 1
		if expanded >= 3:
			break
	for road: Dictionary in roads.duplicate():
		var points: PackedVector3Array = road.points
		if at.distance_to(points[0]) > KEEP_DISTANCE and at.distance_to(points[-1]) > KEEP_DISTANCE:
			road.node.queue_free()
			roads.erase(road)
			graph_revision += 1

func _add_road(start: Vector3, heading: float, depth: int, parent_id: int, length: float = 155.0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + next_id * 7919
	var bend := rng.randf_range(-0.23, 0.23) if depth > 0 else 0.0
	var points := PackedVector3Array()
	var pos := start
	for i in range(33):
		points.append(ground_point(pos.x, pos.z, 0.17))
		var direction := Vector3.FORWARD.rotated(Vector3.UP, heading + bend * sin(float(i) / 32.0 * PI))
		pos += direction * length / 32.0
	var road := {"id": next_id, "parent": parent_id, "depth": depth, "heading": heading, "points": points, "expanded": false}
	next_id += 1
	_render_road(road)
	roads.append(road)
	graph_revision += 1
	# Newly chosen branches may enter an existing forest tile. Rebuild only those tiles.
	var dirty: Dictionary = {}
	for point: Vector3 in points:
		for dx in [-9.0, 9.0]:
			for dz in [-9.0, 9.0]:
				dirty[Vector2i(floori((point.x + dx) / TILE_SIZE), floori((point.z + dz) / TILE_SIZE))] = true
	for key: Vector2i in dirty:
		if tiles.has(key):
			tiles[key].queue_free()
			tiles.erase(key)
			if not pending_tiles.has(key):
				pending_tiles.append(key)

func _render_road(road: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Road_%d" % road.id
	add_child(root)
	road.node = root
	var points: PackedVector3Array = road.points
	_make_ribbon(root, points, ROAD_WIDTH + 2.2, -0.035, shoulder_material)
	_make_ribbon(root, points, ROAD_WIDTH, 0.0, road_material)
	for i in range(1, points.size() - 1, 3):
		var a := points[i]
		var b := points[i + 1]
		var stripe := Geo.box(root, Vector3(0.12, 0.012, a.distance_to(b) * 0.55), (a + b) * 0.5 + Vector3.UP * 0.022, stripe_material)
		stripe.look_at(b)
	if int(road.depth) % 2 == 0:
		var end := points[-1]
		var post := end + Vector3(6.6, 0.0, 6.0)
		post.y = height_at(post.x, post.z)
		Geo.cylinder(root, 0.13, 2.8, post + Vector3.UP * 1.4, trunk_material)
		var sign_mesh := Geo.box(root, Vector3(1.25, 1.25, 0.12), post + Vector3.UP * 2.7, stripe_material)
		sign_mesh.rotation.z = PI / 4.0
		var label := Label3D.new()
		label.text = "Y"
		label.font_size = 100
		label.pixel_size = 0.012
		label.modulate = Color("303c35")
		label.position = post + Vector3(0.0, 2.7, 0.09)
		root.add_child(label)

func _make_ribbon(parent: Node3D, points: PackedVector3Array, width: float, lift: float, mat: Material) -> void:
	var vertices := PackedVector3Array()
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var side := (b - a).normalized().cross(Vector3.UP) * width * 0.5
		var al := ground_point(a.x - side.x, a.z - side.z, 0.17 + lift)
		var ar := ground_point(a.x + side.x, a.z + side.z, 0.17 + lift)
		var bl := ground_point(b.x - side.x, b.z - side.z, 0.17 + lift)
		var br := ground_point(b.x + side.x, b.z + side.z, 0.17 + lift)
		vertices.append_array(PackedVector3Array([al, ar, bl, ar, br, bl]))
	Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, mat)

func nearest_road(at: Vector3) -> Dictionary:
	var best := {"distance": INF, "point": Vector3.ZERO, "direction": Vector3.FORWARD, "road_id": 0}
	var flat := Vector2(at.x, at.z)
	for road: Dictionary in roads:
		var points: PackedVector3Array = road.points
		for i in range(points.size() - 1):
			var a := Vector2(points[i].x, points[i].z)
			var b := Vector2(points[i + 1].x, points[i + 1].z)
			var t := clampf((flat - a).dot(b - a) / (b - a).length_squared(), 0.0, 1.0)
			var p := a.lerp(b, t)
			var dist := flat.distance_to(p)
			if dist < best.distance:
				best = {"distance": dist, "point": points[i].lerp(points[i + 1], t), "direction": (points[i + 1] - points[i]).normalized(), "road_id": road.id}
	return best

func road_distance(at: Vector3) -> float:
	return nearest_road(at).distance

func _build_tile(key: Vector2i) -> void:
	if tiles.has(key):
		return
	var root := Node3D.new()
	root.name = "Forest_%d_%d" % [key.x, key.y]
	add_child(root)
	tiles[key] = root
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(world_seed + key.x * 73856093 + key.y * 19349663)
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var origin := Vector2(key) * TILE_SIZE
	var steps := 10
	var step_size := TILE_SIZE / steps
	for x in steps:
		for z in steps:
			var a := ground_point(origin.x + x * step_size, origin.y + z * step_size)
			var b := ground_point(a.x + step_size, a.z)
			var c := ground_point(a.x, a.z + step_size)
			var d := ground_point(a.x + step_size, a.z + step_size)
			vertices.append_array(PackedVector3Array([a, c, b, b, c, d]))
			var color := Color("6f8057").lerp(Color("92966a"), rng.randf() * 0.65)
			for _j in 6:
				colors.append(color)
	var terrain := Geo.instance(root, Geo.mesh_from_triangles(vertices, colors), Vector3.ZERO, terrain_material)
	terrain.create_trimesh_collision()
	var trees: Array[Transform3D] = []
	var trunks: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	for _i in 60:
		var p := ground_point(origin.x + rng.randf() * TILE_SIZE, origin.y + rng.randf() * TILE_SIZE)
		if road_distance(p) < 8.5 or p.distance_to(Vector3.ZERO) < 12.0:
			continue
		var scale_y := rng.randf_range(0.7, 1.5)
		var scale_x := rng.randf_range(0.75, 1.2)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(scale_x, scale_y, scale_x))
		trees.append(Transform3D(basis, p))
		trunks.append(Transform3D(basis, p + Vector3.UP * scale_y * 1.8))
		var body := StaticBody3D.new()
		var collider := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.height = 3.8 * scale_y
		shape.radius = 0.32 * scale_x
		collider.shape = shape
		body.position = p + Vector3.UP * shape.height * 0.5
		body.add_child(collider)
		root.add_child(body)
	for _i in 7:
		var p := ground_point(origin.x + rng.randf() * TILE_SIZE, origin.y + rng.randf() * TILE_SIZE)
		if road_distance(p) < 7.0:
			continue
		var rock_scale := Vector3(rng.randf_range(0.6, 1.8), rng.randf_range(0.4, 1.1), rng.randf_range(0.7, 1.5))
		rocks.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(rock_scale), p))
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = rock_scale.x * 0.65
		shape.shape = sphere
		body.position = p
		body.add_child(shape)
		root.add_child(body)
	_multimesh(root, tree_mesh, leaf_material, trees)
	_multimesh(root, trunk_mesh, trunk_material, trunks)
	_multimesh(root, rock_mesh, rock_material, rocks)

func _build_tree_mesh() -> void:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for tier in 3:
		var radius := 2.25 - tier * 0.48
		var base := 1.6 + tier * 1.65
		for side in 6:
			var angle := side * TAU / 6.0
			var a := Vector3(cos(angle) * radius, base, sin(angle) * radius)
			var b := Vector3(cos(angle + TAU / 6.0) * radius, base, sin(angle + TAU / 6.0) * radius)
			vertices.append_array(PackedVector3Array([a, Vector3(0, base + 3.7, 0), b]))
			var shade := Color("284c41").lerp(Color("507359"), float((side + tier) % 3) / 3.0)
			for _j in 3:
				colors.append(shade)
	tree_mesh = Geo.mesh_from_triangles(vertices, colors)
	trunk_mesh = CylinderMesh.new()
	trunk_mesh.height = 3.6
	trunk_mesh.top_radius = 0.22
	trunk_mesh.bottom_radius = 0.36
	trunk_mesh.radial_segments = 6
	rock_mesh = SphereMesh.new()
	rock_mesh.radius = 1.0
	rock_mesh.height = 1.5
	rock_mesh.radial_segments = 5
	rock_mesh.rings = 3

func _multimesh(root: Node3D, mesh: Mesh, mat: Material, transforms: Array[Transform3D]) -> void:
	var node := MultiMeshInstance3D.new()
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for i in transforms.size():
		multi.set_instance_transform(i, transforms[i])
	node.multimesh = multi
	node.material_override = mat
	root.add_child(node)

func export_graph() -> Array:
	var result: Array = []
	for road: Dictionary in roads:
		result.append({"id": road.id, "parent": road.parent, "depth": road.depth, "heading": road.heading, "points": road.points, "expanded": road.expanded})
	return result

func import_graph(data: Array) -> void:
	var incoming: Dictionary = {}
	for record: Dictionary in data:
		incoming[record.id] = true
		var found := false
		for road: Dictionary in roads:
			if road.id == record.id:
				found = true
				break
		if not found:
			_render_road(record)
			roads.append(record)
	for road: Dictionary in roads.duplicate():
		if not incoming.has(road.id):
			road.node.queue_free()
			roads.erase(road)
	# Rebuild decor after a graph update to keep trees off newly received roads.
	for key: Vector2i in tiles:
		tiles[key].queue_free()
	tiles.clear()
	last_tile = Vector2i(99999, 99999)
	update_stream(focus, true)
