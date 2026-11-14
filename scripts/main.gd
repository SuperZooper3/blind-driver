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
var ai_navigator: Node
var impact_audio: Node
var radio: Node
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
var navigator_seat: RemoteTransform3D
var motor: AudioStreamPlayer
var mode := "split"
var started := false
var chase_camera := false
var camera_initialized := false
var driver_base := Transform3D.IDENTITY
var navigator_base := Transform3D.IDENTITY
var chase_offset := Vector3.ZERO
var shake := 0.0
var shake_time := 0.0
var route_timer := 0.0
var blur_material: ShaderMaterial
var session: Node
var audio_muted := false
var local_navigator_pid := -1
var local_pair_deadline := 0
var input_ready := false
var repair_notice := ""
## The bank-robbery opening plays for each new ride. Headless
## test runs skip it unless a test turns it on.
const BankIntro = preload("res://scripts/bank_intro.gd")
var intro_enabled := DisplayServer.get_name() != "headless"
var intro_run_id := -1
var intro_clear := false
var intro: Node3D
var repair_notice_time := 0.0
var seasonal_environment: Environment
var seasonal_sky: ProceduralSkyMaterial
var seasonal_sun: DirectionalLight3D
var environment_season := -1

func _ready() -> void:
	ai_options = AICapture.read_options()
	if not ai_options.is_empty():
		Engine.time_scale = float(ai_options.speed_percent) / 100.0
		if ai_options.get("shared_screens", false):
			# Render two full 1280x800 seats regardless of the physical window size.
			get_window().content_scale_size = Vector2i(2560, 800)
			get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
			get_window().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
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
	# The camera must remain inside its SubViewport. This car-mounted seat pushes
	# its exact pose there, even when the network moves the car later in the frame.
	navigator_seat = RemoteTransform3D.new()
	navigator_seat.name = "NavigatorSeat"
	navigator_seat.update_scale = false
	car.add_child(navigator_seat)
	# Each seat sees the other occupant in its peripheral view, never its own head.
	driver_camera.cull_mask = 1 | Car.NAVIGATOR_BODY_LAYER
	ui = UI.new()
	ui.readable_ui = bool(ai_options.get("readable_ui", false))
	ui.complete_seats = bool(ai_options.get("shared_screens", false))
	ui.readable_game = self
	add_child(ui)
	ui.driver_screen.texture = driver_view.get_texture()
	ui.navigator_screen.texture = navigator_view.get_texture()
	blur_material = ShaderMaterial.new()
	blur_material.shader = preload("res://shaders/driver_blur.gdshader")
	ui.driver_screen.material = blur_material
	ui.blur_slider.value_changed.connect(func(value: float): blur_material.set_shader_parameter("blur_amount", value))
	blur_material.set_shader_parameter("blur_amount", ui.blur_slider.value)
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
	car.impacted.connect(_on_car_impact)
	car.tire_popped.connect(impact_audio.pop)
	radio = preload("res://scripts/driving_radio.gd").new()
	add_child(radio)
	car.impacted.connect(radio.crash)
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
		if not UI.SHOW_P2P_UI:
			return
		if not session.peer_link_address().is_empty():
			ui.status_label.text = "DIRECT LINK   /   " + session.peer_link_address().to_upper()
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
	ai_navigator = preload("res://scripts/ai_navigator.gd").new()
	ai_navigator.game = self
	add_child(ai_navigator)
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
		elif argument == "--ai":
			_start("ai")
		elif argument == "--solo":
			_start("solo")
		elif argument == "--split":
			_start("split")
		elif argument.begins_with("--room="):
			_join_from_invite(argument.trim_prefix("--room="))
	# Browser invite links: https://…/?room=K7Q4MZ joins that room straight away.
	if OS.has_feature("web"):
		var invited: Variant = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('room') || ''")
		if JavaScriptBridge.eval("window.BLIND_DRIVER_START_AI === true"):
			_start("ai")
		elif invited is String and not invited.is_empty():
			_join_from_invite(invited)
	if not ai_options.is_empty():
		ai_capture = AICapture.new()
		ai_capture.game = self
		ai_capture.options = ai_options
		add_child(ai_capture)
		if ai_options.get("shared_screens", false):
			var navigator_capture := AICapture.new()
			navigator_capture.game = self
			navigator_capture.options = ai_options.duplicate(true)
			navigator_capture.options.role = "navigator"
			navigator_capture.options.directory = ai_options.navigator_directory
			navigator_capture.leader = ai_capture
			ai_capture.peer = navigator_capture
			add_child(navigator_capture)
	input_ready = true

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
	seasonal_environment = env
	seasonal_sky = sky_material
	seasonal_sun = sun
	_apply_season_environment(0)

