extends SceneTree
## The cabin must stay still in the passenger view, including late network poses.
var failed := false
const SEAT := Transform3D(Basis.IDENTITY, Vector3(0.43, 1.23, -0.05))
const REAR_SEAT := Transform3D(Basis(Vector3.UP, PI), Vector3(0.43, 1.30, 0.9))

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok

func matches_seat(game, expected: Transform3D) -> bool:
	var local: Transform3D = game.car.global_transform.affine_inverse() * game.navigator_camera.global_transform
	return local.origin.distance_to(expected.origin) < 0.001 and local.basis.is_equal_approx(expected.basis)

func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.intro_enabled = false
	game._start("split")
	game.set_process(false)
	game.set_physics_process(false)
	game.session.set_process(false)
	game.car.set_physics_process(false)
	game.car.remote = true
	game.car.freeze = true
	game.car.reset_pending = false
	game.car.recovery_grace = 0
	game.world.set_process(false)
	var steady := true
	var late_pose := true
	for fps in [30.0, 60.0, 144.0]:
		for i in 12:
			game.car.global_transform = Transform3D(Basis.from_euler(Vector3(sin(i) * 0.25, i * 0.17, cos(i) * 0.2)), Vector3(i * 0.6, 2 + sin(i), -i * 0.7))
			game._update_cameras(1.0 / fps)
			steady = steady and matches_seat(game, SEAT)
			# Session._process normally runs after the main camera update. Simulate
			# that correction without giving the camera another manual update.
			game.car.global_transform = Transform3D(Basis.from_euler(Vector3(-0.12, i * 0.19, 0.23)), game.car.global_position + Vector3(0.1, 0.04, -0.4))
			await process_frame
			late_pose = late_pose and matches_seat(game, SEAT)
	check(steady, "passenger stays fixed through yaw, pitch, roll, and speed changes at 30/60/144 fps")
	check(late_pose, "late network car updates carry the passenger camera with them in the same frame")
	game._on_car_impact(1.0)
	game._update_cameras(1.0 / 60.0)
	check(matches_seat(game, SEAT), "crash effects do not move the cabin relative to the passenger")
	game.looking_back = true
	game._update_cameras(1.0 / 60.0)
	game.car.global_position += Vector3(0.3, 0.2, -1.0)
	await process_frame
	check(matches_seat(game, REAR_SEAT), "look-back stays attached to the car at the rear-facing seat")
	game.looking_back = false
	game._update_cameras(1.0 / 60.0)
	check(matches_seat(game, SEAT), "releasing look-back restores the fixed forward seat")
	game.chase_camera = true
	game._update_cameras(1.0 / 60.0)
	var external: Transform3D = game.navigator_camera.global_transform
	game.car.global_position += Vector3(0, 0, -3)
	await process_frame
	check(game.navigator_camera.global_transform.is_equal_approx(external), "seat attachment releases the external chase camera")
	game.chase_camera = false
	game._update_cameras(1.0 / 60.0)
	game.car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 2, 12))
	await process_frame
	check(matches_seat(game, SEAT), "returning to the seat and teleporting for restart keeps the cabin locked")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
