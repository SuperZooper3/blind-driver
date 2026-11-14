extends Node3D
## A bounded road graph with rejoining route choices, terminal roads, and distance-based heat.
## Geometry/decoration are disposable; road records are also used by the map/network.

const Geo = preload("res://scripts/geometry.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
const Challenge = preload("res://scripts/road_challenge.gd")
const TILE_SIZE := 80.0
const TILE_RADIUS := 3
const ROAD_WIDTH := 8.0
const ROAD_MESH_STEP := 3.0
const KEEP_DISTANCE := 720.0
const MAX_ROADS := 100
const THORN_DISTANCE := 18.0
const THORN_CELL := 4.0
const CULDESAC_RADIUS := 14.0
const HEAT_DISTANCE := 750.0
const CLIFF_SIZE := Vector3(160, 36, 112)
## A narrower pit fits between the two through routes when it sits in the middle.
const MIDDLE_HOLE_SIZE := Vector3(64, 36, 64)
## Three-way junctions put the dead end in the middle half the time; otherwise
## it is equally likely on the left or the right (25% each).
const MIDDLE_HOLE_CHANCE := 0.5
## A spike strip covers half the road's width and is half a metre deep.
const SPIKE_HALF_WIDTH := ROAD_WIDTH * 0.25
const SPIKE_HALF_DEPTH := 0.25
## Spikes appear from heat 4 (difficulty 3), at least this far past their warning sign.
const SPIKE_MIN_DIFFICULTY := 3
const SPIKE_WARNING := 100.0
const PROFILES := ["main", "scenic", "rough", "culdesac", "cliff"]
var difficulty := 0
## Opt-in harness curriculum; ordinary play retains the original generator.
var basic_course := false
var world_seed := 72419
var roads: Array[Dictionary] = []
var tiles: Dictionary = {}
var pending_tiles: Array[Vector2i] = []
var next_id := 0
var graph_revision := 0
var challenge_time := 0.0
var jumped_gaps: Dictionary = {}
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
var thorn_mesh: ArrayMesh
var road_cells: Dictionary = {}
const ROAD_CELL_SIZE := 48.0

func _ready() -> void:
	road_material = Geo.material(Color("726b57"))
	shoulder_material = Geo.material(Color("9b9271"))
	stripe_material = Geo.material(Color("dbcb91"))
	terrain_material = Geo.material(Color.WHITE)
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.vertex_color_is_srgb = true
	trunk_material = Geo.material(Color("4a4234"))
	leaf_material = Geo.material(Color.WHITE)
	leaf_material.vertex_color_use_as_albedo = true
	leaf_material.vertex_color_is_srgb = true
	rock_material = Geo.material(Color("838a7e"))
	_build_tree_mesh()
	if allow_generation:
		_add_road(Vector3(0, 0, 40 if basic_course else 150), 0.0, 0, 0, 180.0 if basic_course else 360.0)
		grow_near(Vector3.ZERO)
	update_stream(Vector3.ZERO, true)

static func height_at(x: float, z: float) -> float:
	return Hazards.terrain_height(x, z)

static func ground_point(x: float, z: float, lift: float = 0.0) -> Vector3:
	return Vector3(x, height_at(x, z) + lift, z)

static func heat_for_distance(distance: float) -> int:
	return clampi(floori(distance / HEAT_DISTANCE), 0, 4)

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
	# Only the single safe frontier may grow. Visiting an abandoned fork or the
	# forest must never create another route (or repeatedly expand an old junction).
	var frontier: Dictionary = {}
	for road: Dictionary in roads:
		if not road.danger and not road.expanded:
			if frontier.is_empty() or road.depth > frontier.depth:
				frontier = road
	var nearest := nearest_road(at)
	var on_safe_route := false
	for road: Dictionary in roads:
		if road.id == nearest.road_id:
			on_safe_route = not road.profile in ["cliff", "culdesac"] and nearest.distance < 12.0
	if not frontier.is_empty() and on_safe_route and roads.size() < MAX_ROADS - 3:
		var end: Vector3 = frontier.points[-1]
		if end.distance_to(at) < 235.0:
			frontier.expanded = true
			var depth: int = frontier.depth + 1
			if basic_course:
				_add_road(end, 0.0, depth, frontier.id, 180.0)
			elif frontier.depth % 2 == 0:
				var fork_rng := RandomNumberGenerator.new()
				fork_rng.seed = world_seed + int(frontier.id) * 1531
				var left_safe := fork_rng.randf() > 0.5
				var fork_index: int = frontier.depth / 2
				if fork_index > 0 and fork_index % 3 != 0:
					# Two genuine choices share an endpoint; only the scenic record is
					# the growth frontier, so taking the shortcut cannot sprout a second world.
					var scenic := PackedVector3Array()
					var shortcut := PackedVector3Array()
					var side := -1.0 if left_safe else 1.0
					# Half the time the straight middle road is the dead end (a pit or a
					# cul-de-sac) and both through routes swing around it.
					var middle_hole := fork_rng.randf() < MIDDLE_HOLE_CHANCE
					var terminal := "culdesac" if fork_index % 2 == 1 else "cliff"
					for i in 33:
						var t := i / 32.0
						scenic.append(ground_point(end.x + side * 110.0 * pow(sin(t * PI), 2), end.z - t * 240.0, 0.17))
						var swing := -side * 80.0 * pow(sin(t * PI), 2) if middle_hole else 0.0
						shortcut.append(ground_point(end.x + swing, end.z - t * 240.0, 0.17))
					var scenic_id := _add_road(end, 0.0, depth, frontier.id, 240, false, "scenic", scenic)
					_add_road(end, 0.0, depth, frontier.id, 240, false, "rough", shortcut)
					roads[-1].merge_with = scenic_id
					if middle_hole:
						var drop := PackedVector3Array()
						for i in 33:
							drop.append(ground_point(end.x, end.z - i / 32.0 * 96.0, 0.17))
						_add_road(end, 0.0, depth, frontier.id, 96, terminal == "cliff", terminal, drop, MIDDLE_HOLE_SIZE)
					else:
						_add_road(end, -0.88 if left_safe else 0.88, depth, frontier.id, 140, terminal == "cliff", terminal)
				else:
					_add_road(end, 0.66 if left_safe else -0.66, depth, frontier.id)
					var terminal := "cliff" if fork_index == 0 else "culdesac"
					_add_road(end, -0.88 if left_safe else 0.88, depth, frontier.id, 140, terminal == "cliff", terminal)
			else:
				var continuation := _add_road(end, 0.0, depth, frontier.id, 180.0)
				for road: Dictionary in roads:
					if road.merge_with == frontier.id: road.next = continuation
			graph_revision += 1
	var removed := false
	for road: Dictionary in roads.duplicate():
		var points: PackedVector3Array = road.points
		if at.distance_to(points[0]) > KEEP_DISTANCE and at.distance_to(points[-1]) > KEEP_DISTANCE and road.expanded:
			_invalidate_hazard_tiles(road)
			_invalidate_road_tiles(road.points)
			road.node.queue_free()
			roads.erase(road)
			jumped_gaps.erase(road.id)
			graph_revision += 1
			removed = true
	if removed:
		_rebuild_road_index()

func _add_road(start: Vector3, heading: float, depth: int, parent_id: int, length: float = 155.0, danger: bool = false, profile: String = "main", supplied_points: PackedVector3Array = PackedVector3Array(), hole_size: Vector3 = CLIFF_SIZE) -> int:
	if danger: profile = "cliff"
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + next_id * 7919
	var bend := rng.randf_range(-0.23, 0.23) if depth > 0 else 0.0
	# Straight connector roads give a clear run-up and keep grid-aligned pits away
	# from forks. A set piece replaces ordinary clutter on this entire stretch.
	var challenge_kind := ""
	if not basic_course and profile == "main" and depth > 0 and is_zero_approx(heading):
		if depth % 6 == 2: challenge_kind = "jump_gap"
		elif depth % 6 == 4: challenge_kind = "timed_bridge"
	if not challenge_kind.is_empty(): bend = 0.0
	var points := PackedVector3Array()
	var pos := start
	for i in range(33):
		points.append(ground_point(pos.x, pos.z, 0.17))
		var direction := Vector3.FORWARD.rotated(Vector3.UP, heading + bend * sin(float(i) / 32.0 * PI))
		pos += direction * length / 32.0
	if not supplied_points.is_empty(): points = supplied_points
	var hazards: Array = []
	if danger:
		# Align the hole exactly with the terrain's 8 m cells and end the road at its lip.
		var lip := floorf(points[-1].z / 8.0) * 8.0
		var shift := lip - points[-1].z
		for i in points.size():
			points[i].z += shift * float(i) / (points.size() - 1)
			points[i].y = height_at(points[i].x, points[i].z) + 0.17
		var center := Vector3(roundf(points[-1].x / 8.0) * 8.0, 0, lip - hole_size.z * 0.5)
		center.x += signf(roundf(points[-1].x - start.x)) * 32.0
		center.y = height_at(center.x, center.z) - hole_size.y
		hazards.append({"kind": "cliff", "position": center, "size": hole_size, "yaw": 0.0})
	else:
		# The first stretch teaches driving; every later road has a readable obstacle rhythm.
		if not challenge_kind.is_empty():
			var center := Vector3(roundf(points[16].x / 8.0) * 8.0, 0, roundf(points[16].z / 8.0) * 8.0)
			center.y = height_at(center.x, center.z) - 18.0
			# Keep the ramp/deck centered on the actual road; the wider grid-aligned
			# terrain cut is separate from its narrow crossing surface.
			hazards.append({"kind": challenge_kind, "position": center, "size": Vector3(64, 18, 16), "yaw": 0.0, "lane_x": points[16].x, "level": difficulty})
		elif depth > 0 or basic_course:
			var kinds := ["rock", "tree", "ramp", "bumps", "construction"]
			# Spike strips start at heat 4.
			if difficulty >= SPIKE_MIN_DIFFICULTY: kinds.append("spikes")
			var count := 2 + difficulty / 2
			if basic_course:
				kinds = ["rock"]
				count = 1
			if profile == "scenic": count = 1 + difficulty / 2
			elif profile == "rough": count = 3 + mini(3, difficulty)
			elif profile == "culdesac": count = 1 if difficulty < 3 else 2
			# Seeded per road (so every game sees the same world), but with no fixed
			# rhythm: random kinds, spacing within even bands, and shoulder sides.
			var span := 22.0 / count
			var plan: Array = []
			var previous := ""
			for slot in count:
				var index := clampi(roundi(rng.randf_range(5.0 + slot * span + 0.8, 5.0 + (slot + 1) * span - 0.8)), 5, 27)
				var choices: Array = kinds.duplicate()
				if choices.size() > 1: choices.erase(previous)
				# Spikes sit at least SPIKE_WARNING metres past the sign at the road's start.
				if _distance_along(points, 1, index) < SPIKE_WARNING: choices.erase("spikes")
				# Each tree bends the road around it; keep chicanes apart.
				for other: Dictionary in plan:
					if other.kind == "tree" and absi(other.index - index) < 8: choices.erase("tree")
				var kind: String = choices[rng.randi() % choices.size()]
				previous = kind
				plan.append({"kind": kind, "index": index})
			for item: Dictionary in plan:
				if item.kind != "spikes": continue
				# Every route onto this road passes its start, so one sign covers all paths.
				var ahead := (points[2] - points[1]).normalized()
				var sign_at := points[1] + ahead.cross(Vector3.UP) * (ROAD_WIDTH * 0.5 + 1.4)
				sign_at.y = height_at(sign_at.x, sign_at.z)
				hazards.append({"kind": "spike_sign", "position": sign_at, "size": Vector3.ONE, "yaw": atan2(-ahead.x, -ahead.z)})
				break
			for item: Dictionary in plan:
				if item.kind != "tree": continue
				var index: int = item.index
				var side := (points[index + 1] - points[index]).normalized().cross(Vector3.UP)
				for j in range(index - 3, index + 4):
					points[j] += side * sin(float(j - index + 3) / 6.0 * PI) * 2.0
					points[j].y = height_at(points[j].x, points[j].z) + 0.17
			for item: Dictionary in plan:
				var index: int = item.index
				var kind: String = item.kind
				var direction := (points[index + 1] - points[index]).normalized()
				var side := direction.cross(Vector3.UP)
				var offset := 0.0 if kind in ["tree", "bumps"] else rng.randf_range(1.4, 2.2) * (-1.0 if rng.randf() < 0.5 else 1.0)
				# A spike strip lies across exactly one half of the road.
				if kind == "spikes":
					offset = (-1.0 if rng.randf() < 0.5 else 1.0) * ROAD_WIDTH * 0.25
				if basic_course:
					offset = -2.0 if rng.randf() < 0.5 else 2.0
				var at := points[index] + side * offset
				at.y = height_at(at.x, at.z) + 0.18
				hazards.append({"kind": kind, "position": at, "size": Vector3.ONE, "yaw": atan2(-direction.x, -direction.z)})
		if not basic_course and profile == "main" and depth > 0 and depth % 6 == 0:
			var center := points[16] + Vector3(28, 0, 0)
			center.x = roundf(center.x / 8.0) * 8.0
			center.z = roundf(center.z / 8.0) * 8.0
			# Keep the whole shoulder clear, even when a curve and grid rounding move toward the lake.
			for point: Vector3 in points:
				if absf(point.z - center.z) < 24.0:
					center.x = maxf(center.x, ceilf((point.x + 24.0) / 8.0) * 8.0)
			center.y = height_at(center.x, center.z) - 14.0
			hazards.append({"kind": "lake", "position": center, "size": Vector3(32, 14, 32), "yaw": 0.0})
	var road := {"id": next_id, "parent": parent_id, "depth": depth, "heading": heading, "points": points, "expanded": profile in ["cliff", "culdesac", "rough"], "danger": danger, "hazards": hazards, "profile": profile, "level": difficulty, "next": -1, "merge_with": -1}
	next_id += 1
	for parent: Dictionary in roads:
		if parent.id == parent_id and parent.next == -1: parent.next = road.id
	_render_road(road)
	roads.append(road)
	graph_revision += 1
	# Newly chosen branches may enter an existing forest tile. Rebuild only those tiles.
	_invalidate_road_tiles(points)
	_invalidate_hazard_tiles(road)
	return road.id

func reset_world() -> void:
	difficulty = 0
	set_challenge_time(0.0)
	jumped_gaps.clear()
	for road: Dictionary in roads:
		road.node.queue_free()
	roads.clear()
	road_cells.clear()
	for tile: Node3D in tiles.values():
		tile.queue_free()
	tiles.clear()
	pending_tiles.clear()
	last_tile = Vector2i(99999, 99999)
	# IDs never repeat in a session, including restarts and reconnects.
	_add_road(Vector3(0, 0, 40 if basic_course else 150), 0.0, 0, next_id, 180.0 if basic_course else 360.0)
	update_stream(Vector3.ZERO, true)

func void_at(at: Vector3) -> Dictionary:
	for road: Dictionary in roads:
		for hazard: Dictionary in road.hazards:
			if Hazards.is_void(hazard) and Hazards.contains(hazard, at):
				return hazard
	return {}

func surface_height(at: Vector3) -> float:
	var hole := void_at(at)
	return float(hole.position.y) if not hole.is_empty() else height_at(at.x, at.z)

func set_challenge_time(value: float) -> void:
	challenge_time = value
	for road: Dictionary in roads:
		for challenge: Node3D in road.node.get_meta("challenges", []):
			challenge.set_clock(value)

func assist_jump(car: RigidBody3D) -> void:
	if car.remote or car.run_state != "driving" or car.global_basis.y.dot(Vector3.UP) < 0.6:
		return
	for road: Dictionary in roads:
		if jumped_gaps.has(road.id): continue
		for hazard: Dictionary in road.hazards:
			if hazard.kind != "jump_gap": continue
			var lip: float = hazard.position.z + hazard.size.z * 0.5
			var lead: float = car.global_position.z - lip
			if lead < 0.5 or lead > 3.0 or absf(car.global_position.x - hazard.lane_x) > 3.0: continue
			if -car.linear_velocity.z < Challenge.JUMP_SPEED or car.global_position.y < height_at(hazard.lane_x, lip) + 1.0: continue
			# A forgiving launch impulse keeps the wide ramp fun with the real
			# suspension; gravity, steering, collisions, and landing remain physical.
			car.linear_velocity.y = maxf(car.linear_velocity.y, 7.0)
			car.angular_velocity *= 0.2
			jumped_gaps[road.id] = true

func _invalidate_hazard_tiles(road: Dictionary) -> void:
	for hazard: Dictionary in road.hazards:
		if not Hazards.is_void(hazard):
			continue
		var p: Vector3 = hazard.position
		var extent: Vector3 = hazard.size * 0.5 + Vector3(9, 0, 9)
		# Large ravines can cover whole tiles between their corners.
		for x in range(floori((p.x - extent.x) / TILE_SIZE), floori((p.x + extent.x) / TILE_SIZE) + 1):
			for z in range(floori((p.z - extent.z) / TILE_SIZE), floori((p.z + extent.z) / TILE_SIZE) + 1):
				var key := Vector2i(x, z)
				if tiles.has(key):
					tiles[key].queue_free()
					tiles.erase(key)
					if not pending_tiles.has(key):
						pending_tiles.append(key)

func _invalidate_road_tiles(points: PackedVector3Array) -> void:
	var dirty: Dictionary = {}
	for point: Vector3 in points:
		for dx in [-24.0, 0.0, 24.0]:
			for dz in [-24.0, 0.0, 24.0]:
				dirty[Vector2i(floori((point.x + dx) / TILE_SIZE), floori((point.z + dz) / TILE_SIZE))] = true
	for key: Vector2i in dirty:
		if tiles.has(key):
			tiles[key].queue_free()
			tiles.erase(key)
			if not pending_tiles.has(key):
				pending_tiles.append(key)

func _render_road(road: Dictionary) -> void:
	_index_road(road)
	var root := Node3D.new()
	root.name = "Road_%d" % road.id
	add_child(root)
	road.node = root
	root.set_meta("hazards", road.hazards)
	var challenges: Array[Node3D] = []
	var points: PackedVector3Array = road.points
	for hazard: Dictionary in road.hazards:
		Hazards.render(root, hazard, tree_mesh)
		if Challenge.is_challenge(hazard):
			var challenge := Challenge.new()
			root.add_child(challenge)
			challenge.setup(hazard)
			challenge.set_clock(challenge_time)
			challenges.append(challenge)
	root.set_meta("challenges", challenges)
	_make_ribbon(root, points, ROAD_WIDTH + 2.2, -0.035, shoulder_material)
	_make_ribbon(root, points, ROAD_WIDTH, 0.0, road_material)
	if road.depth > 0:
		_make_pad(root, points[0], (ROAD_WIDTH + 2.2) * 0.5, -0.035, shoulder_material)
		_make_pad(root, points[0], ROAD_WIDTH * 0.5, 0.0, road_material)
	if road.profile == "culdesac":
		_render_culdesac(root, points[-1])
	for i in range(1, points.size() - 1, 3):
		var a := points[i]
		var b := points[i + 1]
		var over_gap := false
		for hazard: Dictionary in road.hazards:
			if Challenge.is_challenge(hazard) and Hazards.contains(hazard, (a + b) * 0.5, 6.0): over_gap = true
		if over_gap: continue
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
		label.text = "+" if road.depth > 0 else "Y"
		label.font_size = 100
		label.pixel_size = 0.012
		label.modulate = Color("303c35")
		label.position = post + Vector3(0.0, 2.7, 0.09)
		root.add_child(label)

func _render_culdesac(parent: Node3D, center: Vector3) -> void:
	for radius: float in [CULDESAC_RADIUS + 1.5, CULDESAC_RADIUS]:
		var lift := 0.135 if radius > CULDESAC_RADIUS else 0.17
		var vertices := PackedVector3Array()
		for i in 40:
			var a := center + Vector3(cos(i * TAU / 40), 0, sin(i * TAU / 40)) * radius
			var b := center + Vector3(cos((i + 1) * TAU / 40), 0, sin((i + 1) * TAU / 40)) * radius
			vertices.append_array(PackedVector3Array([ground_point(center.x, center.z, lift), ground_point(b.x, b.z, lift), ground_point(a.x, a.z, lift)]))
		Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, road_material if radius == CULDESAC_RADIUS else shoulder_material).create_trimesh_collision()
	var at := ground_point(center.x + 7, center.z + 8)
	Geo.cylinder(parent, 0.12, 2.6, at + Vector3.UP * 1.3, trunk_material)
	Geo.box(parent, Vector3(3.4, 1.1, 0.15), at + Vector3.UP * 2.5, road_material)
	var sign := Label3D.new()
	sign.text = "NO THROUGH ROAD\nTURN AROUND"
	sign.font_size = 52
	sign.pixel_size = 0.006
	sign.position = at + Vector3(0, 2.5, 0.09)
	parent.add_child(sign)

