extends Control
## A compact, complete damage list above the dashboard in each seat.
var entries: Array[Dictionary] = []
var bottom_clearance := 12.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Keep the status readable even over the navigator's folded/open map.
	z_index = 12
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()

func update_damage(car: Node, enabled: bool, clearance: float) -> void:
	var next: Array[Dictionary] = car.damage.status_entries()
	visible = enabled and not next.is_empty()
	if next != entries or clearance != bottom_clearance:
		entries = next
		bottom_clearance = clearance
		queue_redraw()

func _draw() -> void:
	if entries.is_empty(): return
	var width := minf(620.0, size.x - 32.0)
	var columns := 2 if width >= 390.0 else 1
	var rows := ceili(float(entries.size()) / columns)
	var height := 38.0 + rows * 36.0
	var left := (size.x - width) * 0.5
	var top := size.y - bottom_clearance - height
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.045, 0.105, 0.09, 0.94)
	panel.border_color = Color("996a4c")
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(9)
	draw_style_box(panel, Rect2(left, top, width, height))
	var font := get_theme_default_font()
	draw_string(font, Vector2(left + 14, top + 23), "CAR DAMAGE", HORIZONTAL_ALIGNMENT_LEFT, width - 28, 12, Color("ffd28a"))
	var column_width := (width - 28.0) / columns
	for i in entries.size():
		var item: Dictionary = entries[i]
		var x := left + 14.0 + (i % columns) * column_width
		var y := top + 43.0 + floori(float(i) / columns) * 36.0
		draw_string(font, Vector2(x, y), item.name, HORIZONTAL_ALIGNMENT_LEFT, column_width - 8, 13, Color("fff6df"))
		draw_string(font, Vector2(x, y + 15), item.status, HORIZONTAL_ALIGNMENT_LEFT, column_width - 8, 11, Color("ff927e") if item.broken else Color("e2b477"))
