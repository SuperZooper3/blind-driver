extends SceneTree
const Wire = preload("res://scripts/wire_protocol.gd")
# A long, clear road isolates pursuit pacing from generated bends and obstacles.
class OpenRoad extends Node3D:
	var graph_revision := 0
	var target_road := 0
	var roads: Array[Dictionary] = [{"id": 0, "parent": 0, "points": PackedVector3Array([Vector3(0, 0, 150), Vector3(0, 0, -5850)]), "hazards": []}]
	func nearest_road(_at: Vector3) -> Dictionary:
		return {"road_id": target_road}
	func height_at(_x: float, _z: float) -> float:
		return 0.0
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
	check_rubberband(cop, car)
	check_capture_reach(cop, car)
	cop.world = world
	cop.reset()
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
	check_streamed_pursuit(cop, car, world)
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)

func check_rubberband(cop: Node3D, car: RigidBody3D) -> void:
	var road := OpenRoad.new()
	root.add_child(road)
	cop.world = road
	car.distance_driven = 0
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	var player_station: float = cop.station + 600.0
	cop.last_gap = 600.0
	var smooth_motion := true
	for i in 3600:
		player_station += 31.0 / 60.0
		car.global_position = cop._sample(0, player_station).point + Vector3.UP
		var previous: Vector3 = cop.global_position
		cop.advance(1.0 / 60.0, true)
		smooth_motion = smooth_motion and previous.distance_to(cop.global_position) <= 40.0 / 60.0 + 0.001
		if i == 599:
			check(cop.phase == "chasing" and cop.visible and cop.gap > 300 and cop.speed > 39, "a large lead triggers faster pursuit instead of ending the chase")
			var snapshot: Dictionary = cop.snapshot()
			var replica = load("res://scripts/police_pursuit.gd").new()
			root.add_child(replica)
			replica.apply_snapshot(snapshot, snapshot, 1)
			check(Wire._police_state(snapshot) and is_equal_approx(replica.speed, cop.speed) and is_equal_approx(replica.gap, cop.gap), "boosted pursuit stays within the shared protocol and shares its speed and gap")
			replica.queue_free()
	check(cop.gap < 300 and cop.closing_speed > 0.5 and smooth_motion, "rubberbanding reels in a fast driver continuously without jumping the patrol")
	var before_pause: Vector3 = cop.global_position
	var paused_gap: float = cop.gap
	tick(cop, 120, false)
	check(cop.global_position == before_pause and cop.gap == paused_gap and cop.siren_gain() == 0, "catch-up boost still pauses with menus or connection recovery")
	var early_speed := 0.0
	for late_run in [false, true]:
		cop.reset()
		cop.phase = "chasing"
		cop.elapsed = 7
		car.distance_driven = 2200 if late_run else 0
		for _i in 600:
			car.global_position = cop._sample(0, cop.station + 70.0).point + Vector3.UP
			cop.advance(1.0 / 60.0, true)
		if not late_run:
			early_speed = cop.speed
			check(is_equal_approx(early_speed, 25.0), "boost fades out nearby, preserving breathing room before capture")
	check(cop.speed > early_speed + 5, "distance progression still raises the patrol's normal cruising pace")
	# Enter a roadside obstacle at full boosted speed, with room to brake and dodge.
	car.distance_driven = 0
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	cop.speed = 40
	var obstacle_station: float = cop.station + 110
	var obstacle: Vector3 = cop._sample(0, obstacle_station).point
	road.roads[0].hazards = [{"kind": "rock", "position": obstacle}]
	road.graph_revision += 1
	var minimum_clearance := INF
	var slowed := false
	for _i in 600:
		car.global_position = cop._sample(0, cop.station + 350).point + Vector3.UP
		cop.advance(1.0 / 60.0, true)
		minimum_clearance = minf(minimum_clearance, Vector2(cop.global_position.x - obstacle.x, cop.global_position.z - obstacle.z).length())
		if absf(cop.station - obstacle_station) < 12:
			slowed = slowed or cop.speed <= 33
		if cop.station > obstacle_station + 12: break
	check(slowed and minimum_clearance > 2.2, "full catch-up speed brakes early enough to clear an obstacle")
	road.queue_free()

func check_capture_reach(cop: Node3D, car: RigidBody3D) -> void:
	var road := OpenRoad.new()
	root.add_child(road)
	cop.world = road
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	car.run_state = "driving"
	car.global_position = cop.global_position + Vector3(15, -12, 0)
	tick(cop, 180)
	check(cop.catch_time == 0 and car.run_state == "driving", "wider capture cannot reach a car down in a pit")
	car.global_position = cop.global_position + Vector3(15, 0, 0)
	tick(cop, 60)
	check(cop.catch_time > 0.9 and car.run_state == "driving", "shoulder capture still gives the driver time to escape")
	tick(cop, 60)
	check(cop.phase == "caught" and car.crash_reason.contains("police"), "police catch a car parked 15 m off the road without leaving the asphalt")
	# Two nearby branches can be physically close while far apart by road.
	road.roads = [
		{"id": 0, "parent": 0, "points": PackedVector3Array([Vector3(0, 0, 150), Vector3.ZERO]), "hazards": []},
		{"id": 1, "parent": 0, "points": PackedVector3Array([Vector3.ZERO, Vector3(-8, 0, -100)]), "hazards": []},
		{"id": 2, "parent": 0, "points": PackedVector3Array([Vector3.ZERO, Vector3(8, 0, -100)]), "hazards": []},
	]
	road.target_road = 2
	road.graph_revision += 1
	cop.reset()
	cop.phase = "chasing"
	cop.elapsed = 7
	cop.road_id = 1
	cop.station = 80
	cop._place(1, 1)
	car.run_state = "driving"
	car.global_position = cop._sample(2, 80).point + Vector3.UP
	check(cop.global_position.distance_to(car.global_position) < 24, "separate-branch check starts inside the wider physical radius")
	tick(cop, 120)
	check(cop.catch_time == 0 and car.run_state == "driving", "nearby separate branches cannot capture through the forest")
	road.roads.remove_at(0)
	road.graph_revision += 1
	cop._sync_roads()
	cop.station = 80
	cop.speed = 0
	cop._place(1, 1)
	tick(cop, 120)
	check(cop.catch_time == 0 and car.run_state == "driving", "streaming out a shared ancestor cannot create a capture across disconnected branches")
	road.queue_free()

func check_streamed_pursuit(cop: Node3D, car: RigidBody3D, world: Node3D) -> void:
	cop.reset()
	car.distance_driven = 0
	car.run_state = "driving"
	var road_id: int = world.roads[0].id
	var station := 138.0
	var peak_gap := 0.0
	# Follow the generated safe route at a brisk sustained speed, including all
	# bends/obstacles and enough streaming to discard the starting road.
	for i in 7200:
		station += 31.0 / 60.0
		car.distance_driven += 31.0 / 60.0
		if station > cop.cache[road_id].length:
			station -= cop.cache[road_id].length
			for record: Dictionary in world.roads:
				if record.parent == road_id and record.id != road_id and not record.danger:
					road_id = record.id
					break
		car.global_position = cop._sample(road_id, station).point + Vector3.UP
		if i % 30 == 0: world.grow_near(car.global_position)
		cop.advance(1.0 / 60.0, true)
		peak_gap = maxf(peak_gap, cop.gap)
		if cop.phase in ["caught", "escaped"]: break
	check(car.distance_driven > 3500 and cop.phase == "chasing" and cop.gap < 260 and peak_gap - cop.gap > 70, "rubberbanding regains ground through kilometers of generated bends and obstacles")
