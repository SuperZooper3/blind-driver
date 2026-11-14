extends Node3D

const World = preload("res://scripts/procedural_world.gd")
const Car = preload("res://scripts/car.gd")
const UI = preload("res://scripts/game_ui.gd")
const Audio = preload("res://scripts/engine_audio.gd")
const Session = preload("res://scripts/session.gd")
const Pursuit = preload("res://scripts/police_pursuit.gd")
const Siren = preload("res://scripts/police_siren.gd")
const ImpactAudio = preload("res://scripts/impact_audio.gd")
const AICapture = preload("res://scripts/ai_capture.gd")
var ai_options: Dictionary = {}
var ai_capture: Node
var impact_audio: Node
var police: Node3D
var siren: AudioStreamPlayer
var looking_back := false
const Records = preload("res://scripts/run_records.gd")
var records := Records.new()
var record_timer := 0.0
var record_run_id := -1
var world: Node3D
var car: RigidBody3D
var ui: CanvasLayer
var driver_view: SubViewport
var navigator_view: SubViewport
var driver_camera: Camera3D
var navigator_camera: Camera3D
var motor: AudioStreamPlayer
var mode := "split"
var started := false
var chase_camera := false
var camera_initialized := false
var route_timer := 0.0
var blur_material: ShaderMaterial
var session: Node
var audio_muted := false
var local_navigator_pid := -1
var local_pair_deadline := 0

