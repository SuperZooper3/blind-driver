extends Node3D

const World = preload("res://scripts/procedural_world.gd")
const Car = preload("res://scripts/car.gd")
const UI = preload("res://scripts/game_ui.gd")
const Audio = preload("res://scripts/engine_audio.gd")
const Session = preload("res://scripts/session.gd")
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

func _ready() -> void:
	_setup_input()
	_setup_environment()
	world = World.new()
	world.name = "World"
	add_child(world)
	car = Car.new()
	car.name = "Car"
	car.position = Vector3(0, World.height_at(0, 12) + 1.1, 12)
	add_child(car)
	driver_view = _make_view("DriverView")
	navigator_view = _make_view("NavigatorView")
	driver_camera = _make_camera(driver_view)
	navigator_camera = _make_camera(navigator_view)
	ui = UI.new()
	add_child(ui)
	ui.driver_screen.texture = driver_view.get_texture()
	ui.navigator_screen.texture = navigator_view.get_texture()
	blur_material = ShaderMaterial.new()
	blur_material.shader = preload("res://shaders/driver_blur.gdshader")
	ui.driver_screen.material = blur_material
	ui.blur_slider.value_changed.connect(func(value: float): blur_material.set_shader_parameter("blur_amount", value))
	ui.map.world = world
	ui.map.car = car
	ui.play_requested.connect(_start)
	ui.resume_requested.connect(_resume)
	ui.recover_requested.connect(_recover)
	ui.host_requested.connect(_host)
	ui.connect_requested.connect(_join)
	ui.show_menu(true, false)
	motor = Audio.new()
	motor.car = car
	add_child(motor)
	session = Session.new()
	session.name = "Session"
	session.car = car
	session.world = world
	add_child(session)
	session.status_changed.connect(func(message: String): ui.status_label.text = message)
	session.connection_lost.connect(func(): car.driving_enabled = false)
	get_viewport().size_changed.connect(_resize_views)
	_resize_views()
	# Useful for opening two local instances without clicking through the menus.
	for argument in OS.get_cmdline_user_args():
		if argument == "--host":
			_host()
		elif argument.begins_with("--join="):
			_join(argument.trim_prefix("--join="))
		elif argument == "--solo":
			_start("solo")
		elif argument == "--split":
			_start("split")

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
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color("b7c7b1")
	env.fog_density = 0.0035
	var environment := WorldEnvironment.new()
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, -35, 0)
	sun.light_color = Color("ffe0ad")
	sun.light_energy = 0.95
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
	var size := get_viewport().get_visible_rect().size
	var width := size.x * 0.5 if mode == "split" and not ui.in_menu else size.x
	# Low resolution plus the blur pass makes the driver's vision genuinely unreadable.
	driver_view.size = Vector2i(maxi(64, int(width / 5.0)), maxi(64, int((size.y - 172) / 5.0)))
	navigator_view.size = Vector2i(int(width), maxi(64, int(size.y - 172)))

func _process(delta: float) -> void:
	world.focus = car.global_position
	_update_cameras(delta)
	motor.enabled = started and not audio_muted and not ui.in_menu
	ui.speed_label.text = "%02d" % roundi(absf(car.signed_speed) * 3.6)
	ui.distance_label.text = "%.2f\nKILOMETERS" % (car.distance_driven / 1000.0)
	ui.surface_label.text = "GRAVEL" if car.on_road else "OFF ROAD"
	if car.grounded_wheels == 0 and started:
		ui.surface_label.text = "AIRBORNE"
	route_timer += delta
	if route_timer > 0.25:
		route_timer = 0.0
		_update_route()
		car.on_road = world.road_distance(car.global_position) < 4.6
	if car.global_position.y < -35:
		_recover()
	ui.hint_label.text = "UPSIDE DOWN?  Press R to recover." if car.global_basis.y.dot(Vector3.UP) < 0.35 else ""

