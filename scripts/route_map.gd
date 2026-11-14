extends Control
## A live navigator's paper chart, drawn from the road graph.

const Hazards = preload("res://scripts/road_hazards.gd")
const Challenge = preload("res://scripts/road_challenge.gd")
var world: Node3D
var car: RigidBody3D
var unfolded := false
var zoom := 1.5
var ink := Color("305449")
var readable_ui := false
var direction_warning: Control
var draw_size: Vector2:
	get: return size / (2.0 if readable_ui else 1.0)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true

func _process(_delta: float) -> void:
	queue_redraw()

func _project(p: Vector3) -> Vector2:
	var rel := p - car.global_position
	var forward := -car.global_basis.z
	var angle := atan2(-forward.x, -forward.z)
	var flat := Vector2(rel.x, rel.z).rotated(0.0 if readable_ui else angle)
	return Vector2(draw_size.x * 0.5, draw_size.y * 0.72) + flat * zoom

func _route_caption(anchor: Vector2, text: String, offset: Vector2, color: Color) -> void:
	if not Rect2(Vector2(10, 42), draw_size - Vector2(20, 94)).has_point(anchor): return
	var width := ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var at := anchor + offset
	if at.x + width > draw_size.x - 18: at.x = anchor.x - width - offset.x
	at.x = clampf(at.x, 18, maxf(18, draw_size.x - width - 18))
	draw_rect(Rect2(at - Vector2(3, 12), Vector2(width + 6, 17)), Color("ddd9bb"))
	draw_string(ThemeDB.fallback_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)

func _draw() -> void:
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * (2.0 if readable_ui else 1.0))
	draw_rect(Rect2(Vector2.ZERO, draw_size), Color("ddd9bb"))
	for x in range(0, int(draw_size.x), 32):
		draw_line(Vector2(x, 0), Vector2(x, draw_size.y), Color(0.22, 0.33, 0.27, 0.08))
	for y in range(0, int(draw_size.y), 32):
		draw_line(Vector2(0, y), Vector2(draw_size.x, y), Color(0.22, 0.33, 0.27, 0.08))
	if not is_instance_valid(world) or not is_instance_valid(car):
		return
	zoom = 1.5
	for road: Dictionary in world.roads:
		var points := PackedVector2Array()
		for p: Vector3 in road.points:
			points.append(_project(p))
		draw_polyline(points, Color("b7b99c"), 11.0, true)
		draw_polyline(points, ink, 3.0, true)
		if road.profile in ["scenic", "rough"]:
			var color := Color("43836a") if road.profile == "scenic" else Color("bd792d")
			draw_polyline(points, color, 4.0, true)
			var midpoint: Vector2 = points[points.size() / 2]
			var caption := "LONG / QUIETER" if road.profile == "scenic" else "SHORT / HEAVY HAZARDS"
			_route_caption(midpoint, caption, Vector2(12, -8), color)
		elif road.profile == "culdesac":
			var end: Vector2 = points[-1]
			var color := Color("8a6665")
			draw_arc(end, 14.0 * zoom, 0, TAU, 32, color, 4.0, true)
			draw_line(end + Vector2(-9, -7), end + Vector2(9, -7), color, 4.0, true)
			_route_caption(end, "DEAD END / TURN AROUND", Vector2(24, 4), color)
		if road.danger:
			var danger := Color("a33d32")
			draw_polyline(points, danger, 5.0, true)
			var end: Vector2 = points[-1]
			draw_line(end + Vector2(-13, -13), end + Vector2(13, 13), danger, 6.0, true)
			draw_line(end + Vector2(13, -13), end + Vector2(-13, 13), danger, 6.0, true)
			draw_string(ThemeDB.fallback_font, end + Vector2(20, 4), "CLIFF", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, danger)
		for hazard: Dictionary in road.hazards:
			var at := _project(hazard.position)
			if hazard.kind == "cliff":
				for edge in Hazards.rim_edges(hazard):
					draw_line(_project(edge[0]), _project(edge[1]), Color("a33d32"), 4.0, true)
			elif hazard.kind == "lake":
				var corners := PackedVector2Array()
				for corner in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]:
					corners.append(_project(hazard.position + corner * hazard.size * 0.5))
				draw_colored_polygon(corners, Color("64979b"))
				draw_string(ThemeDB.fallback_font, at, "LAKE", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
			elif hazard.kind == "construction":
				draw_circle(at, 8.0, Color("c17a3f"))
				draw_string(ThemeDB.fallback_font, at + Vector2(12, 4), "WORKS", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
			elif Challenge.is_challenge(hazard):
				var color := Color("b86a2b")
				var label := "JUMP / RAMP"
				if hazard.kind == "timed_bridge":
					var state := Challenge.bridge_state(hazard, world.challenge_time)
					color = Color("b86a2b") if state.warning else (Color("367e61") if state.open else Color("b64638"))
					label = ("BRIDGE CLOSES %ds" if state.open else "BRIDGE OPENS %ds") % maxi(1, ceili(state.remaining))
				draw_rect(Rect2(at - Vector2(10, 5), Vector2(20, 10)), color)
				draw_string(ThemeDB.fallback_font, at + Vector2(15, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	var pos := _project(car.global_position)
	draw_circle(pos, 16.0, Color(0.18, 0.33, 0.28, 0.12))
	var arrow := PackedVector2Array()
	var forward := -car.global_basis.z
	var heading := atan2(forward.x, -forward.z)
	for point in [Vector2(0, -11), Vector2(-7, 8), Vector2(0, 4), Vector2(7, 8)]:
		arrow.append(pos + (point * (2.0 if readable_ui else 1.0)).rotated(heading if readable_ui else 0.0))
	draw_colored_polygon(arrow, Color("b04f20") if readable_ui else ink)
	if readable_ui:
		draw_rect(Rect2(10, 31, draw_size.x - 20, 23), Color("ddd9bb"))
		draw_string(ThemeDB.fallback_font, Vector2(18, 48), "NORTH UP  /  CAR HEADING %03d°" % int(fposmod(rad_to_deg(heading), 360)), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, ink)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(18, 27), "FIELD MAP  /  M OR TAB TO " + ("FOLD" if unfolded else "UNFOLD"), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ink)
	draw_string(font, Vector2(18, draw_size.y - 17), ("SMALL ROCKS & TREES NOT MAPPED" if readable_ui else "X CLIFF / O DEAD END / AMBER ROUGH / SMALL OBSTACLES UNMAPPED"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ink)
	draw_line(Vector2(draw_size.x - 82, draw_size.y - 31), Vector2(draw_size.x - 22, draw_size.y - 31), ink, 2.0)
	draw_string(font, Vector2(draw_size.x - 80, draw_size.y - 38), "%d m" % int(60.0 / zoom), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
	if unfolded and is_instance_valid(direction_warning) and not direction_warning.status_text().is_empty():
		preload("res://scripts/direction_warning.gd").draw_banner(self, Rect2(18, 60 if readable_ui else 40, draw_size.x - 36, 74))
