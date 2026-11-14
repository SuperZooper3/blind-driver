extends Node3D
## Opening scene: the getaway car idles outside the bank it just robbed, the
## alarm rings, and the driver's glasses fly off and break on the road. The
## camera shows the bank, then the broken glasses, then flies into each
## player's own seat and the ride begins.
const Geo = preload("res://scripts/geometry.gd")

const DURATION := 8.5
## Shots: the bank and car, the driver losing his glasses, the broken glasses
## on the ground, then the flight into each seat.
const WIDE_END := 3.6
const DRIVER_END := 4.9
const GLASSES_END := 6.6
const GLASSES_DROP := 4.0
const GLASSES_FALL_TIME := 0.7
const Site = preload("res://scripts/bank_site.gd")

var car: RigidBody3D
var time := 0.0
var glasses: Node3D
var alarm_light: OmniLight3D
var alarm_lamp: StandardMaterial3D
var bell: AudioStreamPlayer
var bell_playback: AudioStreamGeneratorPlayback
var bell_phase := 0.0
var bell_clock := 0.0
var bell_gain := 1.0
var glasses_start: Transform3D
var glasses_end: Transform3D
var cracks: Array[Node3D] = []
var loose_lens: Node3D
var broken := false

func setup(owner_car: RigidBody3D, ground_y: float) -> void:
	car = owner_car
	_build_bank(Site.CENTER, ground_y)
	_build_glasses()
	_build_bell()

func finished() -> bool:
	return time >= DURATION

func _process(delta: float) -> void:
	time += delta
	# The alarm light flashes twice a second.
	var on := fmod(time, 0.5) < 0.25
	alarm_light.light_energy = 6.0 if on else 0.3
	alarm_lamp.emission_energy_multiplier = 3.0 if on else 0.2
	if is_instance_valid(glasses):
		var fall := clampf((time - GLASSES_DROP) / GLASSES_FALL_TIME, 0.0, 1.0)
		var placed := glasses_start.interpolate_with(glasses_end, fall)
		# Thrown out over the door, they arc up and drop onto the road.
		placed.origin = glasses_start.origin.lerp(glasses_end.origin, fall) + Vector3.UP * sin(fall * PI) * 0.45
		glasses.global_transform = placed.scaled_local(Vector3.ONE * 1.5)
		if fall >= 1.0 and not broken:
			_break_glasses()
	# The bell keeps ringing into the ride, fading out over two seconds.
	bell_gain = 1.0 if time < DURATION else maxf(0.0, 1.0 - (time - DURATION) / 2.0)
	_feed_bell()

## Where a camera sits during the intro. `seat` is that camera's normal view;
## the last shot flies into it.
func shot(seat: Transform3D) -> Transform3D:
	var base := car.global_transform
	var focus := car.global_position + Vector3(4.0, 1.4, 3.0)
	if time < WIDE_END:
		# Slowly circle the bank and the waiting car from across the road.
		return _wide(focus, lerpf(-0.7, 0.15, time / WIDE_END))
	var close_at := base * Vector3(-1.3, 1.45, -1.6)
	var close := Transform3D(Basis.looking_at(base * Vector3(-0.43, 1.05, -0.1) - close_at), close_at)
	if time < DRIVER_END:
		var wide := _wide(focus, 0.15)
		var cut := clampf((time - WIDE_END) / 0.5, 0.0, 1.0)
		return wide.interpolate_with(close, smoothstep(0.0, 1.0, cut))
	# Low over the road, slowly pushing in on the broken glasses.
	var lying := glasses_end.origin
	var side := (glasses_end.origin - base.origin)
	side.y = 0.0
	side = side.normalized()
	var push := clampf((time - DRIVER_END) / (GLASSES_END - DRIVER_END), 0.0, 1.0)
	var ground_at := lying + side * lerpf(1.3, 0.8, push) + Vector3.UP * lerpf(0.7, 0.45, push) + base.basis.z * 0.3
	var ground := Transform3D(Basis.looking_at(lying - ground_at), ground_at)
	if time < GLASSES_END:
		return ground
	var zoom := clampf((time - GLASSES_END) / (DURATION - GLASSES_END), 0.0, 1.0)
	return ground.interpolate_with(seat, smoothstep(0.0, 1.0, zoom))

## From across the road (the bank is on the car's right), `angle` radians around.
func _wide(focus: Vector3, angle: float) -> Transform3D:
	var at := focus + Vector3(-cos(angle) * 14.0, 4.5, sin(angle) * 14.0)
	return Transform3D(Basis.looking_at(focus - at), at)