func _make_ribbon(parent: Node3D, points: PackedVector3Array, width: float, lift: float, mat: Material) -> void:
	var hazards: Array = parent.get_meta("hazards", [])
	# One shared left/right edge per centerline point, mitred between the segments
	# on either side, so bends stay one continuous surface with no wedge gaps.
	var lefts := PackedVector3Array()
	var rights := PackedVector3Array()
	for i in points.size():
		var before := points[maxi(0, i - 1)]
		var after := points[mini(points.size() - 1, i + 1)]
		var tangent := Vector3(after.x - before.x, 0, after.z - before.z).normalized()
		var segment := Vector3(points[mini(points.size() - 1, i + 1)].x - points[i].x, 0, points[mini(points.size() - 1, i + 1)].z - points[i].z)
		if i == points.size() - 1: segment = Vector3(points[i].x - before.x, 0, points[i].z - before.z)
		var side := tangent.cross(Vector3.UP)
		var miter := clampf(side.dot(segment.normalized().cross(Vector3.UP)), 0.6, 1.0)
		# Widen smoothly around a tree, leaving a rough shoulder escape on both sides.
		var local_width := width
		for hazard: Dictionary in hazards:
			if hazard.kind == "tree":
				local_width += 2.5 * (1.0 - smoothstep(10.0, 18.0, points[i].distance_to(hazard.position)))
		side *= local_width * 0.5 / miter
		lefts.append(ground_point(points[i].x - side.x, points[i].z - side.z, 0.17 + lift))
		rights.append(ground_point(points[i].x + side.x, points[i].z + side.z, 0.17 + lift))
	var vertices := PackedVector3Array()
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var over_gap := false
		for hazard: Dictionary in hazards:
			if Challenge.is_challenge(hazard) and minf(a.z, b.z) < hazard.position.z + hazard.size.z * 0.5 and maxf(a.z, b.z) > hazard.position.z - hazard.size.z * 0.5:
				over_gap = true
		if over_gap: continue
		# Long chords can dip through the rolling terrain even when both endpoints
		# are above it. Resample the surface without changing map/route geometry.
		var steps := maxi(1, ceili(a.distance_to(b) / ROAD_MESH_STEP))
		var al := lefts[i]
		var ar := rights[i]
		for step in range(1, steps + 1):
			var t := float(step) / steps
			var bl := lefts[i + 1] if step == steps else lefts[i].lerp(lefts[i + 1], t)
			var br := rights[i + 1] if step == steps else rights[i].lerp(rights[i + 1], t)
			bl.y = height_at(bl.x, bl.z) + 0.17 + lift
			br.y = height_at(br.x, br.z) + 0.17 + lift
			vertices.append_array(PackedVector3Array([al, ar, bl, ar, br, bl]))
			al = bl
			ar = br
	var ribbon := Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, mat)
	ribbon.create_trimesh_collision()