func _update_cameras(delta: float) -> void:
	var car_basis := car.global_basis.orthonormalized()
	var flat_forward := -car_basis.z
	flat_forward.y = 0.0
	flat_forward = flat_forward.normalized()
	var stable := Basis.looking_at(flat_forward)
	var seat_basis := stable.slerp(car_basis, 0.35)
	var driver_target := Transform3D(seat_basis, car.global_transform * Vector3(-0.43, 1.23, -0.05))
	var nav_target := Transform3D(seat_basis, car.global_transform * Vector3(0.43, 1.23, -0.05))
	var chase: bool = ui.in_menu or chase_camera
	navigator_camera.cull_mask = 3 if chase else 1
	if chase:
		var offset := Vector3(5.8, 3.8, 7.0) if ui.in_menu else Vector3(0, 3.5, 7.8)
		var target_position := car.global_position + stable * offset
		var ground: float = World.height_at(target_position.x, target_position.z)
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
	var nearest: Dictionary = {}
	var distance := INF
	for road: Dictionary in world.roads:
		if int(road.depth) % 2 != 0:
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
	var left: bool = int(nearest.id) % 2 == 0
	ui.route_label.text = "↖  Take the left fork" if left else "Take the right fork  ↗"
	ui.route_distance.text = "%d m to junction   /   M to unfold map" % (roundi(distance / 5.0) * 5)
	var children: Array[Dictionary] = []
	for road: Dictionary in world.roads:
		if int(road.parent) == int(nearest.id) and int(road.depth) > int(nearest.depth):
			children.append(road)
	ui.map.route_id = int(children[0 if left else 1].id) if children.size() >= 2 else -1

func _start(value: String) -> void:
	session.stop()
	mode = value
	chase_camera = mode == "solo"
	started = true
	car.driving_enabled = true
	ui.set_mode(mode)
	ui.show_menu(false)
	_resize_views()

func _resume() -> void:
	ui.show_menu(false)
	car.driving_enabled = mode != "join"
	_resize_views()

func _recover() -> void:
	if mode == "join":
		return
	var road: Dictionary = world.nearest_road(car.global_position)
	car.recover(road.point, road.direction)
	camera_initialized = false

func _host() -> void:
	mode = "host"
	ui.set_mode(mode)
	if session.host() != OK:
		return
	started = true
	car.driving_enabled = true
	chase_camera = false
	ui.show_menu(false)
	ui.status_label.text = "DRIVER / HOSTING ON PORT %d" % session.PORT
	_resize_views()

func _join(address: String) -> void:
	mode = "join"
	ui.set_mode(mode)
	if session.join(address) != OK:
		return
	started = true
	car.driving_enabled = false
	chase_camera = false
	ui.show_menu(false)
	_resize_views()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu") and started:
		ui.show_menu(not ui.in_menu)
		car.driving_enabled = not ui.in_menu and mode != "join"
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
	if event.is_action_pressed("recover"):
		_recover()
	if event.is_action_pressed("lights"):
		car.toggle_lights()
	if event.is_action_pressed("mute"):
		audio_muted = not audio_muted

func _setup_input() -> void:
	var bindings := {"accelerate": [KEY_W, KEY_UP], "reverse": [KEY_S, KEY_DOWN], "steer_left": [KEY_A, KEY_LEFT], "steer_right": [KEY_D, KEY_RIGHT], "handbrake": [KEY_SPACE], "map": [KEY_M, KEY_TAB], "camera": [KEY_C], "recover": [KEY_R], "menu": [KEY_ESCAPE], "lights": [KEY_H], "fullscreen": [KEY_F], "mute": [KEY_V]}
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
	for entry: Array in [["handbrake", JOY_BUTTON_A], ["map", JOY_BUTTON_Y], ["recover", JOY_BUTTON_BACK], ["menu", JOY_BUTTON_START]]:
		var input := InputEventJoypadButton.new()
		input.button_index = entry[1]
		InputMap.action_add_event(entry[0], input)