func _ready() -> void:
	ai_options = AICapture.read_options()
	if not ai_options.is_empty():
		Engine.time_scale = float(ai_options.speed_percent) / 100.0
	records.load_record()
	_setup_input()
	_setup_environment()
	world = World.new()
	world.basic_course = ai_options.get("course", "standard") == "basic"
	world.world_seed = int(ai_options.get("seed", world.world_seed))
	world.name = "World"
	add_child(world)
	car = Car.new()
	car.name = "Car"
	car.position = Vector3(0, World.height_at(0, 12) + 1.1, 12)
	add_child(car)
	police = Pursuit.new()
	police.name = "Police"
	police.car = car
	police.world = world
	add_child(police)
	police.reset()
	police.visible = not world.basic_course
	driver_view = _make_view("DriverView")
	navigator_view = _make_view("NavigatorView")
	driver_camera = _make_camera(driver_view)
	navigator_camera = _make_camera(navigator_view)
	ui = UI.new()
	add_child(ui)
	ui.driver_screen.texture = driver_view.get_texture()
	# Draw the driver's cracks inside their low-resolution view, so the blur pass
	# smears them along with the road.
	var driver_glass := CanvasLayer.new()
	driver_view.add_child(driver_glass)
	ui.driver_cracks.reparent(driver_glass, false)
	ui.driver_cracks.line_scale = 0.8
	ui.driver_cracks.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.navigator_screen.texture = navigator_view.get_texture()
	blur_material = ShaderMaterial.new()
	blur_material.shader = preload("res://shaders/driver_blur.gdshader")
	ui.driver_screen.material = blur_material
	ui.blur_slider.value_changed.connect(func(value: float): blur_material.set_shader_parameter("blur_amount", value))
	ui.map.world = world
	ui.map.car = car
	ui.play_requested.connect(_start)
	ui.resume_requested.connect(_resume)
	ui.restart_requested.connect(func():
		_restart_run()
		_resume())
	ui.host_requested.connect(_host)
	ui.connect_requested.connect(_join)
	ui.online_create_requested.connect(func(address: String, seat: String): _host_online(address, "", seat))
	ui.online_join_requested.connect(func(address: String, code: String): _join_online(address, code))
	ui.online_cancel_requested.connect(_leave_online)
	ui.show_menu(true, false)
	motor = Audio.new()
	motor.car = car
	add_child(motor)
	impact_audio = ImpactAudio.new()
	add_child(impact_audio)
	car.impacted.connect(impact_audio.crash)
	car.tire_popped.connect(impact_audio.pop)
	siren = Siren.new()
	siren.pursuit = police
	siren.car = car
	add_child(siren)
	session = Session.new()
	session.name = "Session"
	session.car = car
	session.world = world
	session.police = police
	add_child(session)
	session.status_changed.connect(func(message: String):
		ui.status_label.text = message
		if session.online and ui.in_menu:
			ui.online_status.text = message)
	session.connection_lost.connect(func(): car.driving_enabled = false)
	session.navigator_joined.connect(func():
		if session.online:
			_online_ready()
		car.driving_enabled = not ui.in_menu and session.can_drive())
	session.room_created.connect(ui.display_lobby_ready)
	session.seat_changed.connect(_apply_seat)
	session.relay.partner_build.connect(_check_partner_build)
	session.seats_swapped.connect(func(value: String):
		if value == "host":
			# The new driver owns the next ride: start it fresh for both players.
			_restart_run()
			_resume())
	ui.swap_requested.connect(func(): session.request_swap())
	ui.direct_toggled.connect(func(on: bool):
		if session.online and (session.navigator_id != 0 or session.role == "join"):
			session.set_direct(on))
	session.direct_status_changed.connect(func(text: String, wanted: bool):
		ui.set_direct_status(text, wanted)
		if session.direct.is_linked():
			ui.status_label.text = "DIRECT LINK   /   " + session.direct.partner_address()
		elif wanted:
			ui.status_label.text = "INTERNET RELAY   /   LOOKING FOR DIRECT LINK")
	session.online_joined.connect(_online_ready)
	session.ride_restored.connect(func(): car.driving_enabled = not ui.in_menu and session.can_drive())
	ui.network_session = session
	session.online_error.connect(func(message: String):
		ui.show_online()
		ui.set_online_busy(false)
		ui.online_status.text = message
		_resize_views())
	get_viewport().size_changed.connect(_resize_views)
	_resize_views()
	# Useful for opening two local instances without clicking through the menus.
	for argument in OS.get_cmdline_user_args():
		if argument == "--local-coop":
			_start_local_windows()
		elif argument == "--local-seat=navigator":
			_arrange_local_window(true)
		elif argument == "--host":
			_host("127.0.0.1" if not ai_options.is_empty() else "*")
		elif argument.begins_with("--join="):
			_join(argument.trim_prefix("--join="))
		elif argument == "--solo":
			_start("solo")
		elif argument == "--split":
			_start("split")
		elif argument.begins_with("--room="):
			_join_from_invite(argument.trim_prefix("--room="))
	# Browser invite links: https://…/?room=K7Q4MZ joins that room straight away.
	if OS.has_feature("web"):
		var invited: Variant = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('room') || ''")
		if invited is String and not invited.is_empty():
			_join_from_invite(invited)
	if not ai_options.is_empty():
		ai_capture = AICapture.new()
		ai_capture.game = self
		ai_capture.options = ai_options
		add_child(ai_capture)

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("779b9a")
	sky_material.sky_horizon_color = Color("d3d2ac")
	sky_material.ground_bottom_color = Color("566b54")
	sky_material.ground_horizon_color = Color("c6c9a6")
	sky_material.sky_curve = 0.22
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c5d6ca")
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = Color("b7c7b1")
	env.fog_density = 0.0035
	var environment := WorldEnvironment.new()
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, -35, 0)
	sun.light_color = Color("f8ecd5")
	sun.light_energy = 0.72
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 130.0
	add_child(sun)

func _make_view(view_name: String) -> SubViewport:
	var view := SubViewport.new()
	view.name = view_name
	view.world_3d = get_viewport().world_3d
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.msaa_3d = Viewport.MSAA_2X
	add_child(view)
	return view

func _make_camera(view: SubViewport) -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 80.0
	camera.near = 0.07
	camera.far = 650.0
	camera.current = true
	camera.cull_mask = 1
	view.add_child(camera)
	return camera

