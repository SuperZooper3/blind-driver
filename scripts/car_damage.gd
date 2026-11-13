extends RefCounted
## Health for the car's few big, breakable parts, and what each loss costs.
## The driver's game is authoritative; navigators mirror `health` from snapshots.

enum { WHEEL_FL, WHEEL_FR, WHEEL_RL, WHEEL_RR, HOOD, FRONT_BUMPER, REAR_BUMPER, WINDSHIELD }
const PART_COUNT := 8
const NAMES := ["FL WHEEL", "FR WHEEL", "RL WHEEL", "RR WHEEL", "HOOD", "FRONT BUMPER", "REAR BUMPER", "WINDSHIELD"]
## Closing speed (m/s) below which a hit does no harm.
const SAFE_SPEED := 3.5
## Damage per m/s above SAFE_SPEED.
const RATE := [0.055, 0.055, 0.055, 0.055, 0.05, 0.06, 0.06, 0.045]
## Frontal hits only reach the windshield above this closing speed.
const WINDSHIELD_SPEED := 8.0
const DEBRIS_LIFETIME := 20.0

signal part_broken(part: int)

var car: RigidBody3D
var health := PackedFloat32Array()
## Each part's breakable visuals. A wheel's entry is its spinning wheel node.
var visuals: Array = []
var rest_transforms: Array = []

func _init(owner_car: RigidBody3D) -> void:
	car = owner_car
	health.resize(PART_COUNT)
	health.fill(1.0)
	for i in PART_COUNT:
		visuals.append([])
		rest_transforms.append([])

func register(part: int, node: Node3D) -> void:
	visuals[part].append(node)
	rest_transforms[part].append(node.transform)

func alive(part: int) -> bool:
	return health[part] > 0.0

## Lateral grip multiplier: a bent wheel slides more.
func wheel_grip(wheel: int) -> float:
	return lerpf(0.55, 1.0, health[wheel])

## Permanent toe-out of a bent wheel, in radians. Left wheels pull left, right wheels pull right.
func wheel_toe(wheel: int) -> float:
	var side := 1.0 if wheel % 2 == 0 else -1.0
	return side * (1.0 - health[wheel]) * 0.07

func engine_scale() -> float:
	return 0.7 if not alive(HOOD) else lerpf(0.9, 1.0, health[HOOD])

func speed_scale() -> float:
	return 0.82 if not alive(HOOD) else 1.0

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
	var left := local_point.x < 0.0
	if local_point.y > 0.6:
		_hurt(WINDSHIELD, excess)
	elif local_point.z < -1.45:
		var spill := _absorb(FRONT_BUMPER, excess)
		_hurt(HOOD, excess * spill)
		_hurt(WHEEL_FL if left else WHEEL_FR, excess * spill * (1.4 if absf(local_point.x) > 0.5 else 0.6))
		if closing_speed > WINDSHIELD_SPEED:
			_hurt(WINDSHIELD, excess * spill)
	elif local_point.z > 1.45:
		var spill := _absorb(REAR_BUMPER, excess)
		_hurt(WHEEL_RL if left else WHEEL_RR, excess * spill * (1.4 if absf(local_point.x) > 0.5 else 0.6))
	else:
		var front := local_point.z < 0.0
		var wheel := (WHEEL_FL if left else WHEEL_FR) if front else (WHEEL_RL if left else WHEEL_RR)
		_hurt(wheel, excess)

## A whole-car jolt such as a hard landing: shared out across the wheels.
func apply_landing(closing_speed: float) -> void:
	var excess := closing_speed - 9.0
	if excess <= 0.0:
		return
	for wheel in 4:
		_hurt(wheel, excess * 0.5)

## The bumper takes the hit first. Returns how much of it carries through.
func _absorb(bumper: int, excess: float) -> float:
	if not alive(bumper):
		return 1.0
	_hurt(bumper, excess)
	return 0.3

func _hurt(part: int, excess: float) -> void:
	if not alive(part) or excess <= 0.0:
		return
	set_part(part, maxf(0.0, health[part] - excess * RATE[part]))

func set_part(part: int, value: float) -> void:
	var was_alive := alive(part)
	health[part] = clampf(value, 0.0, 1.0)
	_update_visual(part)
	if was_alive and not alive(part):
		_break(part)

func health_array() -> Array:
	var result: Array = []
	for value in health:
		result.append(snappedf(value, 0.01))
	return result

## Mirror the driver's state. Parts can only get worse during a ride; a reset
## (all parts healthy again) arrives as a new ride.
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
			lost.append(NAMES[i] + (" LOST" if i <= WHEEL_RR else " OFF"))
		elif health[i] < 0.5:
			lost.append(NAMES[i] + " DAMAGED")
	return "" if lost.is_empty() else "DAMAGE:  " + "  /  ".join(lost)

func _update_visual(part: int) -> void:
	var wear := 1.0 - health[part]
	for j in visuals[part].size():
		var node: Node3D = visuals[part][j]
		var rest: Transform3D = rest_transforms[part][j]
		match part:
			HOOD:
				node.transform = rest.rotated_local(Vector3.RIGHT, -wear * 0.2).translated(Vector3(0, wear * 0.06, 0))
			FRONT_BUMPER, REAR_BUMPER:
				node.transform = rest.rotated_local(Vector3.FORWARD, wear * 0.22).translated(Vector3(0, -wear * 0.09, 0))
			WINDSHIELD:
				var glass := node as MeshInstance3D
				if glass != null and glass.material_override is StandardMaterial3D:
					var mat: StandardMaterial3D = glass.material_override
					mat.albedo_color = Color(0.75, 0.86, 0.86, 0.18).lerp(Color(0.86, 0.88, 0.84, 0.72), wear)

func _break(part: int) -> void:
	if part == WINDSHIELD:
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
