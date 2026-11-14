extends RefCounted
## Shared visual resources. Seasons never rebuild terrain, roads, or collision bodies.
const Geo = preload("res://scripts/geometry.gd")
const NAMES := ["SPRING", "SUMMER", "FALL", "WINTER", "HELL"]
const PALETTES := [
	{"ground_low": "729653", "ground_high": "a4bd72", "leaf_low": "679c4f", "leaf_high": "a1c76e", "bark": "685340", "sky": "8bb7ba", "horizon": "e0dfbf", "fog": "c1d2b1", "sun": "fff1d8"},
	{"ground_low": "435c42", "ground_high": "71845c", "leaf_low": "284c41", "leaf_high": "507359", "bark": "4a4234", "sky": "779b9a", "horizon": "d3d2ac", "fog": "b7c7b1", "sun": "f8ecd5"},
	{"ground_low": "826342", "ground_high": "bb995e", "leaf_low": "a63826", "leaf_high": "ed9a36", "bark": "574234", "sky": "a6a9ad", "horizon": "e5c7a1", "fog": "ccb394", "sun": "ffe0b0"},
	{"ground_low": "cedbe0", "ground_high": "f4f5ed", "leaf_low": "cedbe0", "leaf_high": "f4f5ed", "bark": "514b49", "sky": "829ba8", "horizon": "e1e8eb", "fog": "d4e0e5", "sun": "e4edff"},
	{"ground_low": "762c24", "ground_high": "bf4932", "leaf_low": "291e1c", "leaf_high": "49302a", "bark": "302523", "sky": "452d32", "horizon": "ce6c44", "fog": "a95740", "sun": "ffb07c"},
]
const BRUSH_PALETTES := [
	{"leaf_low": "697b47", "leaf_high": "8c9b58", "thorn_low": "b2a57b", "thorn_high": "d0bc85"},
	{"leaf_low": "4d5840", "leaf_high": "6a7046", "thorn_low": "b2a57b", "thorn_high": "d0bc85"},
	{"leaf_low": "73513b", "leaf_high": "a57a46", "thorn_low": "b2a57b", "thorn_high": "d0bc85"},
	{"leaf_low": "bdcdd1", "leaf_high": "e8f1f3", "thorn_low": "737e81", "thorn_high": "a2aaad"},
	{"leaf_low": "48342b", "leaf_high": "714a36", "thorn_low": "b08f6e", "thorn_high": "d0a379"},
]
var stage := 0
var terrain_material := ShaderMaterial.new()
var undergrowth_material := ShaderMaterial.new()
var bark_material := Geo.material(Color.WHITE)
var foliage_material := Geo.material(Color.WHITE)
var flame_material := ShaderMaterial.new()
var canopies: Array[ArrayMesh] = []
var branches: ArrayMesh
var flames: ArrayMesh

func _init() -> void:
	terrain_material.shader = preload("res://shaders/season_ground.gdshader")
	undergrowth_material.shader = preload("res://shaders/season_undergrowth.gdshader")
	foliage_material.vertex_color_use_as_albedo = true
	foliage_material.vertex_color_is_srgb = true
	flame_material.shader = preload("res://shaders/tree_flame.gdshader")
	for i in 3:
		canopies.append(_canopy(Color(PALETTES[i].leaf_low), Color(PALETTES[i].leaf_high)))
	branches = _branches()
	flames = _flames()
	set_stage(0)

func set_stage(value: int) -> void:
	stage = clampi(value, 0, 4)
	var palette: Dictionary = PALETTES[stage]
	terrain_material.set_shader_parameter("ground_low", Color(palette.ground_low))
	terrain_material.set_shader_parameter("ground_high", Color(palette.ground_high))
	bark_material.albedo_color = Color(palette.bark)
	for parameter: String in BRUSH_PALETTES[stage]:
		undergrowth_material.set_shader_parameter(parameter, Color(BRUSH_PALETTES[stage][parameter]))

