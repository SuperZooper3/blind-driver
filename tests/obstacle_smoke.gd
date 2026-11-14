extends SceneTree
const Geo = preload("res://scripts/geometry.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
func _initialize() -> void:
	call_deferred("_run")
func frames(count: int) -> void:
	for _i in count: await physics_frame
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("solo")
	var stage := Node3D.new()
	root.add_child(stage)
	Geo.box(stage, Vector3(100, 1, 1400), Vector3(2000, 19.5, -600), Geo.material(Color.GRAY)).create_trimesh_collision()
	Hazards.render(stage, {"kind": "ramp", "position": Vector3(2000.9, 20, -30), "size": Vector3.ONE, "yaw": 0.0}, game.world.tree_mesh)
	game.car.recover(Vector3(2000, 20.17, -15), Vector3.FORWARD)
	await frames(60)
	game.car.linear_velocity = Vector3(0, 0, -28)
	var min_up := 1.0
	var max_height := 0.0
	for _i in 150:
		await physics_frame
		min_up = minf(min_up, game.car.global_basis.y.dot(Vector3.UP))
		max_height = maxf(max_height, game.car.global_position.y)
	print("Ramp: min_up=", min_up, " max_height=", max_height, " position=", game.car.global_position)
	var passed := min_up < 0 and max_height > 22.0
	print("%s: an offset ramp can launch and overturn the physical car at speed" % ("PASS" if passed else "FAIL"))
	game._restart_run()
	await frames(3)
	game.car.recover(Vector3(2030, 20.17, 0), Vector3.FORWARD)
	await frames(60)
	game.route_timer = -1000.0
	game.car.on_road = true
	Input.action_press("accelerate")
	await frames(1500)
	Input.action_release("accelerate")
	var faster: bool = game.car.signed_speed > 30.0 and game.car.global_basis.y.dot(Vector3.UP) > 0.9
	print("%s: stable straight-line speed reaches %.0f km/h, above the old 104 km/h force cutoff" % ["PASS" if faster else "FAIL", game.car.signed_speed * 3.6])
	passed = passed and faster
	game.queue_free()
	stage.queue_free()
	await process_frame
	quit(0 if passed else 1)
