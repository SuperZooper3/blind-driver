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
