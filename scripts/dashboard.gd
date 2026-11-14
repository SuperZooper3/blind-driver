extends Control
## Analog speed dial and a mechanical-style trip odometer, fed by authoritative car state.
var speed_kmh := 0.0
var distance_km := 0.0
var best_km := 0.0
var displayed_speed := 0.0
const MAX_KMH := 160.0
const CREAM := Color("f0ead5")
const MUTED := Color("a6b7a3")
const AMBER := Color("e2b477")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(330, 144)

func _process(delta: float) -> void:
	displayed_speed = lerpf(displayed_speed, clampf(speed_kmh, 0, MAX_KMH), 1.0 - exp(-delta * 12.0))
	queue_redraw()

func _angle(speed: float) -> float:
	return deg_to_rad(150.0 + clampf(speed / MAX_KMH, 0, 1) * 240.0)

func _text(value: String, at: Vector2, font_size: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, at - Vector2(width * 0.5, 0), value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	var center := Vector2(78, 78)
	var radius := 64.0
	draw_circle(center, radius + 4, Color("091f1d"))
	draw_arc(center, radius + 4, 0, TAU, 64, Color("71887b"), 2.0, true)
	draw_arc(center, radius - 7, _angle(0), _angle(160), 64, Color("3e5d50"), 3.0, true)
	draw_arc(center, radius - 7, _angle(120), _angle(160), 20, Color("c27652"), 3.0, true)
	for speed in range(0, 161, 5):
		var direction := Vector2.from_angle(_angle(speed))
		var major := speed % 20 == 0
		draw_line(center + direction * (radius - (18 if major else 12)), center + direction * (radius - 7), CREAM if major else MUTED, 2.0 if major else 1.0, true)
		if major:
			_text(str(speed), center + direction * (radius - 29) + Vector2(0, 4), 10, CREAM)
	_text("km/h", center + Vector2(0, 25), 10, MUTED)
	var needle := Vector2.from_angle(_angle(displayed_speed))
	draw_line(center - needle * 10, center + needle * (radius - 21), AMBER, 3.0, true)
	draw_circle(center, 5, AMBER)
	draw_circle(center, 2, Color("142f2c"))
	_text("TRIP / KILOMETERS", Vector2(241, 38), 11, MUTED)
	var digits := "%07d" % mini(9999999, maxi(0, floori(distance_km * 100.0)))
	for i in 7:
		var x := 161.0 + i * 21.0 + (7.0 if i >= 5 else 0.0)
		var cell := Rect2(x, 51, 20, 33)
		draw_rect(cell, CREAM if i >= 5 else Color("081e1b"))
		draw_rect(cell, Color("547063"), false, 1.0)
		_text(digits[i], Vector2(x + 10, 75), 22, Color("142f2c") if i >= 5 else CREAM)
		draw_line(Vector2(x + 1, 67), Vector2(x + 19, 67), Color(0, 0, 0, 0.12), 1.0)
	_text(".", Vector2(269, 78), 18, CREAM)
	_text("BEST  %.2f km" % best_km, Vector2(241, 103), 10, AMBER)
