extends CanvasLayer

signal play_requested(mode: String)
signal resume_requested
signal restart_requested
signal connect_requested(address: String)
signal host_requested
signal leave_requested
signal online_create_requested(address: String, seat: String)
signal online_join_requested(address: String, code: String)
signal online_cancel_requested

const Settings = preload("res://scripts/lobby_settings.gd")
const Dashboard = preload("res://scripts/dashboard.gd")
const FOOTER_HEIGHT := 148.0
const Map = preload("res://scripts/route_map.gd")
const Cracks = preload("res://scripts/windshield_cracks.gd")
var ink := Color("142f2c")
var cream := Color("f0ead5")
var muted := Color("a6b7a3")
var amber := Color("e2b477")
var root: Control
var views: HBoxContainer
var driver_screen: TextureRect
var navigator_screen: TextureRect
var menu: PanelContainer
var hud: Control
var map: Control
var map_panel: PanelContainer
var map_clip: Control
var dashboard: Control
var personal_best_label: Label
var pursuit_box: VBoxContainer
var pursuit_title: Label
var pursuit_detail: Label
var rear_button: Button
var rear_button_held := false
var surface_label: Label
var heat_label: Label
var route_label: Label
var route_distance: Label
var status_label: Label
var driver_tag: Label
var navigator_tag: Label
var footer_label: Label
var resume_button: Button
var address: LineEdit
var blur_slider: HSlider
var hint_label: Label
var damage_label: Label
var driver_cracks: Control
var navigator_cracks: Control
var in_menu := true
var map_open := false
var map_reveal := 0.0
var map_tween: Tween
var result_panel: PanelContainer
var result_title: Label
var result_detail: Label
var restart_button: Button
var mode := "split"
var settings_panel: PanelContainer
var local_panel: PanelContainer
var new_ride_button: Button
var leave_lobby_button: Button
var connecting := false
var preferred_seat := "driver"
var relay_address: LineEdit
var room_code_field: LineEdit
var room_code_label: Label
var share_box: HBoxContainer
var copy_code_button: Button
var copy_link_button: Button
var join_code_button: Button
var shared_code := ""
var online_status: Label
var create_online_button: Button
var create_room_button: Button
var join_online_button: Button
var network_session: Node
var diagnostic_client: Node
var diagnostics_panel: PanelContainer
var diagnostic_address: LineEdit
var diagnostic_result: Label
var live_network: Label
var check_button: Button
var diagnostic_timer := 0.0

func _ready() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.clip_contents = true
	add_child(root)
	var theme := Theme.new()
	theme.default_font_size = 16
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next", "Avenir", "Verdana"])
	theme.default_font = font
	theme.set_color("font_color", "Label", cream)
	theme.set_color("font_color", "Button", cream)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_stylebox("normal", "Button", _style(Color("29483f"), 8))
	theme.set_stylebox("hover", "Button", _style(Color("3d6252"), 8))
	theme.set_stylebox("pressed", "Button", _style(Color("52715c"), 8))
	theme.set_stylebox("focus", "Button", _style(Color(0, 0, 0, 0), 8, amber))
	root.theme = theme
	_build_views()
	_build_hud()
	_build_menu()
	_build_settings()
	_build_local_menu()
	_load_preferences()
	_build_diagnostics()
	_build_run_result()
	root.resized.connect(_layout)
	_layout()

