extends PanelContainer
## Compact, readable instruction strip; the spinner only moves during a request.
var instruction: Label
var detail: Label
var spinner: Control
var thinking := false
var angle := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("142f2c")
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	add_child(row)
	spinner = Control.new()
	spinner.custom_minimum_size = Vector2(20, 20)
	spinner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spinner.draw.connect(func():
		spinner.draw_arc(Vector2(10, 12), 7, 0, TAU, 24, Color("49685b"), 2, true)
		if thinking:
			spinner.draw_arc(Vector2(10, 12), 7, angle, angle + PI * 1.4, 20, Color("e2b477"), 2, true))
	row.add_child(spinner)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(box)
	detail = Label.new()
	detail.add_theme_font_size_override("font_size", 12)
	detail.add_theme_color_override("font_color", Color("e2b477"))
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)
	instruction = Label.new()
	instruction.add_theme_font_size_override("font_size", 22)
	instruction.add_theme_color_override("font_color", Color("f0ead5"))
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(instruction)

func _process(delta: float) -> void:
	if visible:
		angle = fmod(angle + delta * 6.0, TAU)
		spinner.queue_redraw()