## A round pad where a road leaves a junction fills the corner between roads
## that meet at an angle.
func _make_pad(parent: Node3D, center: Vector3, radius: float, lift: float, mat: Material) -> void:
	var vertices := PackedVector3Array()
	var middle := ground_point(center.x, center.z, 0.17 + lift)
	for i in 24:
		var a := center + Vector3(cos(i * TAU / 24), 0, sin(i * TAU / 24)) * radius
		var b := center + Vector3(cos((i + 1) * TAU / 24), 0, sin((i + 1) * TAU / 24)) * radius
		vertices.append_array(PackedVector3Array([middle, ground_point(b.x, b.z, 0.17 + lift), ground_point(a.x, a.z, 0.17 + lift)]))
	var pad := Geo.instance(parent, Geo.mesh_from_triangles(vertices), Vector3.ZERO, mat)
	pad.create_trimesh_collision()

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

func recovery_spot(at: Vector3) -> Dictionary:
	var best := {"distance": INF, "point": ground_point(0, 12, 0.17), "direction": Vector3.FORWARD}
	for road: Dictionary in roads:
		var points: PackedVector3Array = road.points
		for i in range(1, points.size() - 3):
			var point := points[i]
			var clear := true
			for hazard: Dictionary in road.hazards:
				if Hazards.is_void(hazard):
					clear = clear and not Hazards.contains(hazard, point, 10.0)
				else:
					clear = clear and point.distance_to(hazard.position) > 12.0
			var distance := at.distance_to(point)
			if clear and distance < best.distance:
				best = {"distance": distance, "point": point, "direction": (points[i + 1] - point).normalized()}
	return best

