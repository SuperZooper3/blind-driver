extends RefCounted
## Immutable obstacle records travel with the road graph. Only the driver simulates hits.
const Geo = preload("res://scripts/geometry.gd")
const KINDS := ["rock", "tree", "ramp", "bumps", "construction", "spikes", "cliff", "lake", "jump_gap", "timed_bridge"]

static func is_void(hazard: Dictionary) -> bool:
	return hazard.kind in ["cliff", "lake", "jump_gap", "timed_bridge"]

static func contains(hazard: Dictionary, point: Vector3, margin: float = 0.0) -> bool:
	if absf(point.x - hazard.position.x) >= hazard.size.x * 0.5 + margin or absf(point.z - hazard.position.z) >= hazard.size.z * 0.5 + margin:
		return false
	if hazard.kind != "cliff" or margin > 0:
		return true
	# Chipped, chamfered edges share the terrain's 8 m grid: no invisible lids or gaps.
	var row := floori((point.z - hazard.position.z + hazard.size.z * 0.5) / 8.0)
	var rows := roundi(hazard.size.z / 8.0)
	var end_distance := mini(row, rows - row - 1)
	var inset := 24.0 if end_distance == 0 else (16.0 if end_distance == 1 else (8.0 if end_distance % 3 == 2 else 0.0))
	return absf(point.x - hazard.position.x) < hazard.size.x * 0.5 - inset

static func render(parent: Node3D, hazard: Dictionary, tree_mesh: Mesh) -> void:
	if is_void(hazard):
		_render_void(parent, hazard)
		return
	var root := Node3D.new()
	root.name = hazard.kind
	parent.add_child(root)
	root.position = hazard.position
	root.rotation.y = hazard.yaw
	var stone := Geo.material(Color("7b8178"))
	var orange := Geo.material(Color("e18b3f"))
	var white := Geo.material(Color("eee4be"))
	var dark := Geo.material(Color("333c36"))
	match hazard.kind:
		"rock":
			var rock := Geo.sphere(root, 1.15, Vector3(0, 0.6, 0), stone)
			rock.scale = Vector3(1.15, 0.85, 1.3)
			rock.create_convex_collision()
			Geo.sphere(root, 0.45, Vector3(1.6, 0.2, -0.6), stone).create_convex_collision()
		"tree":
			Geo.cylinder(root, 0.62, 4.5, Vector3.UP * 2.25, Geo.material(Color("594937")), 0.4).create_convex_collision()
			var leaves := Geo.material(Color.WHITE)
			leaves.vertex_color_use_as_albedo = true
			Geo.instance(root, tree_mesh, Vector3.ZERO, leaves)
		"ramp":
			# A half-width ramp pitches one side of the car up: approach slowly or roll.
			_wedge(root, Vector3.ZERO, 2.2, 4.0, 1.8, orange)
			for x in [-0.9, 0.9]:
				Geo.box(root, Vector3(0.13, 0.05, 4.38), Vector3(x, 0.92, 0), white).rotation.x = atan(1.8 / 4.0)
		"bumps":
			for z in [-2.5, 0.0, 2.5]:
				_wedge(root, Vector3(0, 0, z), 7.4, 0.9, 0.22, orange, true)
		"construction":
			Geo.box(root, Vector3(2.4, 0.8, 0.5), Vector3(0, 0.9, 0), orange).create_convex_collision()
			for x in [-0.9, 0.0, 0.9]:
				var stripe := Geo.box(root, Vector3(0.22, 0.85, 0.54), Vector3(x, 0.9, 0), white)
				stripe.rotation.z = -0.35
			for x in [-0.9, 0.9]:
				Geo.box(root, Vector3(0.14, 0.6, 0.65), Vector3(x, 0.3, 0), dark).create_convex_collision()
			for i in 5:
				var p := Vector3(-0.9 + i * 0.45, 0, 3.0 + i * 2.0)
				Geo.box(root, Vector3(0.65, 0.12, 0.65), p, dark)
				Geo.cylinder(root, 0.28, 0.85, p + Vector3.UP * 0.45, orange, 0.05).create_convex_collision()

		"spikes":
			# No collider: the car rolls straight over it, and every tire it touches pops.
			var base := Geo.box(root, Vector3(4.0, 0.06, 0.5), Vector3(0, 0.03, 0), dark)
			base.name = "SpikeStrip"
			var steel := Geo.material(Color("c9ccc8"))
			for i in 16:
				for row in [-0.12, 0.12]:
					var spike := Geo.cylinder(root, 0.05, 0.22, Vector3(-1.875 + i * 0.25, 0.12, row), steel, 0.0, 6)
					spike.rotation.x = 0.35 if row < 0 else -0.35

static func _wedge(parent: Node3D, at: Vector3, width: float, length: float, height: float, mat: Material, rounded: bool = false) -> void:
	var a := at + Vector3(-width / 2, 0, length / 2)
	var b := at + Vector3(width / 2, 0, length / 2)
	var c := at + Vector3(-width / 2, height, 0 if rounded else -length / 2)
	var d := at + Vector3(width / 2, height, 0 if rounded else -length / 2)
	var e := at + Vector3(-width / 2, 0, -length / 2)
	var f := at + Vector3(width / 2, 0, -length / 2)
	var vertices := PackedVector3Array([a, b, c, b, d, c, c, d, e, d, f, e, a, c, e, b, f, d])
	Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, mat).create_trimesh_collision()