func _style(color: Color, radius: int = 0, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(16)
	if border.a > 0:
		style.border_color = border
		style.set_border_width_all(1)
	return style

func _label(text: String, font_size: int, color: Color = cream) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _build_views() -> void:
	views = HBoxContainer.new()
	views.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	views.add_theme_constant_override("separation", 3)
	root.add_child(views)
	driver_screen = TextureRect.new()
	driver_screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	driver_screen.stretch_mode = TextureRect.STRETCH_SCALE
	driver_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	driver_screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	driver_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	views.add_child(driver_screen)
	navigator_screen = TextureRect.new()
	navigator_screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	navigator_screen.stretch_mode = TextureRect.STRETCH_SCALE
	navigator_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	navigator_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	views.add_child(navigator_screen)
	# The same crack seen from each seat: the driver sits left, so it appears further right.
	driver_screen.clip_contents = true
	navigator_screen.clip_contents = true
	driver_cracks = Cracks.new()
	driver_cracks.origin = Vector2(0.64, 0.3)
	driver_screen.add_child(driver_cracks)
	navigator_cracks = Cracks.new()
	navigator_cracks.origin = Vector2(0.4, 0.3)
	navigator_screen.add_child(navigator_cracks)

func set_windshield_crack(value: float, chase_view: bool) -> void:
	driver_cracks.crack = value
	navigator_cracks.crack = value
	# The chase camera shows the 3D glass instead.
	navigator_cracks.visible = not chase_view

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud)
	var header := Panel.new()
	header.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header.offset_bottom = 78
	header.add_theme_stylebox_override("panel", _style(ink))
	hud.add_child(header)
	var brand := _label("BLIND DRIVER", 24)
	brand.position = Vector2(28, 15)
	header.add_child(brand)
	var edition := _label("FOREST ROADS  /  PROTOTYPE 01", 11, muted)
	edition.position = Vector2(29, 47)
	header.add_child(edition)
	status_label = _label("YOUR NEXT RIDE", 12, amber)
	status_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	status_label.offset_left = -365
	status_label.offset_right = -28
	status_label.offset_top = 27
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(status_label)
	driver_tag = _label("01  /  DRIVER\nTRUST YOUR NAVIGATOR", 13)
	driver_tag.position = Vector2(28, 100)
	hud.add_child(driver_tag)
	navigator_tag = _label("02  /  NAVIGATOR\nKEEP TALKING", 13)
	hud.add_child(navigator_tag)
	var footer := Panel.new()
	footer.name = "DashboardPanel"
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_top = -FOOTER_HEIGHT
	footer.add_theme_stylebox_override("panel", _style(ink))
	hud.add_child(footer)
	dashboard = Dashboard.new()
	dashboard.position = Vector2(16, 0)
	footer.add_child(dashboard)
	surface_label = _label("GRAVEL", 10, amber)
	surface_label.position = Vector2(211, 117)
	footer.add_child(surface_label)
	heat_label = _label("HEAT 1 / 5", 11, amber)
	heat_label.position = Vector2(211, 131)
	footer.add_child(heat_label)
	footer_label = _label("W / S  throttle & brake    A / D  steer\nSPACE  handbrake    M / TAB  map\nB / RB  look back    C  camera    ESC  menu", 13, cream)
	footer_label.position = Vector2(386, 44)
	footer.add_child(footer_label)
	pursuit_box = VBoxContainer.new()
	pursuit_box.custom_minimum_size = Vector2(300, 0)
	pursuit_box.add_theme_constant_override("separation", 4)
	footer.add_child(pursuit_box)
	pursuit_title = _label("PATROL BEHIND YOU", 16, amber)
	pursuit_box.add_child(pursuit_title)
	pursuit_detail = _label("Listen for the siren", 12, muted)
	pursuit_box.add_child(pursuit_detail)
	rear_button = _button("Hold to look back  /  B or RB", func(): pass)
	rear_button.custom_minimum_size.y = 34
	rear_button.button_down.connect(func(): rear_button_held = true)
	rear_button.button_up.connect(func(): rear_button_held = false)
	pursuit_box.add_child(rear_button)
	var route_panel := PanelContainer.new()
	route_panel.name = "RouteCard"
	route_panel.add_theme_stylebox_override("panel", _style(Color("193c34"), 8))
	hud.add_child(route_panel)
	var route_box := VBoxContainer.new()
	route_box.add_theme_constant_override("separation", 5)
	route_panel.add_child(route_box)
	route_box.add_child(_label("YOUR NEXT INSTRUCTION", 10, muted))
	route_label = _label("Follow the road", 23)
	route_box.add_child(route_label)
	route_distance = _label("Find your rhythm. Keep talking.", 12, amber)
	route_box.add_child(route_distance)
	map_panel = PanelContainer.new()
	map_panel.add_theme_stylebox_override("panel", _style(Color("bcb998"), 5))
	map_clip = Control.new()
	map_clip.clip_contents = true
	map_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_clip.z_index = 10
	hud.add_child(map_clip)
	map_clip.add_child(map_panel)
	map = Map.new()
	map.custom_minimum_size = Vector2(0, 0)
	map_panel.add_child(map)
	hint_label = _label("", 16, amber)
	hint_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.position = Vector2(28, -FOOTER_HEIGHT - 90)
	hud.add_child(hint_label)
	damage_label = _label("", 13, Color("e58a6a"))
	damage_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	# Just above the dashboard footer.
	damage_label.offset_top = -FOOTER_HEIGHT - 30
	damage_label.offset_bottom = -FOOTER_HEIGHT - 8
	damage_label.offset_left = 28
	hud.add_child(damage_label)

