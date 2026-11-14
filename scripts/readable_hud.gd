extends Control
## Accessible, human-visible instruments and captions. No navigation decisions.
var game: Node
var sounds: Array[Dictionary] = []
var sound_id := 0
var engine_knocking := false
var siren_audible := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 20
	game.car.impacted.connect(func(_strength: float): caption("CRASH — collision sound"))
	game.car.tire_popped.connect(func(): caption("POP — tire punctured"))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func clock_time() -> float:
	return game.ai_capture.sim_time if is_instance_valid(game.ai_capture) else game.world.challenge_time

func caption(text: String) -> void:
	if is_instance_valid(game.ai_capture) and not game.ai_capture.active: return
	sound_id += 1
	sounds.append({"id": sound_id, "sim_time": clock_time(), "text": text})
	if sounds.size() > 64: sounds.pop_front()

func _process(_delta: float) -> void:
	visible = not game.ui.in_menu
	var knocking: bool = game.car.damage.engine_roughness() > 0.15
	if knocking and not engine_knocking: caption("ENGINE KNOCK — rough motor sound")
	engine_knocking = knocking
	var siren_now: bool = not game.world.basic_course and game.started and game.car.run_state == "driving" and game.police.siren_gain() > 0.05
	if siren_now and not siren_audible: caption("POLICE SIREN nearby")
	siren_audible = siren_now
	queue_redraw()

func text(value: String, at: Vector2, pixels: int, color := Color("f1f5e9"), width := -1.0) -> void:
	draw_string(ThemeDB.fallback_font, at, value, HORIZONTAL_ALIGNMENT_LEFT, width, pixels, color)

func _draw() -> void:
	if not is_instance_valid(game): return
	draw_set_transform(Vector2.ZERO)
	if game.ui.complete_seats:
		_draw_seat(size.x * 0.5, "DRIVER")
		draw_set_transform(Vector2(size.x * 0.5, 0))
		_draw_seat(size.x * 0.5, "NAVIGATOR")
	else:
		_draw_seat(size.x, "DRIVER" if game.mode == "host" else "NAVIGATOR")

func _draw_seat(width: float, seat: String) -> void:
	var footer := size.y - 170.0
	var ui: CanvasLayer = game.ui
	var car: RigidBody3D = game.car
	var amber := Color("ffd06f")
	draw_rect(Rect2(0, 0, width, 72), Color("102c2a"))
	text(seat, Vector2(24, 43), 34)
	text(("MAP OPEN · M TO CLOSE" if ui.map_open else "MAP CLOSED · M TO OPEN") if seat == "NAVIGATOR" else "W/S DRIVE · A/D STEER · SPACE BRAKE", Vector2(300, 43), 26, amber)
	text(preload("res://scripts/version.gd").label(), Vector2(width - 190, 62), 18, amber)
	draw_rect(Rect2(0, footer, width, 170), Color("102c2a"))
	text("SPEED", Vector2(24, footer + 30), 24, amber)
	text("%d km/h" % roundi(absf(car.signed_speed) * 3.6), Vector2(24, footer + 98), 58)
	text("TRIP", Vector2(340, footer + 30), 24, amber)
	text("%.0f m" % car.distance_driven, Vector2(340, footer + 98), 52)
	text("ROAD SURFACE", Vector2(620, footer + 30), 24, amber)
	text("GRAVEL" if car.on_road else "OFF ROAD", Vector2(620, footer + 78), 36)
	text("STATIONARY" if absf(car.signed_speed) < 0.14 else ("REVERSING" if car.signed_speed < 0 else "MOVING"), Vector2(620, footer + 112), 26, amber)
	var damage: String = car.damage.summary()
	text(damage if not damage.is_empty() else "CAR UNDAMAGED", Vector2(24, footer + 150), 24, amber, width - 48)
	var recent: Array[Dictionary] = []
	for sound in sounds:
		if clock_time() - float(sound.sim_time) <= 5.0: recent.append(sound)
	if not recent.is_empty():
		var count := mini(2, recent.size())
		draw_rect(Rect2(18, footer - 82, width - 36, 76), Color(0.04, 0.08, 0.08, 0.94))
		for i in count:
			text("SOUND: " + str(recent[recent.size() - count + i].text), Vector2(32, footer - 52 + i * 32), 26, amber)
	if game.ui.complete_seats and car.run_state == "game_over":
		draw_rect(Rect2(80, 170, width - 160, 210), Color("102c2a"))
		text("GAME OVER", Vector2(110, 225), 42, amber)
		draw_multiline_string(ThemeDB.fallback_font, Vector2(110, 277), car.crash_reason + "\nTrip %.0f m" % car.distance_driven, HORIZONTAL_ALIGNMENT_LEFT, width - 220, 30)