func _resize_views() -> void:
	driver_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if ui.driver_screen.visible else SubViewport.UPDATE_DISABLED
	navigator_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if ui.navigator_screen.visible else SubViewport.UPDATE_DISABLED
	var size := get_viewport().get_visible_rect().size
	var width := size.x * 0.5 if mode == "split" and not ui.in_menu else size.x
	# Low resolution plus the blur pass makes the driver's vision genuinely unreadable.
	driver_view.size = Vector2i(maxi(64, int(width / 5.0)), maxi(64, int((size.y - 78 - (0 if ui.in_menu else UI.FOOTER_HEIGHT)) / 5.0)))
	navigator_view.size = Vector2i(int(width), maxi(64, int(size.y - 78 - (0 if ui.in_menu else UI.FOOTER_HEIGHT))))

func _process(delta: float) -> void:
	world.focus = car.global_position
	looking_back = mode != "host" and not ui.in_menu and car.run_state == "driving" and (Input.is_action_pressed("look_back") or ui.rear_button_held)
	if looking_back and ui.map_open:
		ui.close_map()
	_update_cameras(delta)
	ui.update_pursuit(police, looking_back, car.run_state == "driving")
	if world.basic_course:
		ui.pursuit_title.text = "PRACTICE COURSE"
		ui.pursuit_detail.text = "No pursuit / static obstacles"
	siren.enabled = started and not audio_muted and not ui.in_menu and car.run_state == "driving" and not session.recovering and not session.stale and session.role != "disconnected"
	motor.enabled = started and not audio_muted and not ui.in_menu
	impact_audio.enabled = started and not audio_muted
	if ui.in_menu or car.run_state != "driving" or (session.online and not session.can_drive()):
		car.driving_enabled = false
	if local_navigator_pid > 0:
		_local_navigator_running()
	if local_pair_deadline > 0:
		if session.navigator_id != 0:
			local_pair_deadline = 0
		elif Time.get_ticks_msec() > local_pair_deadline:
			_close_local_navigator()
			ui.show_menu(true)
			ui.status_label.text = "NAVIGATOR DID NOT CONNECT / RETRY LOCAL CO-OP"
			_resize_views()
	if started:
		if record_run_id != car.run_id:
			records.begin_run()
			record_run_id = car.run_id
		records.observe(car.distance_driven)
		record_timer += delta
		if record_timer >= 5.0 or car.run_state == "game_over":
			records.save_record()
			record_timer = 0.0
	ui.personal_best_label.text = "PERSONAL BEST   %.2f km" % (records.best_distance / 1000.0)
	ui.dashboard.best_km = records.best_distance / 1000.0
	ui.dashboard.speed_kmh = absf(car.signed_speed) * 3.6
	ui.dashboard.distance_km = car.distance_driven / 1000.0
	ui.surface_label.text = "GRAVEL" if car.on_road else "OFF ROAD"
	ui.heat_label.text = "HEAT OFF" if world.basic_course else "HEAT %d / 5" % (World.heat_for_distance(car.distance_driven) + 1)
	ui.heat_label.modulate = Color("ef9364").lerp(Color("ef554a"), World.heat_for_distance(car.distance_driven) / 4.0)
	if car.grounded_wheels == 0 and started:
		ui.surface_label.text = "AIRBORNE"
	route_timer += delta
	if route_timer > 0.25:
		route_timer = 0.0
		_update_route()
		if not car.remote:
			car.on_road = world.road_distance(car.global_position) < 4.6
	ui.show_run_result(car.run_state, car.crash_reason, car.distance_driven, mode == "join", records.best_distance, records.new_best, session.can_swap())
	ui.hint_label.text = "Thorns tear your tires — stay near the road" if car.run_state == "driving" and world.road_distance(car.global_position) > 12.0 else ""
	if car.thorn_contact != 0 and car.run_state == "driving":
		ui.surface_label.text = "THORNS / TIRES TEARING"
	elif car.punctured_tires != 0:
		ui.surface_label.text = "FLAT TIRE" if car.run_state == "driving" else "TIRES PUNCTURED"
	elif not car.damage.alive(car.damage.ENGINE) and car.run_state == "driving":
		ui.surface_label.text = "ENGINE WRECKED"
	ui.damage_label.text = car.damage.summary() if started else ""
	ui.set_windshield_crack(car.damage.windshield_crack(), ui.in_menu or chase_camera)
	motor.roughness = car.damage.engine_roughness()

