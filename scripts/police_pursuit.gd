extends Node3D
## Driver-owned route pursuit. Peers interpolate its pose and share the same catch clock.
const Geo = preload("res://scripts/geometry.gd")
const Challenge = preload("res://scripts/road_challenge.gd")
const HEAD_START := 6.0
const START_GAP := 85.0
const BOOST_FULL_GAP := 240.0
## About 61 km/h, just under a car on two flat tires (~62 km/h): driving cleanly
## with one or two flats still pulls away, while a bad crash or a dead end does not.
const CATCH_UP_SPEED := 17.0
const BRAKING := 9.0
const CATCH_SECONDS := 2.0
const CAPTURE_RADIUS := 24.0
const CAPTURE_ROUTE_REACH := 14.0
const CAPTURE_HEIGHT_REACH := 4.0
var world: Node3D
var car: RigidBody3D
var phase := "waiting"
var elapsed := 0.0
var speed := 0.0
var gap := START_GAP
var closing_speed := 0.0
var catch_time := 0.0
var paused := true
var road_id := -1
var station := 0.0
var lateral := 0.0
var cache: Dictionary = {}
var revision := -1
var last_gap := START_GAP
var wheels: Array[Node3D] = []
var lamps: Array[MeshInstance3D] = []
var beacons: Array[OmniLight3D] = []
var wheel_spin := 0.0
var junctions: Dictionary = {}
var goal_routes: Dictionary = {}
var goal_road := -1
var goal_station := -1.0

func _ready() -> void:
	_build_model()

func reset() -> void:
	phase = "waiting"
	elapsed = 0.0
	speed = 0.0
	gap = START_GAP
	last_gap = gap
	closing_speed = 0.0
	catch_time = 0.0
	lateral = 0.0
	paused = true
	cache.clear()
	revision = -1
	_sync_roads()
	road_id = int(world.roads[0].id)
	station = maxf(0.0, _project(Vector3(0, 0, 12), road_id).station - START_GAP)
	_place(1, 1.0)
	visible = true

func _sync_roads() -> void:
	if revision == world.graph_revision:
		return
	var updated := {}
	for road: Dictionary in world.roads:
		var lengths := PackedFloat32Array([0.0])
		for i in range(1, road.points.size()):
			lengths.append(lengths[-1] + Vector2(road.points[i].x - road.points[i - 1].x, road.points[i].z - road.points[i - 1].z).length())
		updated[road.id] = {"points": road.points, "hazards": road.hazards, "lengths": lengths, "length": float(lengths[-1])}
	cache = updated
	junctions.clear()
	for id: int in cache:
		var record: Dictionary = cache[id]
		record.start = _junction(record.points[0])
		record.end = _junction(record.points[-1])
		for direction in [1, -1]:
			var a: Vector2i = record.start if direction > 0 else record.end
			var b: Vector2i = record.end if direction > 0 else record.start
			if not junctions.has(a): junctions[a] = []
			junctions[a].append({"to": b, "road": id, "direction": direction, "length": record.length})
	goal_road = -1
	revision = world.graph_revision

func _junction(at: Vector3) -> Vector2i:
	return Vector2i(roundi(at.x * 100), roundi(at.z * 100))

func _project(at: Vector3, id: int) -> Dictionary:
	var record: Dictionary = cache[id]
	var result := {"station": 0.0, "distance": INF}
	var flat := Vector2(at.x, at.z)
	for i in range(record.points.size() - 1):
		var a := Vector2(record.points[i].x, record.points[i].z)
		var b := Vector2(record.points[i + 1].x, record.points[i + 1].z)
		var t := clampf((flat - a).dot(b - a) / (b - a).length_squared(), 0, 1)
		var distance := flat.distance_to(a.lerp(b, t))
		if distance < result.distance:
			result = {"station": lerpf(record.lengths[i], record.lengths[i + 1], t), "distance": distance}
	return result

