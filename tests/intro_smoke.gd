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
	check(game.intro_clear and game.blur_material.get_shader_parameter("blind_strength") == 0.0, "driver's opening has no blur or haze")
	check(game.driver_view.size == game.navigator_view.size and game.ui.navigator_screen.material == null, "both opening perspectives render at full clarity")
	check_bank_clear(game.world)
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
	game.ui.show_menu(true)
	await frames(2)
	var paused_at: float = game.intro.time
	await frames(20)
	check(game.intro.time == paused_at, "opening pauses with the menu")
	game._resume()
	while game.intro.time < 8.2:
		await process_frame
	check(game.intro_clear and game.blur_material.get_shader_parameter("blind_strength") == 0.0, "flight into both seats remains sharp")
	while game.intro_playing():
		await process_frame
	await frames(3)
	seat = car.global_transform * Vector3(-0.43, 1.23, -0.05)
	check(game.driver_camera.global_position.distance_to(seat) < 0.3, "the opening ends in the driver's first-person view")
	check(not game.intro_clear and game.blur_material.get_shader_parameter("blind_strength") == 1.0, "driver blur starts only after entering the seat")
	check(game.driver_view.size.x < game.navigator_view.size.x and game.ui.navigator_screen.material == null, "only the driver becomes blurry after the opening")
	await frames(90)
	check(not car.intro_hold and car.linear_velocity.length() > 2.0, "the ride begins after the opening")
	Input.action_release("accelerate")
	check(game.intro.glasses.global_position.distance_to(glasses) < 0.01, "the broken glasses stay on the road during the ride")
	var old_intro = game.intro
	game._restart_run()
	await frames(10)
	check(game.intro_playing() and game.intro_clear and not is_instance_valid(old_intro), "a fresh ride replays a clean, sharp opening and removes the old bank")
	check_bank_clear(game.world)
	var opening = game.intro
	game._resume()
	await frames(2)
	check(game.intro == opening, "resuming a ride does not restart the opening")
	# The navigator learns about a new ride through the existing shared run ID.
	game.car.remote = true
	game.session.snapshots_received = 1
	game.car.run_id += 1
	game._update_intro()
	check(game.intro != opening and game.intro_run_id == game.car.run_id and game.intro_clear, "navigator replays the opening when a new run arrives")
	game.intro.time = game.intro.DURATION
	game._update_intro()
	game.car.run_id += 1
	game.car.distance_driven = 100.0
	game._update_intro()
	check(not game.intro_playing(), "joining an already moving ride does not put a bank around the car")
	quit(1 if failed else 0)

func check_bank_clear(world: Node3D) -> void:
	var site = preload("res://scripts/bank_site.gd")
	var clear := true
	for tile: Node3D in world.tiles.values():
		for child in tile.get_children():
			if child is MultiMeshInstance3D:
				for i in child.multimesh.instance_count:
					clear = clear and not site.contains(child.multimesh.get_instance_transform(i).origin)
			elif child is StaticBody3D:
				clear = clear and not site.contains(child.global_position)
	check(clear and not world.thorn_at(site.CENTER), "bank clearing has no trees, rocks, hidden trunk colliders or thorns")
