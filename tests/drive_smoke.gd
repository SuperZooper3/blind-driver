extends SceneTree
## Run: Godot --headless --path . --script tests/drive_smoke.gd

var failed := false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	if not condition:
		failed = true

func frames(count: int) -> void:
	for _i in count:
		await physics_frame

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	await frames(120)
	var car = game.car
	check(car.grounded_wheels == 4, "all four wheels settle on the ground")
	check(car.linear_velocity.length() < 0.5, "parked car is stable")
	check(car.global_basis.y.dot(Vector3.UP) > 0.95, "suspension holds the car upright")
	game._start("solo")
	Input.action_press("accelerate")
	await frames(480)
	Input.action_release("accelerate")
	print("Drive: speed=%.1f m/s distance=%.1f position=%s" % [car.signed_speed, car.distance_driven, car.global_position])
	check(car.signed_speed > 12.0, "accelerates beyond 43 km/h")
	check(car.distance_driven > 65.0, "car makes sustained forward progress")
	check(car.global_basis.y.dot(Vector3.UP) > 0.8, "car stays upright at speed")
	Input.action_press("reverse")
	for _i in 240:
		await physics_frame
		if car.signed_speed < 1.5:
			break
	Input.action_release("reverse")
	check(absf(car.signed_speed) < 4.0, "brake input brings the car to a stop")
	game._recover()
	await frames(90)
	check(car.grounded_wheels == 4, "recovery puts four wheels back on the road")
	var before: Vector3 = -car.global_basis.z
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	await frames(100)
	Input.action_release("accelerate")
	Input.action_release("steer_left")
	check((-car.global_basis.z).dot(before) < 0.97, "steering changes the vehicle's heading")
	check(car.global_position.y > -10.0, "car remains above streamed terrain")
	await _check_damage(game, car)
	var world = game.world
	check(world.roads.size() >= 3, "initial road branches into a safe road and a cliff")
	var left_id: int = world.roads[1].id
	var right_id: int = world.roads[2].id
	world.grow_near(world.roads[1].points[-1])
	world.grow_near(world.roads[2].points[-1])
	var parents: Array = []
	for road: Dictionary in world.roads:
		parents.append(road.parent)
	check(parents.has(left_id) and not parents.has(right_id), "only the safe branch generates a continuation")
	for step in 32:
		var newest: Dictionary = world.roads[-1]
		for road: Dictionary in world.roads:
			if not road.danger and not road.expanded:
				newest = road
		var point: Vector3 = newest.points[-1]
		world.grow_near(point)
	check(world.next_id > 30, "road generation keeps extending through many forks")
	check(world.roads.size() <= world.MAX_ROADS, "distant road graph stays bounded")
	print("Streaming: %d total roads generated, %d retained" % [world.next_id, world.roads.size()])
	var endpoint: Vector3 = world.roads[-1].points[-1]
	world.update_stream(endpoint, true)
	check(world.tiles.size() <= 81, "terrain tiles stay bounded after a long-distance move")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)

## Drive straight on full throttle and return the signed heading change in radians.
func _yaw_drift(game, car, count: int) -> float:
	game._recover()
	await frames(50)
	var before: Vector3 = -car.global_basis.z
	Input.action_press("accelerate")
	await frames(count)
	Input.action_release("accelerate")
	var after: Vector3 = -car.global_basis.z
	return Vector2(before.x, before.z).angle_to(Vector2(after.x, after.z))

