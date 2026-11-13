extends RefCounted
## Immutable obstacle records travel with the road graph. Only the driver simulates hits.
const Geo = preload("res://scripts/geometry.gd")
const KINDS := ["rock", "tree", "ramp", "bumps", "construction", "cliff", "lake"]

static func is_void(hazard: Dictionary) -> bool:
	return hazard.kind in ["cliff", "lake"]

static func contains(hazard: Dictionary, point: Vector3, margin: float = 0.0) -> bool:
	return absf(point.x - hazard.position.x) < hazard.size.x * 0.5 + margin and absf(point.z - hazard.position.z) < hazard.size.z * 0.5 + margin

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

static func _wedge(parent: Node3D, at: Vector3, width: float, length: float, height: float, mat: Material, rounded: bool = false) -> void:
	var a := at + Vector3(-width / 2, 0, length / 2)
	var b := at + Vector3(width / 2, 0, length / 2)
	var c := at + Vector3(-width / 2, height, 0 if rounded else -length / 2)
	var d := at + Vector3(width / 2, height, 0 if rounded else -length / 2)
	var e := at + Vector3(-width / 2, 0, -length / 2)
	var f := at + Vector3(width / 2, 0, -length / 2)
	var vertices := PackedVector3Array([a, b, c, b, d, c, c, d, e, d, f, e, a, c, e, b, f, d])
	Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, mat).create_trimesh_collision()

static func _render_void(parent: Node3D, hazard: Dictionary) -> void:
	var p: Vector3 = hazard.position
	var size: Vector3 = hazard.size
	var earth := Geo.material(Color("655b4a"))
	Geo.box(parent, Vector3(size.x, 1, size.z), p - Vector3.UP * 0.5, earth).create_convex_collision()
	var vertices := PackedVector3Array()
	var corners := [Vector2(p.x - size.x / 2, p.z - size.z / 2), Vector2(p.x + size.x / 2, p.z - size.z / 2), Vector2(p.x + size.x / 2, p.z + size.z / 2), Vector2(p.x - size.x / 2, p.z + size.z / 2)]
	for edge in 4:
		var a: Vector2 = corners[edge]
		var b: Vector2 = corners[(edge + 1) % 4]
		var steps := roundi(a.distance_to(b) / 8.0)
		for i in steps:
			var x := a.lerp(b, float(i) / steps)
			var y := a.lerp(b, float(i + 1) / steps)
			var top_a := Vector3(x.x, terrain_height(x.x, x.y), x.y)
			var top_b := Vector3(y.x, terrain_height(y.x, y.y), y.y)
			var bottom_a := Vector3(x.x, p.y, x.y)
			var bottom_b := Vector3(y.x, p.y, y.y)
			vertices.append_array(PackedVector3Array([top_a, bottom_a, top_b, top_b, bottom_a, bottom_b]))
	var walls := Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, earth)
	walls.material_override.cull_mode = BaseMaterial3D.CULL_DISABLED
	walls.create_trimesh_collision()
	if hazard.kind == "lake":
		var water := Geo.material(Color("488c96"), 0.25)
		Geo.box(parent, Vector3(size.x - 0.1, 0.1, size.z - 0.1), p + Vector3.UP * (size.y - 3.0), water)
	else:
		# Broken edge markers frame the opening; the center remains driveable.
		for offset in [-8.0, 8.0]:
			var marker := Vector3(p.x + offset, terrain_height(p.x + offset, p.z + size.z / 2), p.z + size.z / 2 + 1.0)
			Geo.cylinder(parent, 0.12, 1.4, marker + Vector3.UP * 0.7, Geo.material(Color("e7b566")))

static func terrain_height(x: float, z: float) -> float:
	return sin(x * 0.018) * 1.6 + sin(z * 0.014) * 2.2 + sin((x + z) * 0.037) * 0.45