func _physics_process(delta: float) -> void:
	if not car.remote:
		world.difficulty = 0 if world.basic_course else World.heat_for_distance(car.distance_driven)
		var running: bool = started and not ui.in_menu and car.run_state == "driving" and not car.reset_pending and car.recovery_grace == 0 and session.can_drive()
		if ai_capture != null:
			running = running and ai_capture.active
		if running:
			world.set_challenge_time(world.challenge_time + delta)
			world.assist_jump(car)
		police.advance(delta, running and not world.basic_course)
	if not started or car.remote or car.reset_pending or car.recovery_grace > 0:
		return
	var hole: Dictionary = world.void_at(car.global_position)
	if not hole.is_empty():
		var rim: float = hole.position.y + hole.size.y
		if car.global_position.y < rim - 1.5:
			var reasons := {"cliff": "The road ended at a cliff", "lake": "You plunged into the lake", "jump_gap": "You didn't clear the jump", "timed_bridge": "You missed the timed bridge"}
			car.begin_fall(reasons[hole.kind])
		if car.run_state == "falling" and (car.global_position.y < hole.position.y + 2.5 or (hole.kind == "lake" and car.global_position.y < rim - 3.0)):
			car.finish_run()
	if car.run_state == "driving":
		car.check_rollover(delta)
		car.wear_tires(world.puncture_mask(car), delta)
	if car.global_position.y < -55.0 and car.run_state != "game_over":
		car.begin_fall("You fell into the valley")
		car.finish_run()

func _restart_run() -> void:
	if mode == "join":
		return
	records.observe(car.distance_driven)
	records.save_record()
	records.begin_run()
	world.reset_world()
	police.reset()
	car.run_id += 1
	car.punctured_tires = 0
	car.damage.reset()
	car.rollover_time = 0.0
	car.update_tire_visuals()
	car.run_state = "driving"
	car.crash_reason = ""
	car.distance_driven = 0.0
	car.recover(World.ground_point(0, 12, 0.17), Vector3.FORWARD)
	car.driving_enabled = not ui.in_menu and session.can_drive()
	camera_initialized = false
	ui.close_map()

func _update_cameras(delta: float) -> void:
	var car_basis := car.global_basis.orthonormalized()
	var flat_forward := -car_basis.z
	flat_forward.y = 0.0
	if flat_forward.length_squared() < 0.001:
		flat_forward = Vector3.FORWARD
	flat_forward = flat_forward.normalized()
	var stable := Basis.looking_at(flat_forward)
	var seat_basis := stable.slerp(car_basis, 0.35)
	var driver_target := Transform3D(seat_basis, car.global_transform * Vector3(-0.43, 1.23, -0.05))
	var nav_target := Transform3D(seat_basis, car.global_transform * Vector3(0.43, 1.23, -0.05))
	var chase: bool = ui.in_menu or (chase_camera and not looking_back) or car.run_state != "driving"
	if looking_back:
		nav_target.basis = seat_basis * Basis(Vector3.UP, PI)
		nav_target.origin = car.global_transform * Vector3(0.43, 1.30, 0.9)
	navigator_camera.cull_mask = 3 if chase else 1
	if chase:
		var offset := Vector3(5.8, 3.8, 7.0) if ui.in_menu else Vector3(0, 3.5, 7.8)
		var target_position := car.global_position + stable * offset
		var ground: float = world.surface_height(target_position)
		target_position.y = maxf(target_position.y, ground + 1.4)
		nav_target = Transform3D(Basis.looking_at(car.global_position + Vector3.UP * 0.7 - target_position), target_position)
	var weight := 1.0 - exp(-delta * (7.0 if chase else 18.0))
	if not camera_initialized:
		weight = 1.0
		camera_initialized = true
	driver_camera.global_transform = driver_camera.global_transform.interpolate_with(driver_target, weight)
	navigator_camera.global_transform = navigator_camera.global_transform.interpolate_with(nav_target, weight)
	navigator_camera.fov = lerpf(navigator_camera.fov, 76.0 + absf(car.signed_speed) * 0.24, delta * 2.0)