func _apply_season_environment(stage: int, delta: float = 0.0) -> void:
	var weight := 1.0 if environment_season < 0 or delta <= 0.0 else 1.0 - exp(-delta * 0.35)
	environment_season = stage
	var palette: Dictionary = World.Seasons.PALETTES[stage]
	seasonal_sky.sky_top_color = seasonal_sky.sky_top_color.lerp(Color(palette.sky), weight)
	seasonal_sky.sky_horizon_color = seasonal_sky.sky_horizon_color.lerp(Color(palette.horizon), weight)
	seasonal_sky.ground_horizon_color = seasonal_sky.ground_horizon_color.lerp(Color(palette.horizon), weight)
	seasonal_sky.ground_bottom_color = seasonal_sky.ground_bottom_color.lerp(Color(palette.ground_low), weight)
	seasonal_environment.fog_light_color = seasonal_environment.fog_light_color.lerp(Color(palette.fog), weight)
	seasonal_sun.light_color = seasonal_sun.light_color.lerp(Color(palette.sun), weight)

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
	camera.fov = 60.0 if ai_options.get("readable_ui", false) else 80.0
	camera.near = 0.07
	camera.far = 650.0
	camera.current = true
	camera.cull_mask = 1
	view.add_child(camera)
	return camera

func _resize_views() -> void:
	driver_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if ui.driver_screen.visible else SubViewport.UPDATE_DISABLED
	navigator_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if ui.navigator_screen.visible or mode == "ai" else SubViewport.UPDATE_DISABLED
	var size := get_viewport().get_visible_rect().size
	var width := size.x * 0.5 if mode == "split" and not ui.in_menu else size.x
	var view_height: float = size.y - 78 - (0 if ui.in_menu else UI.FOOTER_HEIGHT)
	if (ui.readable_ui or ui.complete_seats) and not ui.in_menu:
		view_height = size.y - 72 - 170
	# Low resolution plus the blur pass makes the driver's vision genuinely unreadable.
	var divisor := 1.0 if intro_clear else 5.0
	driver_view.size = Vector2i(maxi(64, int(width / divisor)), maxi(64, int(view_height / divisor)))
	navigator_view.size = Vector2i(768, 480) if mode == "ai" and not ui.in_menu else Vector2i(int(width), maxi(64, int(view_height)))

func _process(delta: float) -> void:
	world.focus = car.global_position
	# Distance is already replicated to both seats, including reconnects and resets.
	var season := 0 if world.basic_course else World.heat_for_distance(car.distance_driven)
	world.set_season(season)
	var region: int = world.season_at(car.global_position)
	_apply_season_environment(region, delta)
	looking_back = mode not in ["host", "ai"] and not ui.in_menu and car.run_state == "driving" and (Input.is_action_pressed("look_back") or ui.rear_button_held)
	if looking_back and ui.map_open:
		ui.close_map()
	_update_intro()
	var heat_active: bool = started and not ui.in_menu and not intro_playing() and not session.recovering and not session.stale and not car.reset_pending and car.recovery_grace == 0 and car.run_state == "driving"
	# A joining navigator needs both the driver's position and region map first.
	heat_active = heat_active and (not car.remote or (session.graph_received and session.snapshots_received > 0))
	ui.update_heat(season, region, car.run_id, heat_active, world.basic_course, delta)
	_update_cameras(delta)
	ui.update_pursuit(police, looking_back, car.run_state == "driving")
	if world.basic_course:
		ui.pursuit_title.text = "PRACTICE COURSE"
		ui.pursuit_detail.text = "No pursuit / static obstacles"
	siren.enabled = started and not audio_muted and not ui.in_menu and car.run_state == "driving" and not session.recovering and not session.stale and session.role != "disconnected"
	motor.enabled = started and not audio_muted and not ui.in_menu and not intro_playing() and car.run_state == "driving" and not session.recovering and not session.stale
	_publish_browser_status(delta)
	impact_audio.enabled = started and not audio_muted
	_update_radio(delta)
	if mode == "ai":
		car.driving_enabled = not ui.in_menu and car.run_state == "driving" and ai_navigator.ready_to_drive
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
	repair_notice_time = maxf(0.0, repair_notice_time - delta)
	ui.update_repairs(car, started)
	if car.repairing and car.repair_part != -1 and car.run_state == "driving":
		ui.surface_label.text = "REPAIRING / CAN'T DRIVE"
	elif repair_notice_time > 0.0:
		ui.surface_label.text = repair_notice
	ui.damage_label.text = car.damage.summary() if started else ""
	motor.roughness = car.damage.engine_roughness()