static func rim_edges(hazard: Dictionary) -> Array:
	var edges: Array = []
	var half: Vector3 = hazard.size * 0.5
	var start: Vector3 = hazard.position - half
	var directions := [Vector3.RIGHT, Vector3.BACK, Vector3.LEFT, Vector3.FORWARD]
	for x in roundi(hazard.size.x / 8.0):
		for z in roundi(hazard.size.z / 8.0):
			var center := Vector3(start.x + x * 8 + 4, 0, start.z + z * 8 + 4)
			if not contains(hazard, center):
				continue
			for direction: Vector3 in directions:
				if contains(hazard, center + direction * 8):
					continue
				var side := direction.cross(Vector3.UP) * 4
				var a := center + direction * 4 - side
				var b := center + direction * 4 + side
				a.y = terrain_height(a.x, a.z)
				b.y = terrain_height(b.x, b.z)
				edges.append([a, b])
	return edges

static func _render_void(parent: Node3D, hazard: Dictionary) -> void:
	var p: Vector3 = hazard.position
	var size: Vector3 = hazard.size
	var earth := Geo.material(Color("514b40"))
	var floor_mesh := Geo.box(parent, Vector3(size.x, 1, size.z), p - Vector3.UP * 0.5, earth)
	floor_mesh.name = "RavineFloor" if hazard.kind == "cliff" else "LakeBed"
	floor_mesh.create_convex_collision()
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var rim_vertices := PackedVector3Array()
	var edges := rim_edges(hazard)
	for edge in edges:
		var a: Vector3 = edge[0]
		var b: Vector3 = edge[1]
		var inward := (b - a).cross(Vector3.UP).normalized()
		# Continuous stone faces all the way around, with broken shelves and dark strata.
		for layer in 3:
			var t0 := layer / 3.0
			var t1 := (layer + 1) / 3.0
			var top_a := a.lerp(Vector3(a.x, p.y, a.z), t0) + inward * sin(t0 * PI) * 2.0
			var top_b := b.lerp(Vector3(b.x, p.y, b.z), t0) + inward * sin(t0 * PI) * 2.0
			var bottom_a := a.lerp(Vector3(a.x, p.y, a.z), t1) + inward * sin(t1 * PI) * 2.0
			var bottom_b := b.lerp(Vector3(b.x, p.y, b.z), t1) + inward * sin(t1 * PI) * 2.0
			vertices.append_array(PackedVector3Array([top_a, bottom_a, top_b, top_b, bottom_a, bottom_b]))
			var shade := Color("756b55").lerp(Color("3e453f"), t0 + fposmod(a.x * 0.21 + a.z * 0.13, 0.18))
			for _i in 6:
				colors.append(shade)
		var outer_a := a - inward * 1.1 + Vector3.UP * 0.025
		var outer_b := b - inward * 1.1 + Vector3.UP * 0.025
		rim_vertices.append_array(PackedVector3Array([a + Vector3.UP * 0.03, b + Vector3.UP * 0.03, outer_a, b + Vector3.UP * 0.03, outer_b, outer_a]))
	var rock := Geo.material(Color.WHITE)
	rock.vertex_color_use_as_albedo = true
	rock.cull_mode = BaseMaterial3D.CULL_DISABLED
	var walls := Geo.instance(parent, Geo.mesh_from_triangles(vertices, colors), Vector3.ZERO, rock)
	walls.name = "RavineWalls"
	walls.create_trimesh_collision()
	Geo.instance(parent, Geo.mesh_from_triangles(rim_vertices), Vector3.ZERO, Geo.material(Color("a29a73")))
	if hazard.kind == "lake":
		var water := Geo.material(Color("488c96"), 0.25)
		Geo.box(parent, Vector3(size.x - 0.1, 0.1, size.z - 0.1), p + Vector3.UP * (size.y - 3.0), water)
	else:
		for i in 18:
			var at := p + Vector3(sin(i * 7.3) * size.x * 0.32, 0.0, cos(i * 4.7) * size.z * 0.32)
			var rubble := Geo.sphere(parent, 1.0 + fposmod(i * 0.73, 2.3), at, earth)
			rubble.scale = Vector3(1.6, 0.7, 1.1)

static func make_thorn_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	# Broad low foliage and pale, crossed thorn stems read clearly from a car seat.
	for clump in 3:
		var at := Vector3(sin(clump * 2.1) * 1.0, 0, cos(clump * 2.1) * 1.0)
		for side in 6:
			var angle := side * TAU / 6.0
			var a := at + Vector3(cos(angle) * 1.8, 0.2, sin(angle) * 1.8)
			var b := at + Vector3(cos(angle + TAU / 6.0) * 1.8, 0.2, sin(angle + TAU / 6.0) * 1.8)
			vertices.append_array(PackedVector3Array([a, at + Vector3(0, 0.85 + clump * 0.12, 0), b]))
			for _i in 3:
				colors.append(Color("4d5840") if (side + clump) % 2 else Color("6a7046"))
	for stem in 5:
		var angle := stem * TAU / 5.0
		var direction := Vector3(cos(angle), 0.28, sin(angle))
		var side := direction.cross(Vector3.UP).normalized() * 0.065
		var base := Vector3(0, 0.45, 0)
		var tip := base + direction * 2.6
		vertices.append_array(PackedVector3Array([base - side, base + side, tip, base - Vector3.UP * 0.065, tip, base + Vector3.UP * 0.065]))
		for _i in 6:
			colors.append(Color("b2a57b"))
		for thorn in 3:
			var at := base.lerp(tip, 0.3 + thorn * 0.23)
			vertices.append_array(PackedVector3Array([at - side * 2, at + Vector3.UP * 0.42, at + side * 2]))
			for _i in 3:
				colors.append(Color("d0bc85"))
	return Geo.mesh_from_triangles(vertices, colors)

static func terrain_height(x: float, z: float) -> float:
	return sin(x * 0.018) * 1.6 + sin(z * 0.014) * 2.2 + sin((x + z) * 0.037) * 0.45
