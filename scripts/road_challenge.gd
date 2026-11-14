extends Node3D
## A readable arcade set piece; the driver's shared run clock moves every bridge.
const Geo = preload("res://scripts/geometry.gd")
const Hazards = preload("res://scripts/road_hazards.gd")
const CYCLE := 12.0
const OPEN_TIME := 6.0
const MOVE_TIME := 1.2
const RAMP_LENGTH := 12.0
const RAMP_HEIGHT := 2.2
# Allow for speed lost climbing the ramp from the posted 65 km/h approach.
const JUMP_SPEED := 14.0
var hazard: Dictionary
var deck: AnimatableBody3D
var deck_origin := Vector3.ZERO
var signal_material: StandardMaterial3D
var sign: Label3D

static func is_challenge(item: Dictionary) -> bool:
	return item.kind in ["jump_gap", "timed_bridge"]

static func bridge_state(item: Dictionary, clock: float) -> Dictionary:
	var open_time := OPEN_TIME - clampi(int(item.get("level", 0)), 0, 4) * 0.5
	var phase := fposmod(clock + item.position.x * 0.037 + item.position.z * 0.019, CYCLE)
	if phase > CYCLE - 0.000001: phase = 0.0
	var shift := 0.0
	if phase >= open_time and phase < open_time + MOVE_TIME:
		shift = smoothstep(0.0, 1.0, (phase - open_time) / MOVE_TIME)
	elif phase >= open_time + MOVE_TIME and phase < CYCLE - MOVE_TIME:
		shift = 1.0
	elif phase >= CYCLE - MOVE_TIME:
		shift = 1.0 - smoothstep(0.0, 1.0, (phase - CYCLE + MOVE_TIME) / MOVE_TIME)
	return {"open": phase < open_time, "warning": phase >= open_time - 2 and phase < open_time, "remaining": open_time - phase if phase < open_time else CYCLE - phase, "shift": shift}

static func jump_height(item: Dictionary, at: Vector3) -> float:
	var lip: float = item.position.z + item.size.z * 0.5
	if at.z > lip and at.z < lip + RAMP_LENGTH:
		return (lip + RAMP_LENGTH - at.z) / RAMP_LENGTH * RAMP_HEIGHT
	if at.z <= lip and at.z >= lip - item.size.z:
		var t: float = (lip - at.z) / item.size.z
		return RAMP_HEIGHT * (1.0 - t) + sin(t * PI) * 3.0
	return 0.0

func setup(item: Dictionary) -> void:
	hazard = item
	name = "JumpGap" if item.kind == "jump_gap" else "TimedBridge"
	var yellow := Geo.material(Color("f1bd49"))
	var dark := Geo.material(Color("303d42"))
	var lip: float = item.position.z + item.size.z * 0.5
	var center: Vector3 = item.position
	center.x = item.lane_x
	if item.kind == "jump_gap":
		var at := Vector3(center.x, Hazards.terrain_height(center.x, lip + RAMP_LENGTH) + 0.17, lip + RAMP_LENGTH * 0.5)
		Hazards._wedge(self, at, 7.2, RAMP_LENGTH, RAMP_HEIGHT, yellow)
		for x in [-2.8, 0.0, 2.8]:
			var stripe := Geo.box(self, Vector3(0.18, 0.035, RAMP_LENGTH), at + Vector3(x, RAMP_HEIGHT * 0.5 + 0.04, 0), dark)
			stripe.rotation.x = atan(RAMP_HEIGHT / RAMP_LENGTH)
	else:
		deck = AnimatableBody3D.new()
		deck.name = "SlidingDeck"
		deck.sync_to_physics = false
		add_child(deck)
		var near_y := Hazards.terrain_height(center.x, lip) + 0.17
		var far_y := Hazards.terrain_height(center.x, lip - item.size.z) + 0.17
		deck_origin = Vector3(center.x, (near_y + far_y) * 0.5 - 0.2, center.z)
		deck.basis = Basis.looking_at(Vector3(0, far_y - near_y, -item.size.z))
		var size := Vector3(10.0, 0.4, item.size.z + 2.0)
		Geo.box(deck, size, Vector3.ZERO, Geo.material(Color("619a98")))
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		deck.add_child(collision)
		for z in range(-int(item.size.z / 2), int(item.size.z / 2) + 1, 2):
			Geo.box(deck, Vector3(9.8, 0.025, 0.08), Vector3(0, 0.215, z), dark)
		for x in [-4.5, 4.5]:
			Geo.box(deck, Vector3(0.3, 0.03, size.z), Vector3(x, 0.23, 0), yellow)
		# Visible rails and a machinery bay show where the deck goes during red.
		for z in [-item.size.z * 0.5, item.size.z * 0.5]:
			Geo.box(self, Vector3(24, 0.25, 0.45), Vector3(center.x + 7, (near_y + far_y) * 0.5 - 0.6, center.z + z), dark)
		Geo.box(self, Vector3(3, 2.5, 5), Vector3(center.x + 18, near_y - 1, center.z), yellow)
	for x in [-5.2, 5.2]:
		var at := Vector3(center.x + x, Hazards.terrain_height(center.x + x, lip + 6), lip + 6)
		Geo.box(self, Vector3(0.22, 3.2, 0.22), at + Vector3.UP * 1.6, dark)
		Geo.box(self, Vector3(1.25, 0.4, 0.2), at + Vector3.UP * 1.4, yellow)
	# A large sign is readable far enough ahead to accelerate or wait on firm ground.
	var sign_at := Vector3(center.x - 6, Hazards.terrain_height(center.x - 6, lip + 34), lip + 34)
	Geo.box(self, Vector3(0.2, 4.4, 0.2), sign_at + Vector3.UP * 2.2, dark)
	Geo.box(self, Vector3(4.4, 2.3, 0.2), sign_at + Vector3.UP * 3.8, dark)
	sign = Label3D.new()
	sign.position = sign_at + Vector3(0, 3.8, 0.13)
	sign.font_size = 72
	sign.pixel_size = 0.007
	sign.no_depth_test = false
	sign.modulate = Color("f4e7bf")
	add_child(sign)
	signal_material = Geo.material(Color("f1bd49"))
	signal_material.emission_enabled = true
	signal_material.emission_energy_multiplier = 0.8
	Geo.sphere(self, 0.35, sign_at + Vector3(0, 5.35, 0), signal_material)
	if item.kind == "jump_gap":
		sign.text = "JUMP GAP\n65+ km/h"
		signal_material.emission = yellow.albedo_color
	else:
		set_clock(0.0)

func set_clock(clock: float) -> void:
	if deck == null: return
	var state := bridge_state(hazard, clock)
	deck.position = deck_origin + Vector3.RIGHT * state.shift * 17.0
	var color := Color("f0b84b") if state.warning else (Color("78d896") if state.open else Color("ef6450"))
	signal_material.albedo_color = color
	signal_material.emission = color
	sign.modulate = color
	sign.text = ("CLOSING" if state.warning else ("CROSS NOW" if state.open else "WAIT")) + "\n%d s" % maxi(1, ceili(state.remaining))