func _sample(id: int, at: float) -> Dictionary:
	var record: Dictionary = cache[id]
	at = clampf(at, 0, record.length)
	for i in range(record.points.size() - 1):
		if at <= record.lengths[i + 1]:
			var t: float = (at - record.lengths[i]) / (record.lengths[i + 1] - record.lengths[i])
			return {"point": record.points[i].lerp(record.points[i + 1], t), "direction": (record.points[i + 1] - record.points[i]).normalized()}
	return {"point": record.points[-1], "direction": (record.points[-1] - record.points[-2]).normalized()}

func _routes_to(target_id: int, target_station: float) -> void:
	if goal_road == target_id and goal_station == target_station: return
	goal_road = target_id
	goal_station = target_station
	goal_routes.clear()
	var target: Dictionary = cache[target_id]
	goal_routes[target.start] = {"cost": target_station, "road": target_id, "direction": 1}
	goal_routes[target.end] = {"cost": target.length - target_station, "road": target_id, "direction": -1}
	var pending := {target.start: target_station, target.end: target.length - target_station}
	var visited := {}
	# Actual junction connectivity supports rejoining shortcuts and turnarounds.
	# Costs are road lengths, so close parallel roads never become a forest shortcut.
	while not pending.is_empty():
		var node: Vector2i = pending.keys()[0]
		for candidate: Vector2i in pending:
			if pending[candidate] < pending[node]: node = candidate
		var cost: float = pending[node]
		pending.erase(node)
		visited[node] = true
		for edge: Dictionary in junctions.get(node, []):
			if visited.has(edge.to): continue
			var distance: float = cost + edge.length
			if not goal_routes.has(edge.to) or distance < goal_routes[edge.to].cost:
				goal_routes[edge.to] = {"cost": distance, "road": edge.road, "direction": -edge.direction}
				pending[edge.to] = distance

func _route_to(target_id: int, target_station: float) -> Dictionary:
	if road_id == target_id:
		return {"distance": absf(target_station - station), "direction": 1 if target_station >= station else -1, "next": -1, "next_direction": 1}
	_routes_to(target_id, target_station)
	var record: Dictionary = cache[road_id]
	var backward: float = station + goal_routes.get(record.start, {}).get("cost", INF)
	var forward: float = record.length - station + goal_routes.get(record.end, {}).get("cost", INF)
	if is_inf(minf(backward, forward)):
		return {"distance": maxf(BOOST_FULL_GAP, global_position.distance_to(car.global_position)), "direction": -1, "next": -1, "next_direction": 1}
	var direction := 1 if forward <= backward else -1
	var next: Dictionary = goal_routes[record.end if direction > 0 else record.start]
	return {"distance": minf(backward, forward), "direction": direction, "next": next.road, "next_direction": next.direction}

func _route_gap(target_id: int, target_station: float) -> float:
	return _route_to(target_id, target_station).distance

