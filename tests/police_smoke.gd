extends SceneTree
const Wire = preload("res://scripts/wire_protocol.gd")
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition
func tick(patrol: Node3D, count: int, running: bool = true) -> void:
	for _i in count: patrol.advance(1.0 / 60.0, running)
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("solo")
	game.set_process(false)
	game.set_physics_process(false)
	game.world.set_process(false)
	game.car.freeze = true
	game.car.driving_enabled = false
	var cop = game.police
	var car = game.car
	var world = game.world
	var initial: Vector3 = cop.global_position
	check(initial.z > car.global_position.z + 80 and world.road_distance(initial) < 0.1, "patrol starts behind the car on the extended starting road")
	tick(cop, 180, false)
	check(cop.elapsed == 0 and cop.global_position == initial and cop.siren_gain() == 0, "menus and disconnected sessions freeze pursuit and silence the siren")
	tick(cop, 300)
	check(cop.phase == "waiting" and cop.global_position == initial, "driver gets a six-second head start")
	tick(cop, 300)
	check(cop.phase == "chasing" and cop.gap < 75 and cop.global_position.distance_to(initial) > 15 and cop.eta() > 0, "patrol closes physically and estimates catch time from the changing road gap")
	car.distance_driven = 123.0
	tick(cop, 600)
	game._process(1.0 / 60.0)
	check(cop.phase == "caught" and car.run_state == "game_over" and car.crash_reason.contains("police") and game.ui.result_panel.visible, "sustained proximity ends the run and shows the shared failure screen")
	game._restart_run()
	car.reset_pending = false
	car.global_transform = car.reset_transform
	check(cop.phase == "waiting" and cop.catch_time == 0 and cop.gap == cop.START_GAP, "new ride resets patrol, lead, and catch progress")
	var root_id: int = world.roads[0].id
	var safe: Dictionary = world.roads[1]
	var bad: Dictionary = world.roads[2]
	cop.phase = "chasing"
	cop.elapsed = 7
	cop.station = cop.cache[root_id].length - 12
	cop.speed = 19
	car.global_position = safe.points[-1] + Vector3.UP
	cop.last_gap = cop._route_gap(safe.id, cop.cache[safe.id].length)
	tick(cop, 180)
	check(cop.road_id == safe.id and world.road_distance(cop.global_position) < 4, "patrol takes the driver's safe fork without cutting through the forest")
	var rock: Dictionary = safe.hazards[0]
	var rock_station: float = cop._project(rock.position, safe.id).station
	cop.station = rock_station - 20
	cop.lateral = 0
	cop.speed = 25
	cop._place(1, 1)
	var minimum_clearance := INF
	var slowed := false
	for _i in 180:
		cop.advance(1.0 / 60.0, true)
		minimum_clearance = minf(minimum_clearance, Vector2(cop.global_position.x - rock.position.x, cop.global_position.z - rock.position.z).length())
		slowed = slowed or cop.speed < 21
		if cop.station > rock_station + 10: break
	check(slowed and minimum_clearance > 2.2, "patrol brakes and steers around a rock with vehicle-width clearance")
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	cop.station = cop.cache[root_id].length - 8
	cop.speed = 19
	car.global_position = bad.points[20] + Vector3.UP
	tick(cop, 90)
	check(cop.road_id == bad.id, "patrol follows the chosen wrong branch too")
	car.global_position = safe.points[15] + Vector3.UP
	tick(cop, 300)
	check(cop.road_id == safe.id, "changing branches sends the patrol back through the junction")
	# The same model backs both peers; remote mode never runs its own AI.
	var snapshot: Dictionary = cop.snapshot()
	var replica = load("res://scripts/police_pursuit.gd").new()
	root.add_child(replica)
	replica.apply_snapshot(snapshot, snapshot, 1)
	check(Wire._police_state(snapshot) and replica.global_position.is_equal_approx(cop.global_position) and replica.phase == cop.phase and is_equal_approx(replica.gap, cop.gap), "police pose, gap, phase, and catch state round-trip to a receiver")
	replica.queue_free()
	cop.reset()
	cop.phase = "chasing"
	cop.paused = false
	cop.global_position = car.global_position + Vector3.BACK * 20
	var near_gain: float = cop.siren_gain()
	cop.global_position = car.global_position + Vector3.BACK * 220
	check(near_gain > cop.siren_gain() * 5, "siren grows substantially louder as the patrol approaches")
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 12))
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	var player_station := 138.0
	for _i in 120:
		player_station += 31.0 / 60.0
		car.global_position = cop._sample(root_id, player_station).point + Vector3.UP
		cop.advance(1.0 / 60.0, true)
	check(cop.closing_speed < -1 and cop.eta() < 0, "pulling away never displays a misleading catch countdown")
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	car.global_position = cop._sample(root_id, 340).point + Vector3.UP
	car.distance_driven = 0
	tick(cop, 600)
	var early_speed: float = cop.speed
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	car.distance_driven = 2200
	tick(cop, 600)
	check(cop.speed > early_speed + 5, "distance progression raises the patrol's cruising pace")
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	car.global_position = bad.points[-1] + Vector3.UP
	tick(cop, 360)
	check(cop.phase == "escaped" and not cop.visible and cop.siren_gain() == 0, "holding a 300 m lead loses the patrol without teleporting it forward")
	# Rear controls must not change the driver's view, including on a shared screen.
	car.run_state = "driving"
	game.mode = "split"
	game.ui.set_mode("split")
	game.ui.show_menu(false)
	game.ui.toggle_map()
	Input.action_press("look_back")
	game.camera_initialized = false
	game._process(1.0 / 60.0)
	check(game.looking_back and not game.ui.map_open and (-game.navigator_camera.global_basis.z).dot(car.global_basis.z) > 0.9, "holding look-back folds the map and turns the passenger's view behind")
	check((-game.driver_camera.global_basis.z).dot(-car.global_basis.z) > 0.9, "navigator look-back leaves the driver's camera facing forward")
	check(game.ui.driver_mirror_frame.visible and game.ui.navigator_mirror_frame.visible and game.ui.driver_mirror.material == game.blur_material and game.ui.navigator_mirror.material == null, "both seats retain a small live mirror with driver blur and a clear navigator view")
	check((-game.mirror_camera.global_basis.z).dot(car.global_basis.z) > 0.9 and game.ui.navigator_mirror.flip_h, "live mirror camera faces backward and reflects horizontally")
	Input.action_release("look_back")
	game.camera_initialized = false
	game._process(1.0 / 60.0)
	check(not game.looking_back, "releasing the button restores the normal passenger view")
	game.mode = "host"
	game.ui.set_mode("host")
	Input.action_press("look_back")
	game._process(1.0 / 60.0)
	check(not game.looking_back and not game.ui.rear_button.visible, "driver cannot activate the navigator's full rear view")
	Input.action_release("look_back")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
