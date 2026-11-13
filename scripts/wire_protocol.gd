extends RefCounted
## JSON boundary for the public relay. Local LAN mode keeps native Godot RPC.

static func vector_to_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

static func array_to_vector(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])

static func snapshot_to_json(state: Dictionary) -> Dictionary:
	var result := state.duplicate()
	var transform: Transform3D = state.transform
	var rotation := transform.basis.orthonormalized().get_rotation_quaternion()
	result.erase("transform")
	result.position = vector_to_array(transform.origin)
	result.rotation = [rotation.x, rotation.y, rotation.z, rotation.w]
	result.velocity = vector_to_array(state.velocity)
	return result

static func snapshot_from_json(data: Dictionary) -> Dictionary:
	for key in ["seq", "time", "speed", "steering", "throttle", "distance", "grounded", "reset"]:
		if not _number(data.get(key)):
			return {}
	if not _vector(data.get("position"), 3) or not _vector(data.get("velocity"), 3) or not _vector(data.get("rotation"), 4) or typeof(data.get("lights")) != TYPE_BOOL:
		return {}
	var q: Array = data.rotation
	var rotation := Quaternion(q[0], q[1], q[2], q[3])
	if absf(rotation.length_squared() - 1.0) > 0.02:
		return {}
	var result := data.duplicate()
	result.transform = Transform3D(Basis(rotation.normalized()), array_to_vector(data.position))
	result.velocity = array_to_vector(data.velocity)
	return result

static func graph_to_json(roads: Array) -> Array:
	var result: Array = []
	for road: Dictionary in roads:
		var record := road.duplicate()
		var points: Array = []
		for point: Vector3 in road.points:
			points.append(vector_to_array(point))
		record.points = points
		result.append(record)
	return result

static func graph_from_json(data: Array) -> Array:
	if data.is_empty() or data.size() > 100:
		return []
	var result: Array = []
	var ids: Dictionary = {}
	for value: Variant in data:
		if not value is Dictionary:
			return []
		var road: Dictionary = value
		for key in ["id", "parent", "depth", "heading"]:
			if not _number(road.get(key)):
				return []
		if ids.has(road.id) or typeof(road.get("expanded")) != TYPE_BOOL or not road.get("points") is Array:
			return []
		ids[road.id] = true
		if road.points.size() < 2 or road.points.size() > 64:
			return []
		var points := PackedVector3Array()
		for point: Variant in road.points:
			if not _vector(point, 3):
				return []
			var decoded := array_to_vector(point)
			if not points.is_empty() and points[-1].distance_squared_to(decoded) < 0.0001:
				return []
			points.append(decoded)
		result.append({"id": int(road.id), "parent": int(road.parent), "depth": int(road.depth), "heading": float(road.heading), "expanded": road.expanded, "points": points})
	return result

static func _number(value: Variant) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value)) and absf(float(value)) <= 1.0e12

static func _vector(value: Variant, length: int) -> bool:
	if not value is Array or value.size() != length:
		return false
	for number: Variant in value:
		if not _number(number):
			return false
	return true