func _update_radio(delta: float) -> void:
	var available: bool = started and not intro_playing() and not ui.in_menu and not session.recovering and not session.stale and session.role != "disconnected" and not car.reset_pending and car.recovery_grace == 0
	if mode == "ai":
		available = available and ai_navigator.ready_to_drive
	if ai_capture != null:
		available = available and ai_capture.active
	radio.update(delta, car.run_id, available, car.run_state == "driving", car.signed_speed, car.damage.health, audio_muted)

func _physics_process(delta: float) -> void:
	# The navigator holds R. On one computer either seat's keyboard can; online,
	# the navigator's game relays the hold to the driver's.
	var holding: bool = Input.is_action_pressed("repair") and input_ready and not ui.in_menu
	session.repair_held_local = holding and mode == "join"
	car.repair_held = session.partner_repairing() if mode == "host" else (holding and mode != "join")
	if not car.remote:
		world.difficulty = 0 if world.basic_course else World.heat_for_distance(car.distance_driven)
		var running: bool = started and not intro_playing() and not ui.in_menu and car.run_state == "driving" and not car.reset_pending and car.recovery_grace == 0 and session.can_drive()
		if mode == "ai":
			running = running and ai_navigator.ready_to_drive
		if ai_capture != null:
			running = running and ai_capture.active
		if running:
			world.set_challenge_time(world.challenge_time + delta)
			world.assist_jump(car)
		police.advance(delta, running and not world.basic_course)
	if not started or car.remote or car.reset_pending or car.recovery_grace > 0:
		return
	if ai_capture != null and not ai_capture.active:
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
		var spikes: int = world.spike_mask(car)
		for wheel in 4:
			if spikes & (1 << wheel):
				car.damage.wear_tire(wheel, 1.0)
		# The practice course has no police to catch a crippled car. Exhausting
		# all four tires in its roadside thorns is therefore a terminal failure.
		if world.basic_course and car.punctured_tires == 15:
			car.finish_run("Thorns destroyed all four tires")
		# Police never follow into the forest, so a wreck limping there must still end.
		# Three broken tires, or a blown engine with two, leave the car undriveable
		# there. On the road (after spikes, say) it limps on until the police arrive.
		elif not world.basic_course and car.damage.broken_tires() >= 3 and world.thorn_at(car.global_position):
			car.finish_run("Your car broke down on shredded tires")
		elif not world.basic_course and car.damage.broken_tires() >= 2 and not car.damage.alive(car.damage.ENGINE) and world.thorn_at(car.global_position):
			car.finish_run("Your car broke down: blown engine and flat tires")
	if car.global_position.y < -55.0 and car.run_state != "game_over":
		car.begin_fall("You fell into the valley")
		car.finish_run()

func _restart_run() -> void:
	if mode == "join":
		return
	_clear_intro()
	intro_run_id = -1
	if ai_navigator != null:
		ai_navigator.reset()
	records.observe(car.distance_driven)
	records.save_record()
	records.begin_run()
	world.reset_world()
	police.reset()
	car.run_id += 1
	radio.reset(car.run_id)
	car.punctured_tires = 0
	car.damage.reset()
	car.rollover_time = 0.0
	car.update_tire_visuals()
	car.run_state = "driving"
	car.crash_reason = ""
	car.distance_driven = 0.0
	car.recover(World.ground_point(0, 12, 0.17), Vector3.FORWARD)
	car.driving_enabled = not ui.in_menu and session.can_drive() and (mode != "ai" or ai_navigator.ready_to_drive)
	camera_initialized = false
	shake = 0.0
	ui.close_map()

func intro_playing() -> bool:
	return intro != null and not intro.finished()

func _clear_intro() -> void:
	if intro != null:
		remove_child(intro)
		intro.queue_free()
		intro = null
	car.intro_hold = false

func _set_intro_clear(clear_view: bool) -> void:
	if intro_clear == clear_view:
		return
	intro_clear = clear_view
	# Disabling the shader alone still leaves a pixelated low-resolution image.
	blur_material.set_shader_parameter("blind_strength", 0.0 if intro_clear else 1.0)
	_resize_views()

