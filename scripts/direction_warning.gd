extends Control
## Shared human-visible warning. No driving control or route choice is applied.
var game: Node
var wrong_way := false
var pending_seconds := 0.0
var last_run_id := -1

static func points_wrong_way(world: Node, car: Node3D, was_wrong := false) -> bool:
	if car.run_state != "driving" or car.grounded_wheels == 0 or car.global_basis.y.dot(Vector3.UP) < 0.5:
		return false
	var road: Dictionary = world.nearest_road(car.global_position)
	if road.distance > 25.0: return false
	for item: Dictionary in world.roads:
		# Returning from a marked dead end is a legitimate route, not a wrong turn.
		if item.id == road.road_id and item.profile in ["culdesac", "cliff"]:
			return false
	var intended: Vector3 = road.direction
	intended.y = 0.0
	var travel: Vector3 = car.linear_velocity
	travel.y = 0.0
	# At rest warn about facing backwards; at speed measure actual travel,
	# including reversing. Do not depend on throttle or camera facing.
	if travel.length() < 2.0:
		travel = -car.global_basis.z
		travel.y = 0.0
	if intended.length_squared() < 0.001 or travel.length_squared() < 0.001: return false
	return intended.normalized().dot(travel.normalized()) < (-0.10 if was_wrong else -0.45)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 25
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func status_text() -> String:
	return "WRONG WAY" if wrong_way and visible else ""

func _process(delta: float) -> void:
	if not is_instance_valid(game):
		visible = false
		return
	if last_run_id != game.car.run_id:
		last_run_id = game.car.run_id
		wrong_way = false
		pending_seconds = 0.0
	visible = game.started and not game.ui.in_menu and game.car.run_state == "driving"
	if not visible:
		wrong_way = false
		pending_seconds = 0.0
		return
	var candidate := points_wrong_way(game.world, game.car, wrong_way)
	if candidate == wrong_way:
		pending_seconds = 0.0
	else:
		pending_seconds += delta
		if pending_seconds >= (0.6 if candidate else 0.3):
			wrong_way = candidate
			pending_seconds = 0.0
	queue_redraw()

static func draw_banner(canvas: CanvasItem, box: Rect2) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("941f28")
	style.border_color = Color("ffe8a3")
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	canvas.draw_style_box(style, box)
	var icon := box.position + Vector2(box.size.y * 0.42, box.size.y * 0.51)
	var radius := box.size.y * 0.19
	var gold := Color("ffe8a3")
	canvas.draw_arc(icon, radius, PI, TAU, 20, gold, 5, true)
	canvas.draw_line(icon + Vector2(-radius, 0), icon + Vector2(-radius, radius), gold, 5, true)
	canvas.draw_line(icon + Vector2(radius, 0), icon + Vector2(radius, radius), gold, 5, true)
	canvas.draw_colored_polygon(PackedVector2Array([icon + Vector2(radius, radius + 8), icon + Vector2(radius - 9, radius - 4), icon + Vector2(radius + 9, radius - 4)]), gold)
	var title_size := int(minf(box.size.y * 0.40, (box.size.x - box.size.y) / 6.8))
	var at := box.position + Vector2(box.size.y * 0.85, box.size.y * 0.48)
	canvas.draw_string(ThemeDB.fallback_font, at, "WRONG WAY", HORIZONTAL_ALIGNMENT_LEFT, -1, title_size, Color.WHITE)
	canvas.draw_string(ThemeDB.fallback_font, at + Vector2(0, box.size.y * 0.29), "Slow down. Turn around when clear.", HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(10, int(title_size * 0.44)), gold)

func _draw() -> void:
	# Repairs already show a prominent stop-driving heading in both views.
	# Keep tracking the direction so its warning returns when repairs stop.
	if not wrong_way or game.car.repairing: return
	var split: bool = game.ui.mode == "split"
	var width := size.x * (0.5 if split else 1.0)
	var readable: bool = game.ui.readable_ui or game.ui.complete_seats
	var box_width := minf(760.0 if readable else 560.0, width - 32.0)
	var height := 124.0 if readable else 92.0
	for seat in (2 if split else 1):
		# The unfolded map draws its own banner inside its paper bounds.
		if game.ui.map_reveal > 0.5 and (not split or seat == 1): continue
		draw_banner(self, Rect2(seat * width + (width - box_width) * 0.5, 92, box_width, height))
