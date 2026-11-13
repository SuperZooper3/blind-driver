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
	await frames(100)
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
	check(world.roads.size() >= 3, "initial road branches into two real roads")
	var left_id: int = world.roads[1].id
	var right_id: int = world.roads[2].id
	world.grow_near(world.roads[1].points[-1])
	world.grow_near(world.roads[2].points[-1])
	var parents: Array = []
	for road: Dictionary in world.roads:
		parents.append(road.parent)
	check(parents.has(left_id) and parents.has(right_id), "either initial fork generates a continuation")
	for step in 32:
		var newest: Dictionary = world.roads[-1]
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
	game._start("solo")
	check(damage.is_pristine(), "a new ride starts with an undamaged car")
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
	Input.action_press("accelerate")
	await frames(150)
	Input.action_release("accelerate")
	wall.queue_free()
	print("Crash: health=%s" % [damage.health_array()])
	check(damage.health[damage.FRONT_BUMPER] < 1.0, "driving into a wall damages the front bumper")
	check(damage.alive(damage.WHEEL_RL) and damage.alive(damage.WHEEL_RR), "a frontal crash leaves the rear wheels on")
	# Light taps do nothing.
	var bumper: float = damage.health[damage.FRONT_BUMPER]
	damage.apply_impact(Vector3(0, 0, -1.9), 3.0)
	check(is_equal_approx(damage.health[damage.FRONT_BUMPER], bumper), "a gentle bump causes no damage")
	var straight := absf(await _yaw_drift(game, car, 110))
	# Repeated hard hits to the front-left corner.
	for _i in 4:
		damage.apply_impact(Vector3(-0.8, 0.0, -1.9), 18.0)
	await process_frame
	check(not damage.alive(damage.FRONT_BUMPER), "hard hits knock the front bumper off")
	check(not damage.alive(damage.WHEEL_FL), "the front-left wheel comes off once the bumper is gone")
	check(damage.health[damage.HOOD] < 1.0 and damage.windshield_crack() > 0.0, "hits spill into the hood and windshield")
	check(get_nodes_in_group("car_debris").size() >= 2, "broken parts fall off as debris")
	car.toggle_lights()
	check(not car.headlights[0].visible, "headlights are broken with the front bumper")
	var lopsided := absf(await _yaw_drift(game, car, 110))
	print("Drift: intact=%.3f rad, missing wheel=%.3f rad, grounded=%d" % [straight, lopsided, car.grounded_wheels])
	check(car.grounded_wheels <= 3, "a missing wheel no longer touches the road")
	check(lopsided > straight + 0.05, "a missing wheel pulls the car off a straight line")
	game._recover()
	await frames(10)
	check(not damage.alive(damage.WHEEL_FL), "recovery does not repair the car")
	game._start("solo")
	check(damage.is_pristine() and car.wheel_meshes[0].visible, "a new ride repairs every part")
	await frames(30)