func _update_intro() -> void:
	var ready_for_intro: bool = started and not ui.in_menu and car.run_state == "driving" and not car.reset_pending and car.recovery_grace == 0
	# Wait for the driver's first snapshot before placing the navigator's opening.
	if car.remote:
		ready_for_intro = ready_for_intro and session.snapshots_received > 0
	if intro_enabled and intro_run_id != car.run_id and ready_for_intro:
		_clear_intro()
		intro_run_id = car.run_id
		# Rejoining an already moving ride must not put a bank around the car.
		if car.distance_driven > 1.0:
			_set_intro_clear(false)
			return
		# The opening ends in first person, even in solo's usual chase view.
		chase_camera = false
		intro = BankIntro.new()
		intro.name = "BankIntro"
		add_child(intro)
		var site: Vector3 = BankIntro.Site.CENTER
		intro.setup(car, World.height_at(site.x, site.z))
	car.intro_hold = intro_playing()
	_set_intro_clear(intro_playing())
	if intro != null:
		var watching: bool = not ui.in_menu and not session.recovering and not session.stale
		intro.set_process(watching)
		intro.bell.stream_paused = not watching or audio_muted
	# The bank stays put until the car has left it far behind.
	if intro != null and intro.done_with_sound() and car.global_position.distance_to(intro.get_node("Bank").global_position) > 200.0:
		_clear_intro()

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
	var navigator_local := Transform3D(Basis.IDENTITY, Vector3(0.43, 1.23, -0.05))
	var chase: bool = ui.in_menu or (chase_camera and not looking_back) or car.run_state != "driving"
	if looking_back:
		navigator_local = Transform3D(Basis(Vector3.UP, PI), Vector3(0.43, 1.30, 0.9))
	var nav_target := car.global_transform * navigator_local
	navigator_camera.cull_mask = (3 | Car.DRIVER_BODY_LAYER | Car.NAVIGATOR_BODY_LAYER) if chase else (1 | Car.DRIVER_BODY_LAYER)
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
		chase_offset = nav_target.origin - car.global_position
		driver_base = driver_target
		navigator_base = nav_target
	# The driver's view retains its head stabilization. The passenger shares the
	# car's full orientation: separately smoothing it makes the cabin swim around
	# the camera during turns, bumps, and network corrections. The chase view can
	# still ease its offset because it is outside the car.
	driver_base = Transform3D(driver_base.basis.slerp(driver_target.basis, weight).orthonormalized(), driver_target.origin)
	if chase:
		chase_offset = chase_offset.lerp(nav_target.origin - car.global_position, weight)
		navigator_base = Transform3D(navigator_base.basis.slerp(nav_target.basis, weight).orthonormalized(), car.global_position + chase_offset)
	else:
		chase_offset = nav_target.origin - car.global_position
		navigator_base = nav_target
	# Keep the seated passenger locked even during an impact. The driver's jolt
	# and external camera shake still settle within a second.
	shake = move_toward(shake, 0.0, delta * 1.6)
	shake_time += delta
	driver_camera.global_transform = driver_base * _shake_offset(0.0)
	var seated := not chase and not intro_playing()
	var seat_path := navigator_seat.get_path_to(navigator_camera) if seated else NodePath("")
	if navigator_seat.remote_path != seat_path:
		navigator_seat.remote_path = seat_path
	navigator_seat.transform = navigator_local
	navigator_camera.global_transform = navigator_base if seated else navigator_base * _shake_offset(7.3)
	navigator_camera.fov = 60.0 if ai_options.get("readable_ui", false) else 76.0
	if intro_playing():
		# Both seats watch the robbery from outside, then fly into their own view.
		driver_camera.global_transform = intro.shot(driver_camera.global_transform)
		navigator_camera.global_transform = intro.shot(navigator_camera.global_transform)
		driver_camera.cull_mask = 1 | 2 | Car.DRIVER_BODY_LAYER | Car.NAVIGATOR_BODY_LAYER
		navigator_camera.cull_mask = 1 | 2 | Car.DRIVER_BODY_LAYER | Car.NAVIGATOR_BODY_LAYER
	else:
		driver_camera.cull_mask = 1 | Car.NAVIGATOR_BODY_LAYER

func _on_car_impact(strength: float) -> void:
	# A 30 km/h knock gives a clear jolt; a head-on crash about 3 degrees.
	shake = maxf(shake, clampf(strength * 1.6, 0.0, 1.0))

