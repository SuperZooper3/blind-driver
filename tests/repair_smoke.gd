extends SceneTree
## Repairs under 15 km/h, most crucial part first, and half-road spike strips.
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition
func frames(count: int) -> void:
	for _i in count: await physics_frame
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	game.records.path = "user://repair-check-%d.cfg" % OS.get_process_id()
	root.add_child(game)
	game._start("solo")
	var car = game.car
	var world = game.world
	var damage = car.damage
	await frames(90)
	# Keep the patrol away so it cannot end the ride while the car sits still.
	world.basic_course = true
	check(InputMap.has_action("repair") and InputMap.action_get_events("repair")[0].physical_keycode == KEY_R, "repair is bound to R")
	check(car.start_repair() == "nothing", "an undamaged car has nothing to repair")
	damage.set_part(damage.REAR_BUMPER, 0.4)
	damage.set_part(damage.WHEEL_RL, 0.6)
	car.flatten_tire(damage.WHEEL_FR)
	damage.set_part(damage.WHEEL_FR, 0.0)
	damage.set_part(damage.ENGINE, 0.0)
	check(not damage.alive(damage.ENGINE) and car.smoke.emitting, "wrecked engine smokes before repair")
	car.linear_velocity = -car.global_basis.z * 8.0
	car.signed_speed = 8.0
	check(car.start_repair() == "too_fast" and not car.repairing, "repairs refuse to start at 29 km/h")
	car.linear_velocity = Vector3.ZERO
	await frames(30)
	check(car.start_repair() == "" and car.repairing and car.repair_part == damage.ENGINE, "repairs start below 15 km/h on the engine first")
	Input.action_press("accelerate")
	var start: Vector3 = car.global_position
	await frames(120)
	check(car.repairing and car.global_position.distance_to(start) < 0.5, "the car stays put while repairs run")
	await frames(240)
	check(damage.alive(damage.ENGINE) and damage.health[damage.ENGINE] >= 1.0 and not car.smoke.emitting, "engine is fully repaired first and stops smoking")
	check(car.repair_part == damage.WHEEL_FR, "the flat tire is repaired next, before the less damaged one")
	await frames(330)
	check(car.punctured_tires == 0 and car.wheel_pivots[damage.WHEEL_FR].scale.y == 1.0 and damage.alive(damage.WHEEL_FR), "repaired flat tire is reinflated")
	await frames(360)
	check(damage.is_pristine() and not car.repairing, "repairs finish once every part is whole")
	await frames(60)
	check(car.global_position.distance_to(start) > 0.5, "the car drives normally after repairs")
	Input.action_release("accelerate")
	# A spike strip pops only tires that roll over it, and it covers one half of the road.
	game.started = false
	var road: Dictionary = world.roads[0]
	var points: PackedVector3Array = road.points
	var direction: Vector3 = (points[11] - points[10]).normalized()
	var side: Vector3 = direction.cross(Vector3.UP)
	var at: Vector3 = points[10] + side * world.ROAD_WIDTH * 0.25
	var strip := {"kind": "spikes", "position": at, "size": Vector3.ONE, "yaw": atan2(-direction.x, -direction.z)}
	road.hazards.append(strip)
	var facing := Basis.looking_at(direction)
	# Park the car with its front axle on the strip.
	var front: Vector3 = facing * Vector3(0, 0, car.wheel_pivots[0].position.z)
	car.reset_transform = Transform3D(facing, at - front + Vector3.UP * 0.6)
	car.reset_pending = true
	await frames(20)
	var mask: int = world.spike_mask(car)
	check(mask != 0, "wheels over the strip touch the spikes")
	car.reset_transform = Transform3D(facing, points[10] - side * world.ROAD_WIDTH * 0.25 - front + Vector3.UP * 0.6)
	car.reset_pending = true
	await frames(20)
	check(world.spike_mask(car) == 0, "the other half of the road is clear of spikes")
	game.started = true
	car.reset_transform = Transform3D(facing, at - front + Vector3.UP * 0.6)
	car.reset_pending = true
	await frames(20)
	check(car.punctured_tires != 0 and damage.broken_tires() > 0, "driving over the spikes pops the tires")
	var spike_kind := false
	world.basic_course = false
	for i in 12:
		world._add_road(Vector3(4000, 0, i * 400), 0.1, 3, -1)
	for r: Dictionary in world.roads:
		for h: Dictionary in r.hazards:
			spike_kind = spike_kind or (h.kind == "spikes" and h != strip)
	check(spike_kind, "generated roads include spike strips")
	quit(1 if failed else 0)