func advance(delta: float, running: bool) -> void:
	paused = not running
	if not running or phase in ["caught", "escaped"]:
		closing_speed = 0.0
		return
	_sync_roads()
	if not cache.has(road_id):
		# The driver has left even the retained road graph behind: no teleporting patrol.
		phase = "escaped"
		visible = false
		return
	var nearest: Dictionary = world.nearest_road(car.global_position)
	var target_id := int(nearest.road_id)
	if not cache.has(target_id):
		return
	var target := _project(car.global_position, target_id)
	var route := _route_to(target_id, target.station)
	elapsed += delta
	gap = route.distance + float(target.distance)
	if phase == "waiting":
		last_gap = gap
		if elapsed < HEAD_START:
			return
		phase = "chasing"
	var direction: int = route.direction
	var cruise := 14.0 + clampf(car.distance_driven / 2000.0, 0, 1) * 2.5
	# Earned space gives breathing room, then the patrol gradually reels it back in.
	# Fade the boost out before capture range; never jump the patrol toward the car.
	var boost := smoothstep(START_GAP, BOOST_FULL_GAP, gap)
	var pace := lerpf(1.0, 1.3, boost)
	var guidance := _guidance(direction, pace)
	cruise = lerpf(cruise, CATCH_UP_SPEED, boost)
	var desired_speed: float = minf(cruise, guidance.speed_limit)
	speed = move_toward(speed, desired_speed, delta * (lerpf(3.2, 6.0, boost) if desired_speed > speed else BRAKING * pace * pace))
	lateral = move_toward(lateral, guidance.lateral, delta * 2.0 * pace)
	var step := minf(speed * delta, maxf(0, route.distance - 6.0))
	step = minf(step, guidance.stop_distance)
	speed = minf(speed, step / maxf(delta, 0.001))
	station += step * direction
	if station > cache[road_id].length or station < 0:
		var carry: float = station - cache[road_id].length if direction > 0 else -station
		if cache.has(route.next) and route.next != road_id:
			road_id = route.next
			direction = route.next_direction
			station = carry if direction > 0 else cache[road_id].length - carry
		else:
			station = clampf(station, 0, cache[road_id].length)
	_place(direction, 1.0 - exp(-delta * 9.0))
	gap = _route_gap(target_id, target.station) + float(target.distance)
	var change := last_gap - gap
	var measured := clampf(change / maxf(delta, 0.001), -60, 60) if absf(change) < 8.0 else 0.0
	closing_speed = lerpf(closing_speed, measured, 1.0 - exp(-delta * 2.0))
	last_gap = gap
	# Police control the shoulder alongside them as well as the asphalt. Check
	# progress along the road separately from lateral offset, so parking beside
	# the road is not a safe spot. Route and height checks protect other branches
	# and cars falling into a ravine from capture through the terrain.
	var separation := car.global_position - global_position
	var nearby := Vector2(separation.x, separation.z).length() < CAPTURE_RADIUS and absf(separation.y) < CAPTURE_HEIGHT_REACH and _route_gap(target_id, target.station) < CAPTURE_ROUTE_REACH
	catch_time = catch_time + delta if nearby else maxf(0, catch_time - delta * 3.0)
	if catch_time >= CATCH_SECONDS:
		phase = "caught"
		car.finish_run("The police caught you")