func _check_damage(game, car) -> void:
	var damage = car.damage
	game._restart_run()
	# Keep the patrol out of the way: these checks are about the car alone.
	game.police.phase = "escaped"
	await frames(30)
	check(damage.is_pristine() and car.run_state == "driving", "a new run starts with an undamaged car")
	# A real crash: a wall across the road ahead.
	game._recover()
	await frames(50)
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8, 5, 1)
	shape.shape = box
	wall.add_child(shape)
	game.add_child(wall)
	wall.global_transform = Transform3D(car.global_basis, car.global_transform * Vector3(0, 0.5, -16))
	var sounds := [0]
	var count_sound := func(_strength: float): sounds[0] += 1
	car.impacted.connect(count_sound)
	Input.action_press("accelerate")
	await frames(150)
	Input.action_release("accelerate")
	wall.queue_free()
	car.impacted.disconnect(count_sound)
	check(sounds[0] >= 1, "hitting the wall plays a crash sound")
	print("Crash: health=%s" % [damage.health_array()])
	check(damage.health[damage.FRONT_BUMPER] < 1.0, "driving into a wall damages the front bumper")
	check(car.run_state == "driving", "one crash does not end the run")
	var bumper: float = damage.health[damage.FRONT_BUMPER]
	damage.apply_impact(Vector3(0, 0, -1.9), 3.0)
	check(is_equal_approx(damage.health[damage.FRONT_BUMPER], bumper), "a gentle bump causes no damage")
	# Worn but unbroken parts do not change how the car drives.
	for wheel in 4:
		damage.set_part(wheel, 0.3)
	damage.set_part(damage.ENGINE, 0.2)
	check(damage.wheel_grip(0) == 1.0 and damage.wheel_toe(0) == 0.0 and damage.steer_scale() == 1.0, "damaged tires keep full grip until they break")
	var worn := absf(await _yaw_drift(game, car, 110))
	var healthy_speed: float = car.signed_speed
	check(car.run_state == "driving" and car.signed_speed > 6.0, "a damaged engine still pulls normally")
	damage.reset()
	# Hard hits to the front: the bumper takes them, then falls off.
	damage.apply_impact(Vector3(0, 0, -1.9), 14.0)
	await process_frame
	check(not damage.alive(damage.FRONT_BUMPER) and car.run_state == "driving", "a 50 km/h hit knocks the front bumper off")
	check(damage.health[damage.ENGINE] < 1.0 and damage.alive(damage.ENGINE), "front hits spill into the engine")
	car.toggle_lights()
	check(not car.headlights[0].visible, "headlights are broken with the front bumper")
	# A side hit by the front-left wheel knocks it off.
	damage.apply_impact(Vector3(-0.9, 0.0, -1.0), 22.0)
	damage.apply_impact(Vector3(-0.9, 0.0, -1.0), 22.0)
	await process_frame
	check(not damage.alive(damage.WHEEL_FL) and car.run_state == "driving", "a lost wheel leaves the car limping, not stopped")
	check(get_nodes_in_group("car_debris").size() >= 2, "broken parts fall off as debris")
	var lopsided := absf(await _yaw_drift(game, car, 110))
	print("Drift: worn tires=%.3f rad, missing wheel=%.3f rad, grounded=%d" % [worn, lopsided, car.grounded_wheels])
	check(car.grounded_wheels <= 3, "a missing wheel no longer touches the road")
	check(lopsided > worn + 0.05, "a missing wheel pulls the car off a straight line")
	game._recover()
	await frames(10)
	check(not damage.alive(damage.WHEEL_FL), "recovery does not repair the car")
	# Thorns tear a tire flat instead of ending the run at first touch.
	car.wear_tires(1 << damage.WHEEL_RR, 0.5)
	check(car.run_state == "driving" and damage.alive(damage.WHEEL_RR) and damage.health[damage.WHEEL_RR] < 1.0, "a brush with thorns only wears the tire")
	var pops := [0]
	var count_pop := func(): pops[0] += 1
	car.tire_popped.connect(count_pop)
	car.wear_tires(1 << damage.WHEEL_RR, 1.0)
	await frames(5)
	car.tire_popped.disconnect(count_pop)
	check(car.punctured_tires & (1 << damage.WHEEL_RR) and car.wheel_meshes[damage.WHEEL_RR].visible, "a worn-out tire goes flat but stays on")
	check(pops[0] == 1, "a tire going flat plays one pop")
	check(car.run_state == "driving" and damage.power_scale() < 0.75, "two broken tires cripple the car but do not end the run")
	damage.set_part(damage.ENGINE, 0.0)
	await frames(5)
	check(car.run_state == "driving", "a blown engine with two broken tires limps on along the road")
	game._recover()
	car.recover(game.world.ground_point(26, 12, 0.17), Vector3.FORWARD)
	await frames(30)
	check(car.run_state == "game_over" and car.crash_reason.contains("broke down"), "a blown engine with two broken tires ends the run in the thorn forest")
	game._restart_run()
	game.police.phase = "escaped"
	await frames(30)
	damage.set_part(damage.WHEEL_FL, 0.0)
	damage.set_part(damage.ENGINE, 0.0)
	await frames(5)
	check(car.run_state == "driving" and car.smoke.emitting and damage.power_scale() < 0.4, "a wrecked engine with one broken tire smokes and loses most of its power")
	var wrecked_speed := absf(await _yaw_drift(game, car, 110))
	wrecked_speed = car.signed_speed
	print("Speed after 110 frames: healthy=%.1f m/s, wrecked=%.1f m/s" % [healthy_speed, wrecked_speed])
	check(car.run_state == "driving" and wrecked_speed < healthy_speed * 0.6, "a wrecked car still drives, much slower")
	game._restart_run()
	game.police.phase = "escaped"
	await frames(30)
	for wheel in 3:
		damage.set_part(wheel, 0.0)
	await frames(5)
	check(car.run_state == "driving", "three broken tires on the road do not end the run")
	car.recover(game.world.ground_point(26, 12, 0.17), Vector3.FORWARD)
	await frames(30)
	check(car.run_state == "game_over" and car.crash_reason.contains("broke down"), "three broken tires end the run in the thorn forest, away from the police")
	game._restart_run()
	game.police.phase = "escaped"
	await frames(30)
	check(damage.is_pristine() and car.wheel_meshes[0].visible and car.punctured_tires == 0 and not car.smoke.emitting, "a new run repairs every part")