func _menu_box(panel: PanelContainer) -> VBoxContainer:
	panel.add_theme_stylebox_override("panel", _style(ink, 14))
	root.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 14)
	scroll.add_child(box)
	return box

func _build_menu() -> void:
	menu = PanelContainer.new()
	var box := _menu_box(menu)
	box.add_child(_label("A COOPERATIVE WRONG TURN", 11, amber))
	box.add_child(_label("BLIND DRIVER", 42))
	box.add_child(_label("One drives. One sees the way.", 17, muted))
	personal_best_label = _label("PERSONAL BEST   0.00 km", 13, amber)
	box.add_child(personal_best_label)
	resume_button = _button("Resume the ride   →", func(): resume_requested.emit())
	resume_button.hide()
	box.add_child(resume_button)
	box.add_child(HSeparator.new())
	box.add_child(_label("PLAY ONLINE", 12, amber))
	var seat_row := HBoxContainer.new()
	seat_row.add_theme_constant_override("separation", 10)
	box.add_child(seat_row)
	var seat_label := _label("I want to", 14, muted)
	seat_label.custom_minimum_size.x = 86
	seat_row.add_child(seat_label)
	create_online_button = _button("Drive", func(): _choose_seat("driver"))
	join_online_button = _button("Navigate", func(): _choose_seat("navigator"))
	for button in [create_online_button, join_online_button]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seat_row.add_child(button)
	create_room_button = _button("Create a room   →", _create_room)
	create_room_button.custom_minimum_size.y = 50
	box.add_child(create_room_button)
	# Shown once a room exists: the code to read out or paste to a friend.
	share_box = HBoxContainer.new()
	share_box.add_theme_constant_override("separation", 10)
	share_box.hide()
	box.add_child(share_box)
	room_code_label = _label("", 34)
	room_code_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	share_box.add_child(room_code_label)
	copy_code_button = _button("Copy code", func(): _copy(shared_code, "Code copied. Send it to your friend."))
	share_box.add_child(copy_code_button)
	copy_link_button = _button("Copy invite link", func(): _copy(invite_link(shared_code), "Invite link copied. Opening it joins this room."))
	copy_link_button.visible = OS.has_feature("web")
	share_box.add_child(copy_link_button)
	box.add_child(_label("or join a friend's room", 12, muted))
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	box.add_child(join_row)
	room_code_field = LineEdit.new()
	room_code_field.placeholder_text = "Room code, e.g. K7Q4MZ"
	room_code_field.max_length = 12
	room_code_field.custom_minimum_size.y = 46
	room_code_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_code_field.add_theme_font_size_override("font_size", 19)
	room_code_field.text_submitted.connect(func(_text: String): _join_room())
	join_row.add_child(room_code_field)
	join_code_button = _button("Join", _join_room)
	join_code_button.custom_minimum_size.x = 110
	join_row.add_child(join_code_button)
	online_status = _label("Create a room, or join a friend's with their code. The ride starts when you're both in.", 13, amber)
	online_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	online_status.custom_minimum_size.y = 42
	box.add_child(online_status)
	leave_lobby_button = _button("Cancel / leave room", func(): online_cancel_requested.emit())
	leave_lobby_button.hide()
	box.add_child(leave_lobby_button)
	new_ride_button = _button("Start a new ride", func(): restart_requested.emit())
	new_ride_button.hide()
	box.add_child(new_ride_button)
	box.add_child(HSeparator.new())
	var options := HBoxContainer.new()
	options.add_theme_constant_override("separation", 10)
	box.add_child(options)
	for button in [_button("Play on this computer", func(): _show_secondary(local_panel)), _button("Settings", func(): _show_secondary(settings_panel))]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		options.add_child(button)