func _guidance(direction: int, pace: float = 1.0) -> Dictionary:
	var sample := _sample(road_id, station)
	var forward: Vector3 = sample.direction * direction
	var side: Vector3 = sample.direction.cross(Vector3.UP).normalized()
	var desired := 0.0
	var speed_limit := CATCH_UP_SPEED
	var strongest := 0.0
	var stop_distance := INF
	# Scale braking and dodging with pursuit pace, so bends and obstacles still
	# slow it down without erasing the catch-up boost throughout a busy route.
	var braking := BRAKING * pace * pace
	var bump_speed := 13.0 * pace
	var obstacle_speed := 18.0 * pace
	var turn_speed := 20.0 * pace
	var junction_speed := 19.0 * pace
	var braking_lookahead := maxf(35.0, (speed * speed - bump_speed * bump_speed) / (2.0 * braking) + 16.0)
	# Inspect the next road too, so a turn or an obstacle just beyond a junction is anticipated.
	for record: Dictionary in cache.values():
		for hazard: Dictionary in record.hazards:
			if Challenge.is_challenge(hazard):
				var crossing := Vector3(hazard.lane_x, sample.point.y, hazard.position.z)
				var edge: float = (crossing - sample.point).dot(forward) - hazard.size.z * 0.5
				if hazard.kind == "timed_bridge" and edge > 0 and edge < braking_lookahead + 25 and absf((crossing - sample.point).dot(side)) < 7:
					var state := Challenge.bridge_state(hazard, world.challenge_time)
					var time_to_clear: float = (edge + hazard.size.z + 5) / maxf(speed, 22.0)
					if not state.open or state.remaining < time_to_clear:
						speed_limit = minf(speed_limit, sqrt(2.0 * braking * maxf(0, edge - 7.0)))
						stop_distance = minf(stop_distance, maxf(0, edge - 7.0))
				continue
			if hazard.kind in ["cliff", "lake"]: continue
			var relative: Vector3 = hazard.position - sample.point
			var ahead := relative.dot(forward)
			if ahead < -9 or ahead > braking_lookahead or absf(relative.dot(side)) > 7: continue
			var strength := clampf((35.0 - ahead) / 22.0, 0, 1) * clampf((ahead + 9.0) / 7.0, 0, 1)
			# At catch-up pace, begin braking earlier while retaining the same dodge.
			if ahead > 0:
				var crossing_speed := bump_speed if hazard.kind == "bumps" else obstacle_speed
				speed_limit = minf(speed_limit, sqrt(crossing_speed * crossing_speed + 2.0 * braking * maxf(0, ahead - 16.0)))
			if hazard.kind == "bumps":
				speed_limit = minf(speed_limit, lerpf(CATCH_UP_SPEED, bump_speed, strength))
			else:
				speed_limit = minf(speed_limit, lerpf(CATCH_UP_SPEED, obstacle_speed, strength))
				if strength > strongest:
					strongest = strength
					desired = (-2.6 if relative.dot(side) >= 0 else 2.6) * strength
	var turn_lookahead := maxf(18.0, (speed * speed - turn_speed * turn_speed) / (2.0 * braking) + 18.0)
	for distance in range(18, ceili(turn_lookahead) + 1, 9):
		var look := _sample(road_id, station + distance * direction)
		if sample.direction.dot(look.direction) < 0.985:
			speed_limit = minf(speed_limit, sqrt(turn_speed * turn_speed + 2.0 * braking * maxf(0, distance - 18.0)))
	var junction_distance: float = cache[road_id].length - station if direction > 0 else station
	speed_limit = minf(speed_limit, sqrt(junction_speed * junction_speed + 2.0 * braking * maxf(0, junction_distance - 16.0)))
	if cache[road_id].length - station < 16 or station < 12:
		speed_limit = minf(speed_limit, junction_speed)
	return {"lateral": desired, "speed_limit": speed_limit, "stop_distance": stop_distance}

func _place(direction: int, weight: float) -> void:
	var sample := _sample(road_id, station)
	var side: Vector3 = sample.direction.cross(Vector3.UP).normalized()
	var point: Vector3 = sample.point + side * lateral
	point.y = world.height_at(point.x, point.z) + 0.78
	for hazard: Dictionary in cache[road_id].hazards:
		if hazard.kind == "jump_gap": point.y += Challenge.jump_height(hazard, point)
	global_position = point
	global_basis = global_basis.orthonormalized().slerp(Basis.looking_at(sample.direction * direction), weight)

func eta() -> float:
	return maxf(0, gap - 11.0) / closing_speed if phase == "chasing" and not paused and closing_speed > 0.75 else -1.0

func siren_gain() -> float:
	if paused or phase not in ["waiting", "chasing"]: return 0.0
	return pow(clampf(1.0 - global_position.distance_to(car.global_position) / 300.0, 0, 1), 2.0)

func snapshot() -> Dictionary:
	var q := global_basis.orthonormalized().get_rotation_quaternion()
	return {"position": [global_position.x, global_position.y, global_position.z], "rotation": [q.x, q.y, q.z, q.w], "phase": phase, "elapsed": elapsed, "speed": speed, "gap": gap, "closing": closing_speed, "catch": clampf(catch_time / CATCH_SECONDS, 0, 1), "paused": paused}

