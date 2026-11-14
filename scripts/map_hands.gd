extends Control
## The navigator's two hands holding the paper map: soft blobs gripping its lower
## corners, drifting slightly, and riding up with the map as it unfolds.

var panel: Control
var time := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _process(delta: float) -> void:
	time += delta
	visible = is_instance_valid(panel) and panel.visible
	queue_redraw()

func _draw() -> void:
	if not is_instance_valid(panel):
		return
	var bottom: float = (get_parent() as Control).size.y
	var left := panel.position.x
	var right := panel.position.x + panel.size.x
	var radius := clampf(panel.size.x * 0.045, 26.0, 52.0)
	for side in [-1.0, 1.0]:
		var x := (left + radius * 1.3) if side < 0 else (right - radius * 1.3)
		var drift := Vector2(sin(time * 1.3 + side) * 3.0, sin(time * 1.7 + side * 2.0) * 4.0)
		var at := Vector2(x, bottom - radius * 0.8) + drift
		# A shadow, the palm, and a thumb pressing onto the paper.
		draw_circle(at + Vector2(0, 5), radius, Color(0, 0, 0, 0.18))
		draw_circle(at, radius, Color("b9ccba"))
		draw_circle(at + Vector2(-side * radius * 0.55, -radius * 0.75), radius * 0.42, Color("b9ccba"))
		draw_arc(at, radius, 0, TAU, 32, Color(0.2, 0.25, 0.22, 0.45), 2.0, true)
