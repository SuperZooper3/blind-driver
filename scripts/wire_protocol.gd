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
	result.angular_velocity = vector_to_array(state.angular_velocity)
	return result

static func snapshot_from_json(data: Dictionary) -> Dictionary:
	for key in ["seq", "time", "speed", "steering", "throttle", "distance", "grounded", "reset"]:
		if not _number(data.get(key)):
			return {}
	if not _vector(data.get("position"), 3) or not _vector(data.get("velocity"), 3) or not _vector(data.get("rotation"), 4) or typeof(data.get("lights")) != TYPE_BOOL:
		return {}
	if not _vector(data.get("angular_velocity"), 3) or not _vector(data.get("wheels"), 4):
		return {}
	if not data.get("run_state") in ["driving", "falling", "game_over"] or not data.get("crash_reason") is String or data.crash_reason.length() > 96:
		return {}
	if not _number(data.get("run_id")) or not _number(data.get("impact")) or typeof(data.get("on_road")) != TYPE_BOOL:
		return {}
	if not _number(data.get("tires")) or int(data.tires) != data.tires or data.tires < 0 or data.tires > 15:
		return {}
	if not _police_state(data.get("police")):
		return {}
	var q: Array = data.rotation
	var rotation := Quaternion(q[0], q[1], q[2], q[3])
	if absf(rotation.length_squared() - 1.0) > 0.02:
		return {}
	var result := data.duplicate()
	result.transform = Transform3D(Basis(rotation.normalized()), array_to_vector(data.position))
	result.velocity = array_to_vector(data.velocity)
	result.angular_velocity = array_to_vector(data.angular_velocity)
	return result

static func graph_to_json(roads: Array) -> Array:
	var result: Array = []
	for road: Dictionary in roads:
		var record := road.duplicate()
		var points: Array = []
		for point: Vector3 in road.points:
			points.append(vector_to_array(point))
		record.points = points
		record.hazards = []
		for hazard: Dictionary in road.hazards:
			var item := hazard.duplicate()
			item.position = vector_to_array(hazard.position)
			item.size = vector_to_array(hazard.size)
			record.hazards.append(item)
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
		if typeof(road.get("danger")) != TYPE_BOOL or not road.get("hazards") is Array or road.hazards.size() > 8:
			return []
		var hazards: Array = []
		for hazard: Variant in road.hazards:
			if not hazard is Dictionary or not hazard.get("kind") in preload("res://scripts/road_hazards.gd").KINDS:
				return []
			if not _vector(hazard.get("position"), 3) or not _vector(hazard.get("size"), 3) or not _number(hazard.get("yaw")):
				return []
			var extent := array_to_vector(hazard.size)
			if extent.x <= 0 or extent.y <= 0 or extent.z <= 0 or extent.x > 192 or extent.y > 48 or extent.z > 192:
				return []
			hazards.append({"kind": hazard.kind, "position": array_to_vector(hazard.position), "size": extent, "yaw": float(hazard.yaw)})
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
		result.append({"id": int(road.id), "parent": int(road.parent), "depth": int(road.depth), "heading": float(road.heading), "expanded": road.expanded, "points": points, "danger": road.danger, "hazards": hazards})
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

static func _police_state(value: Variant) -> bool:
	if not value is Dictionary or not _vector(value.get("position"), 3) or not _vector(value.get("rotation"), 4):
		return false
	if not value.get("phase") in ["waiting", "chasing", "escaped", "caught"] or typeof(value.get("paused")) != TYPE_BOOL:
		return false
	for key in ["elapsed", "speed", "gap", "closing", "catch"]:
		if not _number(value.get(key)): return false
	var q: Array = value.rotation
	if absf(Quaternion(q[0], q[1], q[2], q[3]).length_squared() - 1.0) > 0.02: return false
	return value.elapsed >= 0 and value.speed >= 0 and value.speed <= 45 and value.gap >= 0 and value.gap <= 1.0e7 and absf(value.closing) <= 100 and value.catch >= 0 and value.catch <= 1