func _update_route() -> void:
	if world.basic_course:
		ui.route_label.text = "Follow the road"
		ui.route_distance.text = "Practice course / avoid the rocks"
		return
	# The navigator can read the approaching challenge while watching the road.
	for road: Dictionary in world.roads:
		for hazard: Dictionary in road.hazards:
			if not World.Challenge.is_challenge(hazard): continue
			var relative: Vector3 = hazard.position - car.global_position
			if relative.dot(-car.global_basis.z) < -12 or relative.length() > 100: continue
			if hazard.kind == "jump_gap":
				ui.route_label.text = "Jump gap ahead"
				ui.route_distance.text = "Line up on the ramp / 65+ km/h"
			else:
				var state := World.Challenge.bridge_state(hazard, world.challenge_time)
				ui.route_label.text = "Bridge closing" if state.warning else ("Bridge open" if state.open else "Wait for the bridge")
				ui.route_distance.text = ("Closes in %d s" if state.open else "Opens in %d s") % maxi(1, ceili(state.remaining))
			return
	var nearest: Dictionary = {}
	var distance := INF
	for road: Dictionary in world.roads:
		if road.danger or int(road.depth) % 2 != 0:
			continue
		var end: Vector3 = road.points[-1]
		var relative := end - car.global_position
		if relative.dot(-car.global_basis.z) < -12.0:
			continue
		var d := relative.length()
		if d < distance:
			distance = d
			nearest = road
	if nearest.is_empty():
		ui.route_label.text = "Follow the road"
		ui.route_distance.text = "The next fork is still ahead."
		return
	# Directions require consulting the sheet; the card never gives the answer away.
	var exits := 0
	for road: Dictionary in world.roads:
		if road.parent == nearest.id and road.id != nearest.id: exits += 1
	ui.route_label.text = "Three ways / check map" if exits >= 3 else "Fork ahead / check map"
	ui.route_distance.text = "%d m / compare routes and dead ends" % (roundi(distance / 5.0) * 5)

func _start(value: String) -> void:
	if value == "local_windows":
		_start_local_windows()
		return
	_close_local_navigator()
	session.stop()
	ui.set_online_busy(false)
	mode = value
	chase_camera = mode == "solo"
	started = true
	if car.run_state == "game_over":
		_restart_run()
	car.driving_enabled = car.run_state == "driving"
	ui.set_mode(mode)
	ui.show_menu(false)
	_resize_views()

func _resume() -> void:
	ui.show_menu(false)
	car.driving_enabled = mode != "join" and session.can_drive()
	_resize_views()

func _recover() -> void:
	if mode == "join" or car.run_state != "driving" or not world.void_at(car.global_position).is_empty():
		return
	var road: Dictionary = world.recovery_spot(car.global_position)
	car.recover(road.point, road.direction)
	camera_initialized = false

