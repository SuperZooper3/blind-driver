extends Control
## A live navigator's paper chart, drawn from the road graph.

var world: Node3D
var car: RigidBody3D
var large := false
var route_id := -1
var zoom := 1.5
var ink := Color("305449")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true

func _process(_delta: float) -> void:
	queue_redraw()

func _project(p: Vector3) -> Vector2:
	var rel := p - car.global_position
	var forward := -car.global_basis.z
	var angle := atan2(-forward.x, -forward.z)
	var flat := Vector2(rel.x, rel.z).rotated(angle)
	return Vector2(size.x * 0.5, size.y * 0.72) + flat * zoom

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("ddd9bb"))
	for x in range(0, int(size.x), 32):
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.22, 0.33, 0.27, 0.08))
	for y in range(0, int(size.y), 32):
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.22, 0.33, 0.27, 0.08))
	if not is_instance_valid(world) or not is_instance_valid(car):
		return
	zoom = 1.5 if large else 0.95
	for road: Dictionary in world.roads:
		var points := PackedVector2Array()
		for p: Vector3 in road.points:
			points.append(_project(p))
		draw_polyline(points, Color("b7b99c"), 11.0 if large else 8.0, true)
		draw_polyline(points, ink, 3.0, true)
		if int(road.parent) == route_id and int(road.id) % 2 == (route_id % 2):
			draw_polyline(points, Color("c17a3f"), 5.0, true)
	var pos := _project(car.global_position)
	draw_circle(pos, 16.0, Color(0.18, 0.33, 0.28, 0.12))
	draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -11), pos + Vector2(-7, 8), pos + Vector2(0, 4), pos + Vector2(7, 8)]), ink)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(18, 27), "FIELD NOTES / FOREST SERVICE", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ink)
	draw_string(font, Vector2(18, size.y - 17), "YOU ARE HERE   /   UP = YOUR HEADING", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
	draw_line(Vector2(size.x - 82, size.y - 31), Vector2(size.x - 22, size.y - 31), ink, 2.0)
	draw_string(font, Vector2(size.x - 80, size.y - 38), "%d m" % int(60.0 / zoom), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
