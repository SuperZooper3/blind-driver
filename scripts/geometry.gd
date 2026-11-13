extends RefCounted
## Small, code-only low-poly modeling kit. All art is original procedural geometry.

static func material(color: Color, roughness: float = 0.95) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat

static func box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return instance(parent, mesh, at, mat)

static func cylinder(parent: Node3D, radius: float, height: float, at: Vector3, mat: Material, top: float = -1.0, sides: int = 8) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top < 0.0 else top
	mesh.height = height
	mesh.radial_segments = sides
	mesh.rings = 1
	return instance(parent, mesh, at, mat)

static func sphere(parent: Node3D, radius: float, at: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	return instance(parent, mesh, at, mat)

static func instance(parent: Node3D, mesh: Mesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.position = at
	parent.add_child(node)
	return node

static func mesh_from_triangles(vertices: PackedVector3Array, colors: PackedColorArray = PackedColorArray()) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	for i in vertices.size():
		# Godot's front faces use clockwise winding. Inputs use a right-hand normal.
		var index: int = i - i % 3 + [0, 2, 1][i % 3]
		if not colors.is_empty():
			surface.set_color(colors[index])
		surface.add_vertex(vertices[index])
	surface.generate_normals()
	return surface.commit()