func _host(bind_address: String = "*") -> void:
	_close_local_navigator()
	ui.set_online_busy(false)
	mode = "host"
	ui.set_mode(mode)
	if session.host(bind_address) != OK:
		car.driving_enabled = false
		ui.show_menu(true)
		_resize_views()
		return
	started = true
	car.driving_enabled = true
	chase_camera = false
	ui.show_menu(false)
	ui.status_label.text = "DRIVER / HOSTING ON PORT %d" % session.port
	get_window().title = "Blind Driver — Driver"
	_resize_views()

func _join(address: String) -> void:
	_close_local_navigator()
	ui.set_online_busy(false)
	mode = "join"
	ui.set_mode(mode)
	if session.join(address) != OK:
		return
	started = true
	car.driving_enabled = false
	chase_camera = false
	ui.show_menu(false)
	get_window().title = "Blind Driver — Navigator"
	_resize_views()

func _start_local_windows() -> void:
	if OS.has_feature("web"):
		ui.status_label.text = "TWO WINDOWS NEEDS THE DESKTOP GAME / USE SHARED SCREEN"
		return
	if _local_navigator_running() and session.role == "host" and session.navigator_id != 0:
		_resume()
		return
	_host("127.0.0.1")
	if session.role != "host":
		return
	_arrange_local_window(false)
	car.driving_enabled = false
	var arguments := PackedStringArray()
	if OS.has_feature("editor"):
		arguments.append_array(["--path", ProjectSettings.globalize_path("res://")])
	if DisplayServer.get_name() == "headless":
		arguments.append("--headless")
	arguments.append_array(["--windowed", "--log-file", OS.get_user_data_dir().path_join("local-navigator.log"), "--", "--local-seat=navigator", "--join=127.0.0.1"])
	local_navigator_pid = OS.create_instance(arguments)
	if local_navigator_pid < 0:
		session.stop()
		ui.show_menu(true)
		ui.status_label.text = "COULD NOT OPEN NAVIGATOR / TRY MANUAL HOST AND JOIN"
	else:
		local_pair_deadline = Time.get_ticks_msec() + 15000
		ui.status_label.text = "LOCAL DRIVER / OPENING NAVIGATOR WINDOW"
	_resize_views()