func _build_local_menu() -> void:
	local_panel = PanelContainer.new()
	var box := _menu_box(local_panel)
	box.add_child(_label("PLAY HERE", 30))
	box.add_child(_label("No internet or lobby needed.", 15, muted))
	if not OS.has_feature("web"):
		box.add_child(_button("Two players / two windows", func(): play_requested.emit("local_windows")))
	box.add_child(_button("Two players / shared screen", func(): play_requested.emit("split")))
	box.add_child(_button("Solo practice", func(): play_requested.emit("solo")))
	box.add_child(_button("Back", func(): show_menu(true, resume_button.visible)))
	local_panel.hide()

func _build_settings() -> void:
	settings_panel = PanelContainer.new()
	var box := _menu_box(settings_panel)
	box.add_child(_label("SETTINGS", 30))
	box.add_child(_label("Driver blur", 14, muted))
	blur_slider = HSlider.new()
	blur_slider.min_value = 0.012
	blur_slider.max_value = 0.055
	blur_slider.step = 0.001
	blur_slider.value = 0.028
	box.add_child(blur_slider)
	box.add_child(_label("WASD  drive   ·   SPACE  handbrake   ·   M  map\nB / RB  look back   ·   C  camera   ·   H  lights   ·   F  fullscreen   ·   V  mute\nGamepad: left stick + triggers, A brake, Y map", 12, muted))
	box.add_child(HSeparator.new())
	var advanced := VBoxContainer.new()
	advanced.add_theme_constant_override("separation", 10)
	var reveal := CheckButton.new()
	reveal.text = "Advanced connection settings"
	reveal.toggled.connect(func(value: bool): advanced.visible = value)
	box.add_child(reveal)
	box.add_child(advanced)
	advanced.add_child(_label("Online server / already configured", 13, muted))
	relay_address = LineEdit.new()
	relay_address.placeholder_text = Settings.DEFAULT_RELAY
	advanced.add_child(relay_address)
	var help := _label("This website supplies the online server automatically." if OS.has_feature("web") else "Leave this as it is for normal online play.\nDirect LAN below is only for computers on the same Wi-Fi.", 12, muted)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	advanced.add_child(help)
	address = LineEdit.new()
	address.text = "127.0.0.1"
	address.placeholder_text = "Driver’s local IP address"
	advanced.add_child(address)
	if OS.has_feature("web"):
		address.hide()
		relay_address.editable = false
	else:
		advanced.add_child(_button("Direct LAN / host driver", func(): host_requested.emit()))
		advanced.add_child(_button("Direct LAN / join navigator", func(): connect_requested.emit(address.text)))
	advanced.hide()
	box.add_child(_button("Connection check & logs / F8", toggle_diagnostics))
	box.add_child(_button("Save & back", func():
		_save_preferences()
		show_menu(true, resume_button.visible)))
	settings_panel.hide()

func _show_secondary(panel: PanelContainer) -> void:
	menu.hide()
	local_panel.hide()
	settings_panel.hide()
	panel.show()
	_layout()

func _load_preferences(path: String = Settings.PATH) -> void:
	var saved := Settings.read(path)
	preferred_seat = saved.seat
	relay_address.text = OS.get_environment("BLIND_DRIVER_RELAY_URL")
	if relay_address.text.is_empty():
		relay_address.text = saved.address
	if relay_address.text.strip_edges().is_empty():
		relay_address.text = Settings.DEFAULT_RELAY
	if OS.has_feature("web"):
		# Deployment configuration takes precedence over a browser's saved old server.
		var browser_address: Variant = JavaScriptBridge.eval("window.BLIND_DRIVER_CONFIG && window.BLIND_DRIVER_CONFIG.relayUrl || ''")
		if browser_address is String and not browser_address.is_empty():
			relay_address.text = browser_address
	_highlight_seat()