func add_trees(parent: Node3D, transforms: Array[Transform3D]) -> void:
	var root := Node3D.new()
	root.name = "SeasonalTrees"
	parent.add_child(root)
	var late: Array[Transform3D] = []
	var early: Array[Transform3D] = []
	var burning: Array[Transform3D] = []
	for i in transforms.size():
		# No random draws: seasons preserve seeded tree positions and hazard generation.
		if i % 3 == 0: early.append(transforms[i])
		else: late.append(transforms[i])
		if i % 4 == 0: burning.append(transforms[i])
	_batch(root, "LateLeaves", canopies[0], foliage_material, late)
	_batch(root, "EarlyLeaves", canopies[0], foliage_material, early)
	_batch(root, "Branches", branches, bark_material, transforms)
	_batch(root, "Flames", flames, flame_material, burning)
	apply_to_trees(root)

func apply_to_trees(root: Node3D) -> void:
	for layer: String in ["LateLeaves", "EarlyLeaves"]:
		var canopy: MultiMeshInstance3D = root.get_node(layer)
		canopy.multimesh.mesh = canopies[mini(stage, 2)]
		canopy.visible = stage < 3 and (stage < 2 or layer == "LateLeaves")
	root.get_node("Branches").visible = stage >= 2
	root.get_node("Flames").visible = stage == 4

static func _batch(parent: Node3D, label: String, mesh: Mesh, material: Material, transforms: Array[Transform3D]) -> void:
	var node := MultiMeshInstance3D.new()
	node.name = label
	node.multimesh = MultiMesh.new()
	node.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	node.multimesh.mesh = mesh
	node.multimesh.instance_count = transforms.size()
	for i in transforms.size():
		node.multimesh.set_instance_transform(i, transforms[i])
	node.material_override = material
	if label == "Flames":
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)

static func _canopy(low: Color, high: Color) -> ArrayMesh:
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
			var shade := low.lerp(high, float((side + tier) % 3) / 3.0)
			for _j in 3: colors.append(shade)
	return Geo.mesh_from_triangles(vertices, colors)

static func _limb(vertices: PackedVector3Array, base: Vector3, tip: Vector3, radius: float, tip_radius: float) -> void:
	var up := (tip - base).normalized()
	var side := up.cross(Vector3.FORWARD).normalized()
	var front := side.cross(up).normalized()
	for i in 5:
		var a := side * cos(i * TAU / 5.0) + front * sin(i * TAU / 5.0)
		var b := side * cos((i + 1) * TAU / 5.0) + front * sin((i + 1) * TAU / 5.0)
		vertices.append_array(PackedVector3Array([base + a * radius, tip + a * tip_radius, base + b * radius, base + b * radius, tip + a * tip_radius, tip + b * tip_radius]))

static func _branches() -> ArrayMesh:
	var vertices := PackedVector3Array()
	_limb(vertices, Vector3(0, 3.0, 0), Vector3(0.14, 7.5, -0.12), 0.24, 0.015)
	for i in 9:
		var angle := i * 2.4
		var base := Vector3(0, 2.4 + i * 0.43, 0)
		var reach := 2.25 - i * 0.14
		var tip := base + Vector3(cos(angle) * reach, 0.8, sin(angle) * reach)
		_limb(vertices, base, tip, 0.15 - i * 0.009, 0.018)
		_limb(vertices, base.lerp(tip, 0.6), tip + Vector3(-sin(angle) * 0.45, 0.85, cos(angle) * 0.45), 0.055, 0.006)
	return Geo.mesh_from_triangles(vertices)

static func _flames() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	for i in 3:
		var at := Vector3(cos(i * 2.4) * 0.8, 2.8 + i * 0.75, sin(i * 2.4) * 0.8)
		for core in 2:
			var radius := 0.3 if core == 0 else 0.17
			var height := 1.3 if core == 0 else 0.75
			var base := at + Vector3.UP * (0.0 if core == 0 else -0.08)
			for side in 5:
				var a := base + Vector3(cos(side * TAU / 5.0) * radius, 0, sin(side * TAU / 5.0) * radius)
				var b := base + Vector3(cos((side + 1) * TAU / 5.0) * radius, 0, sin((side + 1) * TAU / 5.0) * radius)
				vertices.append_array(PackedVector3Array([a, base + Vector3(0.16, height, 0.1), b]))
				for _j in 3: colors.append(Color("ff6a16") if core == 0 else Color("ffe890"))
	return Geo.mesh_from_triangles(vertices, colors)
