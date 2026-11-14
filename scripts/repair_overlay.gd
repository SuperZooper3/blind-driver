extends Control
## Read-only repair display in each seat, above the road and below the map.
const Damage = preload("res://scripts/car_damage.gd")
const PART_NAMES := ["Front left tire", "Front right tire", "Rear left tire", "Rear right tire", "Engine", "Front bumper", "Rear bumper", "Windshield"]
const GOLD := Color("ffd28a")
const CREAM := Color("fff6df")
const GREEN := Color("95d6ae")
const MUTED := Color("bbc8bf")
var health := PackedFloat32Array()
var active_part := -1
var can_look_back := false
var driver_only := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 5
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()

func update_repair(car: Node, enabled: bool, rear_available: bool, is_driver: bool) -> void:
	visible = enabled and car.repairing and car.run_state == "driving"
	if not visible:
		return
	health = car.damage.health.duplicate()
	active_part = car.repair_part
	can_look_back = rear_available
	driver_only = is_driver
	queue_redraw()

func _panel(box: Rect2, color: Color, border: Color = Color.TRANSPARENT) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0 else 0)
	style.set_corner_radius_all(12)
	draw_style_box(style, box)

func _text(at: Vector2, text: String, font_size: int, color: Color, width: float, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(get_theme_default_font(), at, text, alignment, width, font_size, color)

func _draw() -> void:
	if health.size() != Damage.PART_COUNT:
		return
	# Dim the whole view without hiding the pursuit or intercepting any input.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.06, 0.055, 0.26))
	draw_rect(Rect2(Vector2(3, 3), size - Vector2(6, 6)), Color(GOLD, 0.65), false, 3.0)
	var width := minf(590.0, size.x - 32.0)
	var left := (size.x - width) * 0.5
	var compact := size.y < 510.0
	var heading_height := 102.0 if compact else 118.0
	_panel(Rect2(left, 16, width, heading_height), Color(0.045, 0.105, 0.09, 0.94), GOLD)
	_text(Vector2(left, 55), "REPAIRING...", 30 if compact else 36, GOLD, width, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Vector2(left, 87), "You can't drive", 24 if compact else 27, CREAM, width, HORIZONTAL_ALIGNMENT_CENTER)
	if not compact:
		_text(Vector2(left, 114), "The car is parked until repairs stop", 14, MUTED, width, HORIZONTAL_ALIGNMENT_CENTER)
	# Every part stays visible, including queued work and completed repairs.
	# Two columns leave a clear window between the heading and progress card.
	var row_height := 41.0 if compact else 45.0
	var card_height := row_height * 4.0 + 61.0
	# Leave the folded map's 64-pixel edge clear, even before it is opened.
	var top := size.y - card_height - 84.0
	_panel(Rect2(left, top, width, card_height), Color(0.045, 0.105, 0.09, 0.90))
	_text(Vector2(left + 16, top + 23), "PART REPAIR PROGRESS", 12, GOLD, width - 32)
	var column_width := (width - 48.0) * 0.5
	for index in Damage.REPAIR_ORDER.size():
		var part: int = Damage.REPAIR_ORDER[index]
		var value := clampf(health[part], 0.0, 1.0)
		var active := part == active_part and value < 1.0
		var color := GREEN if value >= 1.0 else (GOLD if active else MUTED)
		var x := left + 16.0 + (index % 2) * (column_width + 16.0)
		var y := top + 45.0 + floori(index / 2.0) * row_height
		_text(Vector2(x, y), PART_NAMES[part], 13, color, column_width - 40)
		_text(Vector2(x, y), "%d%%" % floori(value * 100.0), 13, color, column_width, HORIZONTAL_ALIGNMENT_RIGHT)
		var bar := Rect2(x, y + 7.0, column_width, 9.0)
		_panel(bar, Color("32463e"))
		if value > 0.0:
			_panel(Rect2(bar.position, Vector2(bar.size.x * value, bar.size.y)), color)
		if active:
			draw_rect(bar.grow(2), GOLD, false, 1.0)
	var hint := "Navigator: release R to drive" if driver_only else "Hold R to repair  /  Release to drive"
	if can_look_back:
		hint += "  /  B or RB: look back"
	_text(Vector2(left + 12, top + card_height - 12), hint, 12, CREAM, width - 24, HORIZONTAL_ALIGNMENT_CENTER)