func _arrange_local_window(navigator: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var window := get_window()
	window.content_scale_size = Vector2i(960, 720)
	if Engine.is_embedded_in_editor():
		return
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	window.mode = Window.MODE_WINDOWED
	window.min_size = Vector2i(480, 420)
	window.size = Vector2i(maxi(480, screen.size.x / 2 - 16), mini(820, screen.size.y - 56))
	window.position = screen.position + Vector2i(screen.size.x / 2 + 8 if navigator else 8, 28)
	_resize_views()

func _close_local_navigator() -> void:
	local_pair_deadline = 0
	if _local_navigator_running():
		OS.kill(local_navigator_pid)
	local_navigator_pid = -1

func _local_navigator_running() -> bool:
	if local_navigator_pid <= 0:
		return false
	if not OS.is_process_running(local_navigator_pid):
		local_navigator_pid = -1
		return false
	return true

func _exit_tree() -> void:
	records.save_record()
	_close_local_navigator()
	preload("res://scripts/network_log.gd").close()

func _host_online(address: String, lobby: String = "", seat: String = "driver") -> void:
	_close_local_navigator()
	car.driving_enabled = false
	chase_camera = false
	session.host_online(address, lobby, seat)
	_resize_views()

func _join_online(address: String, code: String = "", lobby: String = "") -> void:
	_close_local_navigator()
	car.driving_enabled = false
	chase_camera = false
	session.join_online(address, code, lobby)
	_resize_views()

func _join_from_invite(code: String) -> void:
	var short: String = session.relay.normalize_share(code)
	if short.is_empty():
		ui.online_status.text = "That invite code doesn't look right. Ask your friend for the 6-character code."
		return
	ui.room_code_field.text = short
	ui.connecting = true
	ui.set_online_busy(true)
	ui.online_status.text = "Joining room %s…" % short
	_join_online(ui.relay_address.text, short)

## Warn when the two games are different builds: features and bugs will not match.
func _check_partner_build(build: int) -> void:
	var Version := preload("res://scripts/version.gd")
	if build == Version.PROTOTYPE:
		ui.version_label.text = "%s   ·   your partner is on the same version" % Version.label()
		return
	var theirs := "an older version (before version numbers)" if build < 0 else "PROTOTYPE %02d" % build
	var message := "Your partner is on %s; you are on %s. Both of you should update to the latest version." % [theirs, Version.label()]
	ui.version_label.text = message
	ui.online_status.text = message
	ui.status_label.text = "VERSION MISMATCH   /   PARTNER %s" % ("OLD" if build < 0 else "%02d" % build)

## The relay decides who drives: follow it whenever our seat changes.
func _apply_seat(value: String) -> void:
	mode = value
	ui.set_mode(mode)
	chase_camera = false
	car.driving_enabled = false
	if session.online:
		get_window().title = "Blind Driver — " + ("Driver" if value == "host" else "Navigator")
	_resize_views()

func _online_ready() -> void:
	var first_connection: bool = not started or ui.connecting
	ui.connecting = false
	if ui.direct_toggle.button_pressed and not session.direct_wanted:
		session.set_direct(true)
	started = true
	if first_connection:
		ui.show_menu(false)
	car.driving_enabled = mode == "host" and session.can_drive()
	_resize_views()

func _leave_online() -> void:
	if session.online:
		session.stop()
		started = false
		mode = "split"
		ui.set_mode(mode)
		ui.online_status.text = "Create a room, or join a friend's with their code."
	ui.set_online_busy(false)
	ui.show_menu(true, started)
	car.driving_enabled = false
	_resize_views()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F8:
		ui.toggle_diagnostics()
	if event.is_action_pressed("menu") and started:
		ui.show_menu(not ui.in_menu)
		car.driving_enabled = not ui.in_menu and mode != "join" and session.can_drive()
		_resize_views()
	if event.is_action_pressed("fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	if ui.in_menu:
		return
	if event.is_action_pressed("map"):
		ui.toggle_map()
	if event.is_action_pressed("camera"):
		chase_camera = not chase_camera
	if event.is_action_pressed("lights") and mode != "join":
		car.toggle_lights()
	if event.is_action_pressed("mute"):
		audio_muted = not audio_muted

func _setup_input() -> void:
	var bindings := {"accelerate": [KEY_W, KEY_UP], "reverse": [KEY_S, KEY_DOWN], "steer_left": [KEY_A, KEY_LEFT], "steer_right": [KEY_D, KEY_RIGHT], "handbrake": [KEY_SPACE], "map": [KEY_M, KEY_TAB], "camera": [KEY_C], "look_back": [KEY_B], "menu": [KEY_ESCAPE], "lights": [KEY_H], "fullscreen": [KEY_F], "mute": [KEY_V]}
	for action: String in bindings:
		InputMap.add_action(action)
		for key: int in bindings[action]:
			var input := InputEventKey.new()
			input.physical_keycode = key
			InputMap.action_add_event(action, input)
	for entry: Array in [["accelerate", JOY_AXIS_TRIGGER_RIGHT, 1.0], ["reverse", JOY_AXIS_TRIGGER_LEFT, 1.0], ["steer_left", JOY_AXIS_LEFT_X, -1.0], ["steer_right", JOY_AXIS_LEFT_X, 1.0]]:
		var input := InputEventJoypadMotion.new()
		input.axis = entry[1]
		input.axis_value = entry[2]
		InputMap.action_add_event(entry[0], input)
	for entry: Array in [["handbrake", JOY_BUTTON_A], ["map", JOY_BUTTON_Y], ["look_back", JOY_BUTTON_RIGHT_SHOULDER], ["menu", JOY_BUTTON_START]]:
		var input := InputEventJoypadButton.new()
		input.button_index = entry[1]
		InputMap.action_add_event(entry[0], input)
