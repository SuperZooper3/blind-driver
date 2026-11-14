extends Node
## Human driver + continuous Cohere advice. Exactly one fresh observation in flight.
var game: Node
var request: HTTPRequest
var map_view: SubViewport
var panel: PanelContainer
var active := false
var busy := false
var ready_to_drive := false
var permanent_error := false
var epoch := 0
var run_id := -1
var sent_epoch := -1
var sent_at := 0
var observation_at := 0
var retry_at := 0
var latency_ms := 0
var instruction := ""
var error_text := ""
var endpoint := ""

func _ready() -> void:
	request = HTTPRequest.new()
	request.timeout = 65.0
	request.body_size_limit = 8192
	add_child(request)
	request.request_completed.connect(_completed)
	endpoint = OS.get_environment("BLIND_DRIVER_AI_URL")
	if endpoint.is_empty():
		endpoint = "http://127.0.0.1:8080/api/ai/navigate"
	if OS.has_feature("web"):
		endpoint = str(JavaScriptBridge.eval("window.location.origin + '/api/ai/navigate'"))
	# Render the navigator's familiar map offscreen, never exposing it to the driver.
	map_view = SubViewport.new()
	map_view.size = Vector2i(640, 480)
	map_view.disable_3d = true
	map_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(map_view)
	var map := preload("res://scripts/route_map.gd").new()
	map.world = game.world
	map.car = game.car
	map.unfolded = true
	map.size = Vector2(640, 480)
	map_view.add_child(map)
	panel = preload("res://scripts/ai_instruction.gd").new()
	game.ui.hud.add_child(panel)
	panel.hide()
	game.ui.root.resized.connect(_layout)
	_layout()

func _layout() -> void:
	panel.position = Vector2(18, 90)
	panel.size = Vector2(maxf(200, game.ui.root.size.x - 36), 0)

func is_running() -> bool:
	return game.mode == "ai" and game.started and not game.ui.in_menu and game.car.run_state == "driving"

func reset() -> void:
	epoch += 1
	request.cancel_request()
	active = false
	busy = false
	ready_to_drive = false
	permanent_error = false
	instruction = ""
	error_text = ""
	latency_ms = 0
	observation_at = 0
	retry_at = 0
	map_view.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _process(_delta: float) -> void:
	var running := is_running()
	panel.visible = game.mode == "ai" and not game.ui.in_menu
	if not running:
		if active:
			reset()
		panel.thinking = false
		panel.detail.text = "COHERE COMMAND A VISION · Ride ended"
		panel.instruction.text = "Start a new ride for fresh directions."
		return
	if not active or run_id != game.car.run_id:
		reset()
		active = true
		run_id = game.car.run_id
		map_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var now := Time.get_ticks_msec()
	if not busy and not permanent_error and now >= retry_at:
		_capture_and_request()
	panel.thinking = busy
	var latency := "Latest latency: —" if latency_ms == 0 else "Latest latency: %d ms" % latency_ms
	var state := "Thinking…" if busy else ""
	if not error_text.is_empty():
		state = error_text if permanent_error else ("Retrying… " + error_text if busy else "%s Retry in %d s" % [error_text, maxi(0, ceili((retry_at - now) / 1000.0))])
	var age := ""
	if observation_at > 0:
		age = " · View %.1f s old" % ((now - observation_at) / 1000.0)
		if now - observation_at > 5000:
			age += " · Advice is stale: slow down"
	panel.detail.text = "COHERE COMMAND A VISION · %s%s · %s" % [latency, age, state]
	panel.instruction.text = instruction if not instruction.is_empty() else (error_text if permanent_error else "Wait for your first direction. W / S to drive, A / D to steer.")
	# Fit wrapped text at small window sizes without covering the dashboard.
	panel.size.y = 0

func _capture_and_request() -> void:
	busy = true
	var capture_epoch := epoch
	# Wait only for the latest frame, never queue old frames behind an API call.
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	if not is_running() or capture_epoch != epoch:
		return
	var view := game.navigator_view.get_texture().get_image() as Image
	var map := map_view.get_texture().get_image()
	if view == null or map == null or view.is_empty() or map.is_empty():
		busy = false
		error_text = "Cannot capture the navigator view."
		retry_at = Time.get_ticks_msec() + 2000
		return
	var now := Time.get_ticks_msec()
	var body := {"view": Marshalls.raw_to_base64(view.save_jpg_to_buffer(0.72)),
		"map": Marshalls.raw_to_base64(map.save_jpg_to_buffer(0.8)),
		"speed_kmh": snappedf(game.car.signed_speed * 3.6, 0.1),
		"route": game.ui.route_label.text + ": " + game.ui.route_distance.text,
		"previous_instruction": instruction, "previous_latency_ms": latency_ms,
		"instruction_age_ms": mini(86400000, now - observation_at) if observation_at > 0 else 0}
	sent_at = now
	sent_epoch = epoch
	var result := request.request(endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
	if result != OK:
		busy = false
		error_text = "Cannot connect to the AI host."
		retry_at = now + 2000

func _completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not active or sent_epoch != epoch or not is_running() or run_id != game.car.run_id:
		return
	busy = false
	var now := Time.get_ticks_msec()
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and data is Dictionary and data.get("instruction") is String and not data.instruction.strip_edges().is_empty() and data.instruction.length() <= 240:
		instruction = data.instruction.strip_edges()
		latency_ms = maxi(1, now - sent_at)
		observation_at = sent_at
		ready_to_drive = true
		error_text = ""
		retry_at = 0
		return
	var delay := 2.0
	error_text = "AI connection interrupted."
	if data is Dictionary:
		error_text = str(data.get("error", error_text)).left(180)
		permanent_error = bool(data.get("permanent", false))
		delay = clampf(float(data.get("retry_after", delay)), 1, 3600)
	elif code == 404:
		error_text = "AI host needs an update."
		permanent_error = true
	retry_at = now + int(delay * 1000)
