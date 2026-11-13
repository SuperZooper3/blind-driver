extends CanvasLayer

signal play_requested(mode: String)
signal resume_requested
signal recover_requested
signal connect_requested(address: String)
signal host_requested
signal leave_requested
signal online_create_requested(address: String)
signal online_join_requested(address: String, code: String)
signal online_cancel_requested

const Map = preload("res://scripts/route_map.gd")
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
var speed_label: Label
var distance_label: Label
var surface_label: Label
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
var in_menu := true
var map_open := false
var mode := "split"
var online_panel: PanelContainer
var relay_address: LineEdit
var room_field: LineEdit
var online_status: Label
var create_online_button: Button
var join_online_button: Button

func _ready() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	_build_online_menu()
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
	status_label = _label("LOCAL CO-OP   •   SHARED RIDE", 12, amber)
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
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_top = -94
	footer.add_theme_stylebox_override("panel", _style(ink))
	hud.add_child(footer)
	speed_label = _label("00", 40)
	speed_label.position = Vector2(28, 7)
	footer.add_child(speed_label)
	var unit := _label("KM/H", 10, muted)
	unit.position = Vector2(110, 38)
	footer.add_child(unit)
	surface_label = _label("GRAVEL", 11, amber)
	surface_label.position = Vector2(28, 62)
	footer.add_child(surface_label)
	distance_label = _label("0.00\nKILOMETERS", 14, muted)
	distance_label.position = Vector2(177, 23)
	footer.add_child(distance_label)
	footer_label = _label("W / S  throttle & brake    A / D  steer    SPACE  handbrake\nM / TAB  map    C  camera    R  recover    ESC  menu", 13, cream)
	footer_label.position = Vector2(340, 26)
	footer.add_child(footer_label)
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
	hud.add_child(map_panel)
	map = Map.new()
	map.custom_minimum_size = Vector2(260, 190)
	map_panel.add_child(map)
	hint_label = _label("", 16, amber)
	hint_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.position = Vector2(28, -135)
	hud.add_child(hint_label)

func _build_menu() -> void:
	menu = PanelContainer.new()
	menu.add_theme_stylebox_override("panel", _style(Color("142f2c"), 14))
	root.add_child(menu)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	menu.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 13)
	margin.add_child(box)
	box.add_child(_label("A COOPERATIVE WRONG TURN", 12, amber))
	var title := _label("BLIND\nDRIVER", 64)
	title.add_theme_constant_override("line_spacing", -15)
	box.add_child(title)
	var description := _label("One drives. One sees the way.\nA forest, a battered car, and no end in sight.", 17, muted)
	box.add_child(description)
	var divider := HSeparator.new()
	box.add_child(divider)
	resume_button = _button("Resume the ride   →", func(): resume_requested.emit())
	resume_button.visible = false
	box.add_child(resume_button)
	box.add_child(_button("Start local co-op   →", func(): play_requested.emit("split")))
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	box.add_child(modes)
	for button: Button in [_button("Solo driving test", func(): play_requested.emit("solo")), _button("Play online…", show_online)]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		modes.add_child(button)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	row.add_child(_button("Host driver", func(): host_requested.emit()))
	address = LineEdit.new()
	address.text = "127.0.0.1"
	address.placeholder_text = "Host IP"
	address.custom_minimum_size.x = 140
	address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(address)
	row.add_child(_button("Join navigator", func(): connect_requested.emit(address.text)))
	box.add_child(_label("Two windows? Host here, then join 127.0.0.1 in another.\nTwo computers? Join the host's local network IP.", 11, muted))
	var blur_row := HBoxContainer.new()
	box.add_child(blur_row)
	blur_row.add_child(_label("Driver blur", 13, muted))
	blur_slider = HSlider.new()
	blur_slider.min_value = 0.012
	blur_slider.max_value = 0.055
	blur_slider.step = 0.001
	blur_slider.value = 0.028
	blur_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blur_row.add_child(blur_slider)
	box.add_child(_label("WASD  drive  ·  SPACE  handbrake  ·  M  navigator map\nC  camera  ·  R  recover  ·  H  lights  ·  F  fullscreen\nV  mute  ·  Gamepad: left stick + triggers, A brake, Y map", 12, muted))