func _shake_offset(seed: float) -> Transform3D:
	var amount := shake
	if amount <= 0.0001:
		return Transform3D.IDENTITY
	var t := shake_time * 31.0 + seed
	var turn := Vector3(sin(t * 1.13) + sin(t * 2.71) * 0.5, sin(t * 0.97 + 1.7) + sin(t * 2.31) * 0.5, sin(t * 1.41 + 0.6)) * 0.05 * amount
	var nudge := Vector3(sin(t * 1.9 + 2.2), sin(t * 2.3 + 0.4), 0.0) * 0.06 * amount
	return Transform3D(Basis.from_euler(turn), nudge)

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
	if ai_navigator != null:
		ai_navigator.reset()
	ui.close_map()
	mode = value
	chase_camera = mode == "solo"
	started = true
	if car.run_state == "game_over" or mode == "ai":
		_restart_run()
	car.driving_enabled = car.run_state == "driving" and mode != "ai"
	ui.set_mode(mode)
	ui.show_menu(false)
	_resize_views()

func _resume() -> void:
	ui.show_menu(false)
	car.driving_enabled = mode != "join" and session.can_drive() and (mode != "ai" or ai_navigator.ready_to_drive)
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

var _status_timer := 0.0
## Browser only: a small read-only status object (window.blindDriverStatus) so a
## page or a person in the developer console can see the connection at a glance.
func _publish_browser_status(delta: float) -> void:
	if not OS.has_feature("web"):
		return
	_status_timer += delta
	if _status_timer < 0.5:
		return
	_status_timer = 0.0
	var status := {"version": preload("res://scripts/version.gd").RELEASE, "prototype": preload("res://scripts/version.gd").PROTOTYPE, "mode": mode, "online": session.online,
		"seat": session.relay.seat_role, "room": session.relay.share_code, "link": "webrtc" if session.rtc.is_linked() else ("lan" if session.direct.is_linked() else "relay"),
		"direct_wanted": session.direct_wanted, "webrtc_available": session.rtc_available, "updates_received": session.snapshots_received,
		"direct_messages": session.rtc.received_count + session.direct.received_count, "webrtc": session.rtc.debug_state(), "run_state": car.run_state, "distance_m": snappedf(car.distance_driven, 0.1),
		"ai": {"thinking": ai_navigator.busy, "ready": ai_navigator.ready_to_drive, "latency_ms": ai_navigator.latency_ms, "error": ai_navigator.error_text, "request_started_ms": ai_navigator.sent_at}}
	JavaScriptBridge.eval("window.blindDriverStatus = %s;" % JSON.stringify(status), true)

## Warn when the two games are different builds: features and bugs will not match.
func _check_partner_build(build: int) -> void:
	var Version := preload("res://scripts/version.gd")
	if build == Version.PROTOTYPE:
		ui.version_label.text = "%s   ·   your partner is on the same version" % Version.label()
		return
	var theirs := "an older version (before version numbers)" if build < 0 else "build %d" % build
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
	# Building the world can dispatch window events before the UI/session exist.
	# Godot already reports this node ready while its _ready() is still running.
	if not input_ready:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F8:
		ui.toggle_diagnostics()
	if event.is_action_pressed("menu") and started:
		ui.show_menu(not ui.in_menu)
		car.driving_enabled = not ui.in_menu and mode != "join" and session.can_drive() and (mode != "ai" or ai_navigator.ready_to_drive)
		_resize_views()
	if event.is_action_pressed("fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	if ui.in_menu:
		return
	if event.is_action_pressed("map"):
		ui.toggle_map()
	if event.is_action_pressed("camera") and mode != "ai":
		chase_camera = not chase_camera
	if event.is_action_pressed("lights") and mode != "join":
		car.toggle_lights()
	# The navigator repairs. Online, the driver's R does nothing.
	if event.is_action_pressed("repair") and mode != "host":
		var refusal: String = car.repair_refusal()
		var notices := {"too_fast": "DRIVER: SLOW BELOW 15 KM/H TO REPAIR", "nothing": "NOTHING TO REPAIR"}
		if notices.has(refusal):
			repair_notice = notices[refusal]
			repair_notice_time = 2.0
	if event.is_action_pressed("mute"):
		audio_muted = not audio_muted

func _setup_input() -> void:
	var bindings := {"accelerate": [KEY_W, KEY_UP], "reverse": [KEY_S, KEY_DOWN], "steer_left": [KEY_A, KEY_LEFT], "steer_right": [KEY_D, KEY_RIGHT], "handbrake": [KEY_SPACE], "map": [KEY_M, KEY_TAB], "camera": [KEY_C], "look_back": [KEY_B], "menu": [KEY_ESCAPE], "lights": [KEY_H], "fullscreen": [KEY_F], "mute": [KEY_V], "repair": [KEY_R]}
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