func apply_snapshot(a: Dictionary, b: Dictionary, weight: float) -> void:
	var first := Transform3D(Basis(Quaternion(a.rotation[0], a.rotation[1], a.rotation[2], a.rotation[3])), Vector3(a.position[0], a.position[1], a.position[2]))
	var second := Transform3D(Basis(Quaternion(b.rotation[0], b.rotation[1], b.rotation[2], b.rotation[3])), Vector3(b.position[0], b.position[1], b.position[2]))
	global_transform = first.interpolate_with(second, weight)
	phase = b.phase
	elapsed = lerpf(a.elapsed, b.elapsed, weight)
	speed = lerpf(a.speed, b.speed, weight)
	gap = lerpf(a.gap, b.gap, weight)
	closing_speed = b.closing
	catch_time = b.catch * CATCH_SECONDS
	paused = b.paused
	visible = phase != "escaped"

func _process(delta: float) -> void:
	wheel_spin += speed * delta / 0.36 if not paused and phase == "chasing" else 0.0
	for wheel in wheels: wheel.rotation.x = -wheel_spin
	for i in lamps.size():
		var lit := phase != "escaped" and (fmod(elapsed, 0.8) < 0.4) == (i == 0)
		lamps[i].material_override.emission_energy_multiplier = 2.0 if lit else 0.05
		beacons[i].light_energy = 1.5 if lit else 0.0

func _build_model() -> void:
	var white := Geo.material(Color("e5e7da"))
	var black := Geo.material(Color("17242a"))
	var glass := Geo.material(Color("547982"), 0.25)
	var trim := Geo.material(Color("a9b5ac"))
	Geo.box(self, Vector3(1.95, 0.58, 4.15), Vector3.ZERO, white)
	Geo.box(self, Vector3(1.91, 0.24, 1.2), Vector3(0, 0.37, -1.42), black)
	Geo.box(self, Vector3(1.88, 0.2, 0.85), Vector3(0, 0.34, 1.58), black)
	Geo.box(self, Vector3(1.66, 0.84, 2.2), Vector3(0, 0.86, 0.18), glass)
	Geo.box(self, Vector3(1.77, 0.14, 2.28), Vector3(0, 1.33, 0.18), black)
	for x in [-1.0, 1.0]:
		Geo.box(self, Vector3(0.04, 0.3, 1.65), Vector3(x, 0.16, 0.1), black)
		var badge := Geo.sphere(self, 0.16, Vector3(x * 1.025, 0.16, 0.1), Geo.material(Color("d4be74")))
		badge.scale.x = 0.12
		for z in [-1.3, 1.3]:
			var pivot := Node3D.new()
			pivot.position = Vector3(x * 0.93, -0.35, z)
			add_child(pivot)
			wheels.append(pivot)
			Geo.cylinder(pivot, 0.36, 0.25, Vector3.ZERO, black, -1, 12).rotation.z = PI / 2
			Geo.cylinder(pivot, 0.18, 0.26, Vector3.ZERO, trim).rotation.z = PI / 2
	for z in [-2.12, 2.12]:
		Geo.box(self, Vector3(1.9, 0.17, 0.13), Vector3(0, -0.15, z), trim)
	for x in [-0.68, 0.68]:
		Geo.box(self, Vector3(0.4, 0.2, 0.06), Vector3(x, 0.13, -2.1), Geo.material(Color("fff3c4")))
	Geo.box(self, Vector3(1.35, 0.1, 0.4), Vector3(0, 1.46, 0.1), trim)
	for i in 2:
		var mat := Geo.material(Color("e34b43") if i == 0 else Color("4e88df"))
		mat.emission_enabled = true
		mat.emission = mat.albedo_color
		lamps.append(Geo.box(self, Vector3(0.53, 0.19, 0.32), Vector3(-0.35 if i == 0 else 0.35, 1.59, 0.1), mat))
		var light := OmniLight3D.new()
		light.position = Vector3(-0.35 if i == 0 else 0.35, 1.75, 0.1)
		light.light_color = mat.albedo_color
		light.omni_range = 8
		add_child(light)
		beacons.append(light)
