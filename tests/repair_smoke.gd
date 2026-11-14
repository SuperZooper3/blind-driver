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
	check(InputMap.has_action("repair") and game.mode == "solo" and InputMap.action_get_events("repair")[0].physical_keycode == KEY_R, "repair is bound to R")
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
	Input.action_press("repair")
	await frames(2)
	check(car.repairing and car.repair_part == damage.ENGINE, "holding R below 15 km/h repairs the engine first")
	game.ui.set_mode("split")
	await frames(2)
	check(game.ui.repair_overlays[0].is_visible_in_tree() and game.ui.repair_overlays[1].is_visible_in_tree(), "both seat views show the repairing overlay")
	var overlay = game.ui.repair_overlays[1]
	check(overlay.health.size() == damage.PART_COUNT and overlay.health[damage.REAR_BUMPER] == damage.health[damage.REAR_BUMPER] and overlay.health[damage.WHEEL_FL] == 1.0, "repair bars include queued damage and already healthy parts")
	game.ui.toggle_map()
	await frames(25)
	check(game.ui.map_open and overlay.visible and game.ui.map_clip.z_index > overlay.z_index, "the open map sits above the repair display")
	game.ui.rear_button_held = true
	await frames(2)
	check(game.looking_back and not game.ui.map_open and overlay.visible and overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "look-back works and the repairing overlay stays visible")
	game.ui.rear_button_held = false
	game.ui.set_mode("solo")
	Input.action_press("accelerate")
	var start: Vector3 = car.global_position
	await frames(120)
	check(car.repairing and car.global_position.distance_to(start) < 0.5, "the car stays put while repairs run")
	Input.action_release("repair")
	await frames(2)
	var partial: float = damage.health[damage.ENGINE]
	check(not car.repairing and partial > 0.3 and partial < 1.0, "letting go of R stops repairs part-way")
	check(not overlay.visible, "releasing repair removes the overlay so driving can resume")
	await frames(60)
	check(car.global_position.distance_to(start) > 0.5 and is_equal_approx(damage.health[damage.ENGINE], partial), "the car drives on half-repaired")
	Input.action_release("accelerate")
	car.linear_velocity = Vector3.ZERO
	await frames(60)
	Input.action_press("repair")
	Input.action_press("accelerate")
	start = car.global_position
	await frames(220)
	check(damage.alive(damage.ENGINE) and damage.health[damage.ENGINE] >= 1.0 and not car.smoke.emitting, "engine is fully repaired first and stops smoking")
	check(car.repair_part == damage.WHEEL_FR, "the flat tire is repaired next, before the less damaged one")
	check(overlay.active_part == damage.WHEEL_FR and overlay.health[damage.ENGINE] == 1.0, "repair bars retain the completed engine while the next part repairs")
	await frames(330)
	check(car.punctured_tires == 0 and car.wheel_pivots[damage.WHEEL_FR].scale.y == 1.0 and damage.alive(damage.WHEEL_FR), "repaired flat tire is reinflated")
	await frames(360)
	Input.action_release("repair")
	check(damage.is_pristine() and not car.repairing, "repairs finish once every part is whole")
	await frames(2)
	check(not overlay.visible, "the repair overlay disappears when all work is complete")
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
	# Shredded tires on the road leave a limping car; only the forest ends the ride.
	world.basic_course = false
	for wheel in 4:
		car.flatten_tire(wheel)
		damage.set_part(wheel, 0.0)
	await frames(30)
	check(car.run_state == "driving", "four flat tires on the road do not end the ride")
	car.recover(world.ground_point(-26, 12, 0.17), Vector3.FORWARD)
	await frames(30)
	check(car.run_state == "game_over" and car.crash_reason.contains("shredded"), "shredded tires end the ride in the thorn forest")
	var spike_kind := false
	world.difficulty = 2
	var first_new: int = world.roads.size()
	for i in 12:
		world._add_road(Vector3(4000, 0, i * 400), 0.1, 3, -1)
	var early := false
	for r: Dictionary in world.roads.slice(first_new):
		for h: Dictionary in r.hazards: early = early or h.kind == "spikes"
	check(not early, "no spike strips below heat 4")
	world.difficulty = 3
	for i in 12:
		world._add_road(Vector3(6000, 0, i * 400), 0.1, 3, -1)
	var warned := true
	for r: Dictionary in world.roads:
		var sign_at = null
		for h: Dictionary in r.hazards:
			if h.kind == "spike_sign": sign_at = h.position
		for h: Dictionary in r.hazards:
			if h.kind == "spikes" and h != strip:
				warned = warned and sign_at != null and Vector2(h.position.x, h.position.z).distance_to(Vector2(sign_at.x, sign_at.z)) >= 95.0
	check(warned, "every spike strip has a warning sign at least 100 m before it")
	for r: Dictionary in world.roads:
		for h: Dictionary in r.hazards:
			spike_kind = spike_kind or (h.kind == "spikes" and h != strip)
	check(spike_kind, "generated roads include spike strips")
	quit(1 if failed else 0)