func _build_bank(center: Vector3, ground_y: float) -> void:
	var root := Node3D.new()
	root.name = "Bank"
	add_child(root)
	root.global_position = Vector3(center.x, ground_y, center.z)
	var stone := Geo.material(Color("d8cfb8"))
	var trim := Geo.material(Color("9c9483"))
	var glass := Geo.material(Color("33424a"), 0.2)
	var hall := Geo.box(root, Vector3(10, 7, 14), Vector3(0, 3.5, 0), stone)
	hall.create_convex_collision()
	Geo.box(root, Vector3(11, 0.6, 15), Vector3(0, 7.3, 0), trim)
	# A pediment over four columns and the steps, facing the road.
	Geo.box(root, Vector3(1.6, 1.2, 15), Vector3(-5.6, 7.9, 0), trim)
	for z in [-4.5, -1.5, 1.5, 4.5]:
		Geo.cylinder(root, 0.4, 6.2, Vector3(-6.0, 3.4, z), stone, -1.0, 10)
	for step in 3:
		Geo.box(root, Vector3(1.0, 0.25, 12), Vector3(-6.4 - step * 0.6 + 0.6, 0.12 + (2 - step) * 0.25, 0), trim)
	var door := Geo.box(root, Vector3(0.1, 3.2, 2.4), Vector3(-5.02, 1.9, 0), glass)
	door.name = "BankDoor"
	for z in [-4.0, 4.0]:
		Geo.box(root, Vector3(0.1, 2.0, 1.6), Vector3(-5.02, 3.6, z), glass)
	var sign := Label3D.new()
	sign.text = "BANK"
	sign.font_size = 220
	sign.modulate = Color("3a3428")
	sign.outline_size = 0
	sign.position = Vector3(-6.45, 7.9, 0)
	sign.rotation.y = -PI / 2.0
	root.add_child(sign)
	# The alarm bell box with its flashing red lamp beside the door.
	var bell_box := Geo.box(root, Vector3(0.3, 0.7, 0.7), Vector3(-5.2, 5.4, -2.4), Geo.material(Color("b3241c")))
	bell_box.name = "AlarmBell"
	alarm_lamp = Geo.material(Color("ff3b2a"), 0.3)
	alarm_lamp.emission_enabled = true
	alarm_lamp.emission = Color("ff3b2a")
	Geo.sphere(root, 0.28, Vector3(-5.35, 6.0, -2.4), alarm_lamp)
	alarm_light = OmniLight3D.new()
	alarm_light.light_color = Color("ff3b2a")
	alarm_light.omni_range = 16.0
	alarm_light.position = Vector3(-6.0, 6.0, -2.4)
	root.add_child(alarm_light)

func _build_glasses() -> void:
	glasses = Node3D.new()
	glasses.name = "DriverGlasses"
	# They belong to the street, not the car: they stay behind when it drives off.
	add_child(glasses)
	var frame := Geo.material(Color("141414"), 0.4)
	var lens := Geo.material(Color(0.6, 0.8, 0.9, 0.5), 0.1)
	lens.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var crack_mat := Geo.material(Color("f4f4f0"), 0.2)
	for side in [-0.065, 0.065]:
		var rim := Geo.cylinder(glasses, 0.05, 0.02, Vector3(side, 0, 0), lens, -1.0, 12)
		rim.rotation.x = PI / 2.0
		if side > 0.0:
			loose_lens = rim
		else:
			# Hidden until the glasses hit the road.
			for angle in [0.4, 1.5, 2.6, -0.8]:
				var crack := Geo.box(glasses, Vector3(0.09, 0.004, 0.004), Vector3(side, 0, -0.012), crack_mat)
				crack.rotation.z = angle
				crack.visible = false
				cracks.append(crack)
		Geo.box(glasses, Vector3(0.11, 0.012, 0.012), Vector3(side, 0.05, 0), frame)
		Geo.box(glasses, Vector3(0.012, 0.012, 0.16), Vector3(side * 2.3, 0.04, 0.08), frame)
	Geo.box(glasses, Vector3(0.04, 0.012, 0.012), Vector3(0, 0.035, 0), frame)
	# On the driver's face, then lying on the road beside the driver's door.
	var base := car.global_transform
	glasses_start = Transform3D(base.basis, base * Vector3(-0.43, 1.31, -0.04))
	var landing := base * Vector3(-1.6, 0.0, -0.5)
	landing.y = _ground_below(landing) + 0.03
	glasses_end = Transform3D(base.basis * Basis.from_euler(Vector3(-PI / 2.0, 0.7, 0.0)), landing)
	glasses.global_transform = glasses_start.scaled_local(Vector3.ONE * 1.5)

func _ground_below(at: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 3.0, at + Vector3.DOWN * 6.0)
	query.exclude = [car.get_rid()]
	var hit := car.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position.y if not hit.is_empty() else car.global_position.y - 0.9

## On landing a lens cracks and the other pops out beside the frame.
func _break_glasses() -> void:
	broken = true
	for crack in cracks:
		crack.visible = true
	loose_lens.position += Vector3(0.16, 0.0, 0.09)
	loose_lens.rotation = Vector3(0.2, 0.0, 0.5)

func _build_bell() -> void:
	bell = AudioStreamPlayer.new()
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050
	generator.buffer_length = 0.12
	bell.stream = generator
	bell.volume_db = -12
	add_child(bell)
	bell.play()
	bell_playback = bell.get_stream_playback()

## A classic alarm bell: a bright tone struck about twenty times a second.
func _feed_bell() -> void:
	if bell_playback == null:
		return
	for _i in bell_playback.get_frames_available():
		bell_clock += 1.0 / 22050.0
		bell_phase = fmod(bell_phase + 1180.0 / 22050.0, 1.0)
		var strike := exp(-fmod(bell_clock, 0.05) * 60.0)
		var sample := (sin(bell_phase * TAU) + 0.4 * sin(bell_phase * TAU * 2.76)) * strike * bell_gain * 0.35
		bell_playback.push_frame(Vector2(sample, sample))

## Once the bell has faded, only the bank stays behind; the glasses stay on the floor.
func done_with_sound() -> bool:
	return time >= DURATION + 2.0

func _exit_tree() -> void:
	if bell != null:
		bell.stop()
	bell_playback = null
