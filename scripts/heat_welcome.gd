extends Control
## Crisp per-seat title, above the road texture and below the map/repair overlays.
const Seasons = preload("res://scripts/season_style.gd")
const DURATION := 4.2
var clip: Control
var panel: Panel
var heading: Label
var detail: Label
var reveal := 0.0
var stage := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 4
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip = Control.new()
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(clip)
	panel = Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(panel)
	detail = Label.new()
	detail.position = Vector2(20, 12)
	detail.add_theme_font_size_override("font_size", 11)
	panel.add_child(detail)
	heading = Label.new()
	heading.position = Vector2(18, 32)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next", "Avenir", "Verdana"])
	font.font_weight = 700
	heading.add_theme_font_override("font", font)
	heading.add_theme_color_override("font_color", Color("fff4de"))
	panel.add_child(heading)
	resized.connect(_layout)
	hide()

func update_welcome(value: int, elapsed: float, enabled: bool) -> void:
	if stage != clampi(value, 0, 4):
		_set_stage(clampi(value, 0, 4))
	visible = enabled and elapsed < DURATION
	reveal = smoothstep(0.0, 0.65, elapsed) * (1.0 - smoothstep(3.4, DURATION, elapsed))
	_layout()

func _set_stage(value: int) -> void:
	stage = value
	heading.text = "Welcome to " + Seasons.NAMES[stage].capitalize()
	detail.text = "CHAPTER %02d  /  KEEP GOING" % (stage + 1)
	var accent := Color(Seasons.PALETTES[stage].leaf_high) if stage < 3 else Color("cbe5f1" if stage == 3 else "ff7848")
	detail.add_theme_color_override("font_color", accent)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.10, 0.085, 0.92)
	style.border_color = accent
	style.border_width_left = 4
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)

func _layout() -> void:
	if clip == null: return
	var width := minf(480.0, maxf(100.0, size.x - 48.0))
	clip.position = Vector2((size.x - width) * 0.5, 14)
	clip.size = Vector2(width * reveal, 90)
	panel.size = Vector2(width, 90)
	heading.add_theme_font_size_override("font_size", clampi(roundi(width / 13.0), 20, 34))
	heading.size = Vector2(width - 36, 44)