func thorn_at(at: Vector3) -> bool:
	# The same global grid defines the visible thicket and tire contact on both peers.
	var center := Vector3((floorf(at.x / THORN_CELL) + 0.5) * THORN_CELL, 0, (floorf(at.z / THORN_CELL) + 0.5) * THORN_CELL)
	return road_distance(center) >= THORN_DISTANCE and void_at(center).is_empty() and void_at(at).is_empty()

func puncture_mask(car: RigidBody3D) -> int:
	if car.grounded_wheels == 0 or car.global_basis.y.dot(Vector3.UP) < 0.4:
		return 0
	var result := 0
	for i in car.wheel_pivots.size():
		var contact: Vector3 = car.wheel_pivots[i].global_position - car.global_basis.y * car.WHEEL_RADIUS
		if absf(contact.y - height_at(contact.x, contact.z)) < 0.8 and thorn_at(contact):
			result |= 1 << i
	return result

static func _distance_along(points: PackedVector3Array, from: int, to: int) -> float:
	var total := 0.0
	for i in range(from, to):
		total += points[i].distance_to(points[i + 1])
	return total

## Wheels currently rolling over a spike strip, as a bitmask.
func spike_mask(car: RigidBody3D) -> int:
	if car.grounded_wheels == 0:
		return 0
	var result := 0
	for road: Dictionary in roads:
		for hazard: Dictionary in road.hazards:
			if hazard.kind != "spikes" or hazard.position.distance_squared_to(car.global_position) > 100.0:
				continue
			var basis := Basis(Vector3.UP, float(hazard.yaw))
			for i in car.wheel_pivots.size():
				var contact: Vector3 = car.wheel_pivots[i].global_position - car.global_basis.y * car.WHEEL_RADIUS
				var local: Vector3 = basis.inverse() * (contact - hazard.position)
				if absf(local.x) < SPIKE_HALF_WIDTH and absf(local.z) < SPIKE_HALF_DEPTH + 0.15 and absf(local.y) < 0.8:
					result |= 1 << i
	return result

