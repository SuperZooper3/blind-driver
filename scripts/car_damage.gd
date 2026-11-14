extends RefCounted
## Health for the car's few big, breakable parts, and what each loss costs.
## A damaged part only looks and sounds worse; the car drives normally until a
## part actually breaks. Breaking never ends the run by itself: a wrecked car
## just limps along until the police catch it. The driver's game is
## authoritative; navigators mirror `health` from snapshots.

enum { WHEEL_FL, WHEEL_FR, WHEEL_RL, WHEEL_RR, ENGINE, FRONT_BUMPER, REAR_BUMPER, WINDSHIELD }
const PART_COUNT := 8
const NAMES := ["FL TIRE", "FR TIRE", "RL TIRE", "RR TIRE", "ENGINE", "FRONT BUMPER", "REAR BUMPER", "WINDSHIELD"]
## Closing speed (m/s) below which a hit does no harm: 3.5 m/s is about 13 km/h.
const SAFE_SPEED := 3.5
## Hit severity grows faster than speed, like crash energy: (speed - SAFE_SPEED) ^ CURVE.
const CURVE := 1.3
## Health lost per unit of severity. Severity is about 8 at 30 km/h, 21 at 50 km/h,
## 45 at 80 km/h, 73 at 110 km/h and 122 at the 158 km/h top speed. The car is
## fragile: a 30 km/h hit dents the bumper, a 50 km/h hit tears it off, an
## 80 km/h corner hit knocks that wheel off, and one head-on hit at top speed
## wrecks the engine.
const RATE := [0.055, 0.055, 0.055, 0.055, 0.03, 0.05, 0.05, 0.025]
## Frontal hits only reach the windshield above this closing speed (about 32 km/h).
const WINDSHIELD_SPEED := 9.0
## How much of a hit gets past a bumper that is still on.
const BUMPER_SPILL := 0.3
## Penalties for broken parts. Each broken tire costs this share of power and top speed.
const TIRE_POWER_LOSS := 0.15
const TIRE_SPEED_LOSS := 0.12
## A broken engine still runs, badly.
const ENGINE_BROKEN_POWER := 0.45
const ENGINE_BROKEN_SPEED := 0.55
const DEBRIS_LIFETIME := 20.0
## Repairs fix one part at a time, most crucial first: the engine, then the tires
## (worst first), then the glass, the headlight bumper and the rear bumper.
const REPAIR_ORDER := [ENGINE, WHEEL_FL, WHEEL_FR, WHEEL_RL, WHEEL_RR, WINDSHIELD, FRONT_BUMPER, REAR_BUMPER]
## Health restored per second: a fully broken part takes 5 seconds.
const REPAIR_RATE := 0.2

signal part_broken(part: int)
## Health lost by any part this frame, summed: drives the crash sound on both seats.
signal damaged(amount: float)

var car: RigidBody3D
var health := PackedFloat32Array()
## Each part's breakable visuals. A wheel's entry is its spinning wheel node.
var visuals: Array = []
var rest_transforms: Array = []
## Which side the last dent came from, -1 (left) .. 1 (right), for lopsided crumpling.
var dent_side := PackedFloat32Array()

func _init(owner_car: RigidBody3D) -> void:
	car = owner_car
	health.resize(PART_COUNT)
	health.fill(1.0)
	dent_side.resize(PART_COUNT)
	for i in PART_COUNT:
		visuals.append([])
		rest_transforms.append([])

func register(part: int, node: Node3D) -> void:
	visuals[part].append(node)
	rest_transforms[part].append(node.transform)

func alive(part: int) -> bool:
	return health[part] > 0.0

## Lateral grip multiplier: a flat tire slides.
func wheel_grip(wheel: int) -> float:
	return 1.0 if alive(wheel) else 0.45

## A flat tire drags and pulls toward its side, in radians. Left pulls left, right pulls right.
func wheel_toe(wheel: int) -> float:
	if alive(wheel):
		return 0.0
	return (1.0 if wheel % 2 == 0 else -1.0) * 0.06

## Drive force multiplier from broken parts.
func power_scale() -> float:
	var scale := 1.0 - TIRE_POWER_LOSS * broken_tires()
	return scale * (1.0 if alive(ENGINE) else ENGINE_BROKEN_POWER)

## Top speed multiplier from broken parts.
func speed_scale() -> float:
	var scale := 1.0 - TIRE_SPEED_LOSS * broken_tires()
	return scale * (1.0 if alive(ENGINE) else ENGINE_BROKEN_SPEED)

func broken_tires() -> int:
	var count := 0
	for wheel in 4:
		if not alive(wheel):
			count += 1
	return count

## Engine knock grows with damage; power only drops once the engine breaks.
func engine_roughness() -> float:
	return 1.0 if not alive(ENGINE) else (1.0 - health[ENGINE]) * 0.45