func _highlight_seat() -> void:
	create_online_button.add_theme_stylebox_override("normal", _style(Color("52715c") if preferred_seat == "driver" else Color("29483f"), 8))
	join_online_button.add_theme_stylebox_override("normal", _style(Color("52715c") if preferred_seat == "navigator" else Color("29483f"), 8))

func _save_preferences() -> Error:
	var result := Settings.write(relay_address.text, "", preferred_seat)
	if result != OK:
		online_status.text = "Couldn’t save preferences on this computer. You can still join."
	return result

func _choose_seat(seat: String) -> void:
	preferred_seat = seat
	_highlight_seat()
	_save_preferences()

func _create_room() -> void:
	_save_preferences()
	connecting = true
	set_online_busy(true)
	online_status.text = "Creating your room… The server may take a moment to wake up."
	online_create_requested.emit(relay_address.text, preferred_seat)

func _join_room() -> void:
	var code := preload("res://scripts/relay_client.gd").normalize_share(room_code_field.text)
	if code.is_empty():
		online_status.text = "Room codes are 6 letters and numbers, like K7Q4MZ."
		room_code_field.grab_focus()
		return
	room_code_field.text = code
	connecting = true
	set_online_busy(true)
	online_status.text = "Joining room %s… The server may take a moment to wake up." % code
	online_join_requested.emit(relay_address.text, code)

func _copy(text: String, done: String) -> void:
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	online_status.text = done

## Browser link that opens the game and joins this room; empty outside the browser.
func invite_link(code: String) -> String:
	if not OS.has_feature("web") or code.is_empty():
		return ""
	var base: Variant = JavaScriptBridge.eval("window.location.origin + window.location.pathname")
	return "%s?room=%s" % [base, code] if base is String else ""