func road_distance(at: Vector3) -> float:
	# Decoration and tire queries only need nearby roads. Avoid scanning the entire
	# retained graph for every single tree as the run gets longer.
	var key := Vector2i(floori(at.x / ROAD_CELL_SIZE), floori(at.z / ROAD_CELL_SIZE))
	var point := Vector2(at.x, at.z)
	var closest := INF
	for road: Dictionary in roads:
		if road.profile == "culdesac":
			var end: Vector3 = road.points[-1]
			closest = minf(closest, maxf(0, point.distance_to(Vector2(end.x, end.z)) - CULDESAC_RADIUS + ROAD_WIDTH * 0.5))
	for x in range(-1, 2):
		for z in range(-1, 2):
			for segment: Array in road_cells.get(key + Vector2i(x, z), []):
				var a: Vector2 = segment[0]
				var b: Vector2 = segment[1]
				var t := clampf((point - a).dot(b - a) / (b - a).length_squared(), 0.0, 1.0)
				closest = minf(closest, point.distance_to(a.lerp(b, t)))
	return closest

func _index_road(road: Dictionary) -> void:
	var points: PackedVector3Array = road.points
	for i in range(points.size() - 1):
		var a := Vector2(points[i].x, points[i].z)
		var b := Vector2(points[i + 1].x, points[i + 1].z)
		var key := Vector2i(floori(a.x / ROAD_CELL_SIZE), floori(a.y / ROAD_CELL_SIZE))
		if not road_cells.has(key):
			road_cells[key] = []
		road_cells[key].append([a, b])