func _build_online_menu() -> void:
	online_panel = PanelContainer.new()
	online_panel.add_theme_stylebox_override("panel", _style(ink, 14))
	root.add_child(online_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	online_panel.add_child(box)
	box.add_child(_label("TWO SEATS / ANY TWO COMPUTERS", 12, amber))
	box.add_child(_label("Take the long way.", 34))
	box.add_child(_label("Both players use the same relay address.\nThe driver creates a room and shares its code.", 16, muted))
	box.add_child(_label("Relay address", 13, cream))
	relay_address = LineEdit.new()
	relay_address.placeholder_text = "https://your-service.onrender.com"
	relay_address.text = OS.get_environment("BLIND_DRIVER_RELAY_URL")
	var preferences := ConfigFile.new()
	if relay_address.text.is_empty() and preferences.load("user://network.cfg") == OK:
		relay_address.text = preferences.get_value("relay", "address", "")
	box.add_child(relay_address)
	create_online_button = _button("Create room / I am driving", func():
		_save_relay_address()
		set_online_busy(true)
		online_status.text = "Connecting… A sleeping free server can take about a minute."
		online_create_requested.emit(relay_address.text))
	box.add_child(create_online_button)
	box.add_child(_label("Room code", 13, cream))
	var code_row := HBoxContainer.new()
	box.add_child(code_row)
	room_field = LineEdit.new()
	room_field.placeholder_text = "Paste the driver's room code"
	room_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_row.add_child(room_field)
	code_row.add_child(_button("Copy", func(): DisplayServer.clipboard_set(room_field.text)))
	join_online_button = _button("Join room / I am navigating", func():
		_save_relay_address()
		set_online_busy(true)
		online_status.text = "Connecting to the driver…"
		online_join_requested.emit(relay_address.text, room_field.text))
	box.add_child(join_online_button)
	online_status = _label("Deploy your relay first: instructions are in deployment.md.", 13, amber)
	online_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	online_status.custom_minimum_size = Vector2(480, 50)
	box.add_child(online_status)
	box.add_child(_button("Back / leave online room", func(): online_cancel_requested.emit()))
	online_panel.visible = false

func _save_relay_address() -> void:
	var preferences := ConfigFile.new()
	preferences.set_value("relay", "address", relay_address.text.strip_edges())
	preferences.save("user://network.cfg")

func set_online_busy(busy: bool) -> void:
	create_online_button.disabled = busy
	join_online_button.disabled = busy

func show_online() -> void:
	show_menu(true)
	menu.visible = false
	online_panel.visible = true
	_layout()

func display_room_code(code: String) -> void:
	room_field.text = code
	online_status.text = "Room ready. Copy this code to your navigator. The ride starts when they join."

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
	menu.position = Vector2(40, maxf(94, (height - 680) * 0.5))
	menu.size = Vector2(530, 0)
	if online_panel != null:
		online_panel.position = Vector2(40, maxf(98, (height - 580) * 0.5))
		online_panel.size = Vector2(530, 0)
	views.offset_top = 78
	views.offset_bottom = -94
	navigator_tag.position = Vector2(width * 0.5 + 28 if mode == "split" else 28, 100)
	var route_panel := hud.get_node("RouteCard") as PanelContainer
	route_panel.position = Vector2(width - 340, 98)
	route_panel.size = Vector2(312, 98)
	if map_open:
		map_panel.position = Vector2(width * 0.5 + 16 if mode == "split" else 16, 210)
		map_panel.size = Vector2(width * 0.5 - 32 if mode == "split" else width - 32, height - 320)
	else:
		map_panel.position = Vector2(width - 312, height - 338)
		map_panel.size = Vector2(284, 216)
	map.large = map_open

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
	menu.visible = value
	if online_panel != null:
		online_panel.visible = false
	if not value:
		var focused := root.get_viewport().gui_get_focus_owner()
		if focused != null:
			focused.release_focus()
	resume_button.visible = can_resume
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

func toggle_map() -> void:
	map_open = not map_open
	_layout()