func _build_diagnostics() -> void:
	diagnostic_client = preload("res://scripts/relay_client.gd").new()
	add_child(diagnostic_client)
	diagnostic_client.check_updated.connect(func(message: String): diagnostic_result.text = message)
	diagnostic_client.check_finished.connect(func(message: String):
		diagnostic_result.text = message
		check_button.disabled = false)
	diagnostics_panel = PanelContainer.new()
	diagnostics_panel.z_index = 40
	diagnostics_panel.add_theme_stylebox_override("panel", _style(ink, 12, amber))
	root.add_child(diagnostics_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	diagnostics_panel.add_child(box)
	box.add_child(_label("CONNECTION & LOGS", 24))
	live_network = _label("No network session.", 13, muted)
	live_network.custom_minimum_size = Vector2(460, 75)
	live_network.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(live_network)
	box.add_child(_label("Test this computer's connection to the relay", 14))
	diagnostic_address = LineEdit.new()
	diagnostic_address.placeholder_text = "https://your-service.onrender.com"
	box.add_child(diagnostic_address)
	check_button = _button("Start 75-second connection check", func():
		check_button.disabled = true
		diagnostic_result.text = "Connecting… Allow up to 90 seconds for a sleeping server."
		diagnostic_client.start(diagnostic_address.text, "check"))
	box.add_child(check_button)
	diagnostic_result = _label("Checks the same connection used by the game.\nNo room needed. Results describe this test period only.", 13, amber)
	diagnostic_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	diagnostic_result.custom_minimum_size = Vector2(460, 100)
	box.add_child(diagnostic_result)
	if OS.has_feature("web"):
		box.add_child(_button("Download network logs", func(): preload("res://scripts/network_log.gd").download()))
	else:
		box.add_child(_button("Open network logs folder", func(): OS.shell_open(preload("res://scripts/network_log.gd").folder())))
	box.add_child(_button("Stop check / close   F8", func():
		diagnostic_client.stop()
		check_button.disabled = false
		diagnostics_panel.visible = false))
	diagnostics_panel.visible = false

func toggle_diagnostics() -> void:
	diagnostics_panel.visible = not diagnostics_panel.visible
	if diagnostics_panel.visible:
		if not diagnostic_client.active:
			diagnostic_address.text = relay_address.text
		_layout()

func _process(delta: float) -> void:
	diagnostic_timer += delta
	if not diagnostics_panel.visible or diagnostic_timer < 0.5:
		return
	diagnostic_timer = 0.0
	if network_session == null or network_session.role == "local":
		live_network.text = "No network ride active. Start a check below."
	elif network_session.online:
		var data: Dictionary = network_session.relay.metrics()
		live_network.text = "%s · %s\nLatency %d ms · p95 %d ms · missed probes %d\nReconnects %d · queued %d bytes · last close %d" % [network_session.role.to_upper(), "CONNECTED" if data.ready else "WAITING / RECONNECTING", data.rtt_ms, data.p95_ms, data.missed, data.reconnects, data.buffered_bytes, data.last_close_code]
	else:
		live_network.text = "DIRECT LAN · %s\nReceived snapshots: %d · %s" % [network_session.role.to_upper(), network_session.snapshots_received, "reconnecting" if network_session.recovering else "connected / waiting for partner"]

func set_online_busy(busy: bool) -> void:
	create_room_button.disabled = busy
	join_code_button.disabled = busy
	create_online_button.disabled = busy
	join_online_button.disabled = busy
	room_code_field.editable = not busy
	leave_lobby_button.visible = busy
	if not busy:
		connecting = false
		shared_code = ""
		share_box.hide()

func show_online() -> void:
	show_menu(true)

func display_lobby_ready(code: String) -> void:
	shared_code = code
	room_code_label.text = code
	share_box.show()
	online_status.text = "Room ready. Tell your friend this code%s — they'll %s." % [" or send the invite link" if OS.has_feature("web") else "", "navigate" if preferred_seat == "driver" else "drive"]

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 43
	button.pressed.connect(action)
	button.focus_mode = Control.FOCUS_NONE
	return button

func _layout() -> void:
	var width := root.size.x
	var height := root.size.y
	for panel in [menu, settings_panel, local_panel]:
		if panel != null:
			panel.position = Vector2(32, 94)
			panel.size = Vector2(minf(490, width - 64), minf(610, maxf(260, height - 118)))
	if diagnostics_panel != null:
		diagnostics_panel.position = Vector2(maxf(16, width - 540), 98)
		diagnostics_panel.size = Vector2(510, 0)
	pursuit_box.position = Vector2(width - 330, 20)
	footer_label.visible = width >= 1150
	views.offset_top = 78
	views.offset_bottom = 0 if in_menu else -FOOTER_HEIGHT
	navigator_tag.position = Vector2(width * 0.5 + 28 if mode == "split" else 28, 100)
	var route_panel := hud.get_node("RouteCard") as PanelContainer
	route_panel.position = Vector2(width - 340, 190 if mode == "split" else 98)
	route_panel.size = Vector2(312, 98)
	_place_map(map_reveal)
	if result_panel != null:
		result_panel.position = Vector2(maxf(12, (width - 440) / 2), maxf(20, (height - 230) / 2))
		result_panel.size = Vector2(minf(440, width - 24), 0)

func _place_map(value: float) -> void:
	map_reveal = value
	var start_x := root.size.x * 0.5 if mode == "split" else 0.0
	map_panel.position = Vector2(start_x, lerpf(root.size.y - FOOTER_HEIGHT - 64.0, 0.0, value))
	map_panel.size = Vector2(root.size.x - start_x, root.size.y)
	map_clip.size = Vector2(root.size.x, lerpf(root.size.y - FOOTER_HEIGHT, root.size.y, value))
	map.unfolded = map_open

func _build_run_result() -> void:
	result_panel = PanelContainer.new()
	result_panel.z_index = 30
	result_panel.add_theme_stylebox_override("panel", _style(ink, 12, amber))
	root.add_child(result_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	result_panel.add_child(box)
	result_title = _label("GAME OVER", 36, amber)
	box.add_child(result_title)
	result_detail = _label("", 18)
	result_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(result_detail)
	restart_button = _button("Drive again", func(): restart_requested.emit())
	box.add_child(restart_button)
	result_panel.hide()

func show_run_result(state: String, reason: String, distance: float, navigator: bool, best: float = 0.0, new_best: bool = false) -> void:
	result_panel.visible = state == "game_over" and not in_menu
	if state != "game_over":
		return
	result_detail.text = "%s.\nYou made it %.2f km.\n%s: %.2f km%s" % [reason, distance / 1000.0, "NEW PERSONAL BEST" if new_best else "Personal best", best / 1000.0, "\nWaiting for the driver to restart." if navigator else ""]
	restart_button.visible = not navigator

func set_mode(value: String) -> void:
	mode = value
	driver_screen.visible = mode == "split" or mode == "host"
	navigator_screen.visible = mode != "host"
	driver_tag.visible = mode == "split" or mode == "host"
	navigator_tag.visible = mode != "host"
	map_panel.visible = mode != "host" and not in_menu
	hud.get_node("RouteCard").visible = mode != "host" and not in_menu
	status_label.text = {"split": "LOCAL CO-OP   /   SHARED RIDE", "solo": "SOLO   /   DRIVING TEST", "host": "DRIVER   /   WAITING FOR NAVIGATOR", "join": "NAVIGATOR   /   CONNECTING"}.get(mode, "LOCAL")
	_layout()

func show_menu(value: bool, can_resume: bool = true) -> void:
	in_menu = value
	if value:
		rear_button_held = false
	menu.visible = value
	hud.get_node("DashboardPanel").visible = not value
	if settings_panel != null:
		settings_panel.hide()
	if local_panel != null:
		local_panel.hide()
	if not value:
		var focused := root.get_viewport().gui_get_focus_owner()
		if focused != null:
			focused.release_focus()
	resume_button.visible = can_resume and not connecting
	new_ride_button.visible = can_resume and not connecting and mode != "join"
	map_panel.visible = not value and mode != "host"
	hud.get_node("RouteCard").visible = not value and mode != "host"
	driver_tag.visible = not value and (mode == "split" or mode == "host")
	navigator_tag.visible = not value and mode != "host"
	if value:
		driver_screen.visible = false
		navigator_screen.visible = true
	else:
		var current_status := status_label.text
		set_mode(mode)
		status_label.text = current_status
	_layout()

func toggle_map() -> void:
	if mode == "host" or in_menu:
		return
	map_open = not map_open
	if map_tween != null:
		map_tween.kill()
	map_tween = create_tween()
	map_tween.tween_method(_place_map, map_reveal, 1.0 if map_open else 0.0, 0.38).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)

func close_map() -> void:
	map_open = false
	if map_tween != null:
		map_tween.kill()
	_place_map(0.0)

func update_pursuit(patrol: Node3D, rear: bool, driving: bool) -> void:
	rear_button.visible = mode != "host"
	rear_button.disabled = not driving
	if not driving:
		rear_button_held = false
	pursuit_title.modulate = Color("f2a073") if patrol.gap < 45 else Color.WHITE
	if patrol.phase == "caught":
		pursuit_title.text = "CAUGHT"
		pursuit_detail.text = "The patrol stopped your ride."
	elif patrol.phase == "escaped":
		pursuit_title.text = "YOU LOST THE PATROL"
		pursuit_detail.text = "Keep your eyes on the road."
	elif rear:
		pursuit_title.text = "POLICE  /  %d m AWAY" % (roundi(patrol.gap / 5.0) * 5)
		var estimate: float = patrol.eta()
		if patrol.catch_time > 0:
			pursuit_detail.text = "ON YOUR TAIL — KEEP MOVING!"
		elif patrol.phase == "waiting":
			pursuit_detail.text = "A head start. Get moving!"
		elif estimate >= 0 and estimate < 90:
			pursuit_detail.text = "Closing · about %d s at this pace" % maxi(1, roundi(estimate))
		elif patrol.closing_speed < -0.75:
			pursuit_detail.text = "You're pulling away."
		else:
			pursuit_detail.text = "Holding the gap."
	else:
		pursuit_title.text = "POLICE ON YOUR TAIL" if patrol.gap < 45 else "POLICE PURSUIT"
		pursuit_detail.text = "Listen for the siren" if mode == "host" else "Look back to judge the gap."
	navigator_tag.text = "02  /  LOOKING BACK" if rear else "02  /  NAVIGATOR\nKEEP TALKING"