func _rebuild_road_index() -> void:
	road_cells.clear()
	for road: Dictionary in roads:
		_index_road(road)

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
			var center := Vector3(origin.x + (x + 0.5) * step_size, 0, origin.y + (z + 0.5) * step_size)
			if not void_at(center).is_empty():
				continue
			var a := ground_point(origin.x + x * step_size, origin.y + z * step_size)
			var b := ground_point(a.x + step_size, a.z)
			var c := ground_point(a.x, a.z + step_size)
			var d := ground_point(a.x + step_size, a.z + step_size)
			vertices.append_array(PackedVector3Array([a, c, b, b, c, d]))
			var color := Color("435c42").lerp(Color("71845c"), rng.randf() * 0.65)
			for _j in 6:
				colors.append(color)
	# A broad ravine can consume an entire tile; its floor/walls already provide collision.
	if not vertices.is_empty():
		var terrain := Geo.instance(root, Geo.mesh_from_triangles(vertices, colors), Vector3.ZERO, terrain_material)
		terrain.create_trimesh_collision()
	var trees: Array[Transform3D] = []
	var trunks: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	for _i in 60:
		var p := ground_point(origin.x + rng.randf() * TILE_SIZE, origin.y + rng.randf() * TILE_SIZE)
		if not void_at(p).is_empty() or road_distance(p) < 8.5 or p.distance_to(Vector3.ZERO) < 12.0:
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
		if not void_at(p).is_empty() or road_distance(p) < 7.0:
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
	var thorns: Array[Transform3D] = []
	for x in int(TILE_SIZE / THORN_CELL):
		for z in int(TILE_SIZE / THORN_CELL):
			var p := ground_point(origin.x + (x + 0.5) * THORN_CELL, origin.y + (z + 0.5) * THORN_CELL)
			if not thorn_at(p):
				continue
			var rotation := fposmod(p.x * 7.13 + p.z * 3.71, TAU)
			thorns.append(Transform3D(Basis(Vector3.UP, rotation), p))
	_multimesh(root, thorn_mesh, leaf_material, thorns)
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
	thorn_mesh = Hazards.make_thorn_mesh()

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
		result.append({"id": road.id, "parent": road.parent, "depth": road.depth, "heading": road.heading, "points": road.points, "expanded": road.expanded, "danger": road.danger, "hazards": road.hazards.duplicate(true), "profile": road.profile, "level": road.level, "next": road.next, "merge_with": road.merge_with})
	return result

func import_graph(data: Array) -> void:
	var existing: Dictionary = {}
	for road: Dictionary in roads:
		existing[road.id] = road
	var updated: Array[Dictionary] = []
	for record: Dictionary in data:
		var previous: Dictionary = existing.get(record.id, {})
		existing.erase(record.id)
		if not previous.is_empty() and previous.points == record.points and previous.profile == record.profile and previous.level == record.level and previous.hazards == record.hazards:
			previous.expanded = record.expanded
			previous.next = record.next
			previous.merge_with = record.merge_with
			updated.append(previous)
		else:
			if not previous.is_empty():
				_invalidate_road_tiles(previous.points)
				_invalidate_hazard_tiles(previous)
				previous.node.queue_free()
			_render_road(record)
			updated.append(record)
			_invalidate_road_tiles(record.points)
			_invalidate_hazard_tiles(record)
		next_id = maxi(next_id, int(record.id) + 1)
	for road: Dictionary in existing.values():
		_invalidate_road_tiles(road.points)
		_invalidate_hazard_tiles(road)
		road.node.queue_free()
	roads = updated
	_rebuild_road_index()
	graph_revision += 1
	update_stream(focus)