## Thorns tear the tire itself. It goes flat at zero but stays on the car.
func wear_tire(wheel: int, amount: float) -> void:
	if not alive(wheel) or amount <= 0.0:
		return
	var value := maxf(0.0, health[wheel] - amount)
	if value <= 0.0 and car.has_method("flatten_tire"):
		car.flatten_tire(wheel)
	set_part(wheel, value)

func steer_scale() -> float:
	var scale := 1.0
	for wheel in [WHEEL_FL, WHEEL_FR]:
		if not alive(wheel):
			scale *= 0.5
	return scale

func headlights_ok() -> bool:
	return alive(FRONT_BUMPER)

## 0 = clear glass, 1 = shattered.
func windshield_crack() -> float:
	return 1.0 - health[WINDSHIELD]

## A contact at `local_point` (car space, forward is -Z) closing at `closing_speed` m/s.
func apply_impact(local_point: Vector3, closing_speed: float) -> void:
	var excess := closing_speed - SAFE_SPEED
	if excess <= 0.0:
		return
	var severity := pow(excess, CURVE)
	var left := local_point.x < 0.0
	var side := clampf(local_point.x / 0.9, -1.0, 1.0)
	for part in [ENGINE, FRONT_BUMPER, REAR_BUMPER]:
		dent_side[part] = side
	# Corner hits land on one wheel; hits near the middle spread across both.
	var corner := absf(local_point.x) > 0.5
	if local_point.y > 0.6:
		_hurt(WINDSHIELD, severity)
	elif local_point.z < -1.45:
		var spill := _absorb(FRONT_BUMPER, severity)
		_hurt(ENGINE, severity * spill)
		if corner:
			_hurt(WHEEL_FL if left else WHEEL_FR, severity * spill * 1.4)
		else:
			_hurt(WHEEL_FL, severity * spill * 0.3)
			_hurt(WHEEL_FR, severity * spill * 0.3)
		if closing_speed > WINDSHIELD_SPEED:
			_hurt(WINDSHIELD, severity * spill)
	elif local_point.z > 1.45:
		var spill := _absorb(REAR_BUMPER, severity)
		if corner:
			_hurt(WHEEL_RL if left else WHEEL_RR, severity * spill * 1.4)
		else:
			_hurt(WHEEL_RL, severity * spill * 0.3)
			_hurt(WHEEL_RR, severity * spill * 0.3)
	else:
		# Side hits are usually glancing; the nearest wheel takes part of it.
		var front := local_point.z < 0.0
		var wheel := (WHEEL_FL if left else WHEEL_FR) if front else (WHEEL_RL if left else WHEEL_RR)
		_hurt(wheel, severity * 0.6)

## A whole-car jolt such as a hard landing: shared out across the wheels.
func apply_landing(closing_speed: float) -> void:
	var excess := closing_speed - 9.0
	if excess <= 0.0:
		return
	for wheel in 4:
		_hurt(wheel, pow(excess, CURVE) * 0.4)

## The bumper takes the hit first. Returns how much of it carries through.
func _absorb(bumper: int, excess: float) -> float:
	if not alive(bumper):
		return 1.0
	_hurt(bumper, excess)
	return BUMPER_SPILL

func _hurt(part: int, severity: float) -> void:
	if not alive(part) or severity <= 0.0:
		return
	set_part(part, maxf(0.0, health[part] - severity * RATE[part]))

func set_part(part: int, value: float) -> void:
	var was_alive := alive(part)
	var before := health[part]
	health[part] = clampf(value, 0.0, 1.0)
	if health[part] < before:
		damaged.emit(before - health[part])
	_update_visual(part)
	if was_alive and not alive(part):
		_break(part)
	elif not was_alive and alive(part):
		_restore(part)

## The part that repairs work on next, or -1 when the car is whole.
func next_repair() -> int:
	var best := -1
	for part: int in REPAIR_ORDER:
		if health[part] >= 1.0:
			continue
		if best == -1:
			best = part
		# Among the tires, fix the most damaged one first.
		elif best <= WHEEL_RR and part <= WHEEL_RR and health[part] < health[best]:
			best = part
	return best

## Spend `delta` seconds of repair work. Returns the part worked on, or -1.
func repair_step(delta: float) -> int:
	var part := next_repair()
	if part != -1:
		set_part(part, minf(1.0, health[part] + REPAIR_RATE * delta))
	return part

## A repaired part goes back on the car.
func _restore(part: int) -> void:
	for node: Node3D in visuals[part]:
		node.visible = true
	if car.has_method("_part_repaired"):
		car._part_repaired(part)

func health_array() -> Array:
	var result: Array = []
	for value in health:
		result.append(snappedf(value, 0.01))
	return result

## Mirror the driver's state, including repairs. A reset (all parts healthy
## again) may also arrive as a new ride.
func set_health_array(values: Array) -> void:
	if values.size() != PART_COUNT:
		return
	var repaired := true
	for value in values:
		repaired = repaired and float(value) >= 1.0
	if repaired and not is_pristine():
		reset()
		return
	for i in PART_COUNT:
		if not is_equal_approx(health[i], float(values[i])):
			set_part(i, float(values[i]))

