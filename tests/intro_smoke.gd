extends SceneTree
## The bank-robbery opening holds the car, shows the scene from outside, drops
## the driver's glasses and hands over to the seat view.
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition
func frames(count: int) -> void:
	for _i in count: await process_frame
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	game.records.path = "user://intro-check-%d.cfg" % OS.get_process_id()
	game.intro_enabled = true
	root.add_child(game)
	game._start("split")
	await frames(30)
	var car = game.car
	check(game.intro != null and game.intro_playing(), "starting a ride plays the bank opening")
	check(game.intro.get_node_or_null("Bank") != null and game.intro.alarm_light != null, "the bank and its alarm are built beside the car")
	Input.action_press("accelerate")
	await frames(60)
	var seat: Vector3 = car.global_transform * Vector3(-0.43, 1.23, -0.05)
	check(game.driver_camera.global_position.distance_to(seat) > 6.0, "the opening watches from outside the car")
	check(car.intro_hold and car.linear_velocity.length() < 0.5, "the car waits at the bank during the opening")
	while game.intro.time < 5.5:
		await process_frame
	var glasses: Vector3 = game.intro.glasses.global_position
	check(game.intro.broken and glasses.y < car.global_position.y - 0.5, "the driver's glasses fall onto the road and break")
	check(game.driver_camera.global_position.distance_to(glasses) < 2.0, "a shot shows the broken glasses on the ground")
	while game.intro_playing():
		await process_frame
	await frames(3)
	seat = car.global_transform * Vector3(-0.43, 1.23, -0.05)
	check(game.driver_camera.global_position.distance_to(seat) < 0.3, "the opening ends in the driver's first-person view")
	await frames(90)
	check(not car.intro_hold and car.linear_velocity.length() > 2.0, "the ride begins after the opening")
	Input.action_release("accelerate")
	game._restart_run()
	await frames(10)
	check(not game.intro_playing(), "the opening plays only once")
	check(game.intro.glasses.global_position.distance_to(glasses) < 0.01, "the broken glasses stay on the road")
	quit(1 if failed else 0)
