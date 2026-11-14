extends Control
## Cracks in the shared windshield, drawn over a seat view. The pattern is fixed
## per seat and revealed as damage rises, so both players see the same glass.

const CRACKS := 16
var crack := 0.0:
	set(value):
		if not is_equal_approx(crack, value):
			crack = value
			queue_redraw()
## Where the glass first gave way, in 0..1 view coordinates.
var origin := Vector2(0.62, 0.32)
var paths: Array[PackedVector2Array] = []
## Line widths are in pixels; the driver's low-resolution view uses thinner lines.
var line_scale := 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331
	for i in CRACKS:
		var angle := TAU * float(i) / CRACKS + rng.randf_range(-0.2, 0.2)
		var point := Vector2.ZERO
		var path := PackedVector2Array([point])
		for _step in rng.randi_range(5, 8):
			angle += rng.randf_range(-0.45, 0.45)
			point += Vector2(cos(angle), sin(angle)) * rng.randf_range(0.04, 0.11)
			path.append(point)
		paths.append(path)
	resized.connect(queue_redraw)

func _draw() -> void:
	if crack <= 0.02:
		return
	var scale := minf(size.x, size.y) * 1.3
	var center := origin * size
	var shattered := crack >= 0.999
	if shattered:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.82, 0.84, 0.8, 0.3))
	# Each crack appears at its own damage level, then grows to full length.
	for i in paths.size():
		var start := float(i) / paths.size() * 0.85
		var grown := clampf((crack - start) / 0.25, 0.0, 1.0)
		if grown <= 0.0:
			continue
		var path: PackedVector2Array = paths[i]
		var count := maxi(2, ceili(path.size() * grown))
		var points := PackedVector2Array()
		for j in count:
			points.append(center + path[j] * scale)
		draw_polyline(points, Color(0.1, 0.12, 0.12, 0.35), maxf(1.0, 3.0 * line_scale), true)
		draw_polyline(points, Color(0.95, 0.97, 0.95, 0.8), maxf(1.0, 1.4 * line_scale), true)
	# Impact star.
	var star := (6.0 + crack * 18.0) * line_scale
	draw_circle(center, star, Color(0.95, 0.97, 0.95, 0.22 + crack * 0.25))
	if shattered:
		# Spider-web rings linking the radial cracks.
		for ring in [0.05, 0.11, 0.19, 0.3]:
			var web := PackedVector2Array()
			for path: PackedVector2Array in paths:
				var index := mini(path.size() - 1, int(ring / 0.08) + 1)
				web.append(center + path[index].normalized() * ring * scale * (0.9 + 0.2 * sin(index * 3.1)))
			web.append(web[0])
			draw_polyline(web, Color(0.95, 0.97, 0.95, 0.6), maxf(1.0, 1.2 * line_scale), true)