func is_pristine() -> bool:
	for value in health:
		if value < 1.0:
			return false
	return true

func reset() -> void:
	health.fill(1.0)
	dent_side.fill(0.0)
	for part in PART_COUNT:
		_update_visual(part)
		for node: Node3D in visuals[part]:
			node.visible = true
	if car.has_method("_damage_reset"):
		car._damage_reset()

func summary() -> String:
	var lost: PackedStringArray = []
	for i in PART_COUNT:
		if i == WINDSHIELD:
			if not alive(i):
				lost.append("WINDSHIELD SHATTERED")
			elif health[i] < 0.7:
				lost.append("WINDSHIELD CRACKED")
		elif not alive(i):
			if i <= WHEEL_RR:
				lost.append(NAMES[i] + (" FLAT" if car.punctured_tires & (1 << i) else " LOST"))
			else:
				lost.append(NAMES[i] + (" WRECKED" if i == ENGINE else " OFF"))
		elif health[i] < 0.5:
			lost.append(NAMES[i] + " DAMAGED")
	return "" if lost.is_empty() else "DAMAGE:  " + "  /  ".join(lost)

func _update_visual(part: int) -> void:
	var wear := 1.0 - health[part]
	for j in visuals[part].size():
		var node: Node3D = visuals[part][j]
		var rest: Transform3D = rest_transforms[part][j]
		match part:
			ENGINE:
				# The hood buckles: front edge lifts, it twists toward the hit and crumples back.
				node.transform = rest.rotated_local(Vector3.RIGHT, -wear * 0.42) \
					.rotated_local(Vector3.FORWARD, -dent_side[part] * wear * 0.2) \
					.scaled_local(Vector3(1.0 - wear * 0.08, 1.0 + wear * 0.5, 1.0 - wear * 0.3)) \
					.translated(Vector3(0, wear * 0.12, wear * 0.16))
			FRONT_BUMPER, REAR_BUMPER:
				# Pushed in toward the cabin, bent toward the hit, and sagging.
				var inward := 1.0 if part == FRONT_BUMPER else -1.0
				node.transform = rest.rotated_local(Vector3.FORWARD, (0.12 + 0.3 * dent_side[part]) * wear) \
					.rotated_local(Vector3.UP, dent_side[part] * wear * 0.3 * inward) \
					.scaled_local(Vector3(1.0 - wear * 0.12, 1.0 + wear * 0.4, 1.0)) \
					.translated(Vector3(0, -wear * 0.14, inward * wear * 0.22))
			WINDSHIELD:
				var glass := node as MeshInstance3D
				if glass != null and glass.material_override is StandardMaterial3D:
					var mat: StandardMaterial3D = glass.material_override
					mat.albedo_color = Color(0.75, 0.86, 0.86, 0.18).lerp(Color(0.86, 0.88, 0.84, 0.72), wear)

func _break(part: int) -> void:
	if part == WINDSHIELD:
		part_broken.emit(part)
		return
	# A flat tire stays on its wheel.
	if part <= WHEEL_RR and car.punctured_tires & (1 << part):
		part_broken.emit(part)
		return
	for node: Node3D in visuals[part]:
		if node.visible:
			# Called from inside the physics step; add bodies once it finishes.
			_spawn_debris.call_deferred(node, part, node.global_transform)
		node.visible = false
	part_broken.emit(part)

func _spawn_debris(source: Node3D, part: int, at: Transform3D) -> void:
	var level := car.get_parent()
	if level == null or not car.is_inside_tree() or not is_instance_valid(source):
		return
	var debris := RigidBody3D.new()
	debris.name = "Debris"
	debris.add_to_group("car_debris")
	debris.mass = 18.0 if part <= WHEEL_RR else 12.0
	debris.collision_layer = 4
	debris.collision_mask = 1
	debris.continuous_cd = true
	level.add_child(debris)
	debris.add_collision_exception_with(car)
	debris.global_transform = at
	var copy := source.duplicate() as Node3D
	copy.transform = Transform3D.IDENTITY
	copy.visible = true
	debris.add_child(copy)
	var shape := CollisionShape3D.new()
	if part <= WHEEL_RR:
		var cylinder := CylinderShape3D.new()
		cylinder.radius = car.WHEEL_RADIUS
		cylinder.height = 0.24
		shape.shape = cylinder
		shape.rotation.z = PI / 2.0
	else:
		var box := BoxShape3D.new()
		var mesh_node := source as MeshInstance3D
		box.size = mesh_node.mesh.get_aabb().size if mesh_node != null and mesh_node.mesh != null else Vector3.ONE * 0.4
		shape.shape = box
	debris.add_child(shape)
	var outward := (at.origin - car.global_position).normalized()
	debris.linear_velocity = car.linear_velocity + outward * 3.5 + Vector3.UP * 2.5
	debris.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	debris.get_tree().create_timer(DEBRIS_LIFETIME).timeout.connect(debris.queue_free)
