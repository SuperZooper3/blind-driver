extends RigidBody3D
## Four raycast springs + lateral tire forces, with a little arcade stability.
## The body remains fully physical: gravity, pitching, roll, collisions and jumps.

const Geo = preload("res://scripts/geometry.gd")
const Damage = preload("res://scripts/car_damage.gd")
const Cracks = preload("res://scripts/windshield_cracks.gd")
## Render layers: each seat camera hides only its own occupant's head and body.
const DRIVER_BODY_LAYER := 4
const NAVIGATOR_BODY_LAYER := 8
const SPRING_LENGTH := 0.62
const WHEEL_RADIUS := 0.36
const SPRING_STRENGTH := 28000.0
const SPRING_DAMPING := 3800.0
const ENGINE_FORCE := 11500.0
## Gentler acceleration: the engine pulls at this share of full force from a
## standstill, reaching full force at LAUNCH_FULL_SPEED, so top speed is unchanged.
const LAUNCH_POWER := 0.7
const LAUNCH_FULL_SPEED := 30.0
const MAX_SPEED := 44.0
var suspension_points := [Vector3(-0.88, 0.0, -1.3), Vector3(0.88, 0.0, -1.3), Vector3(-0.88, 0.0, 1.25), Vector3(0.88, 0.0, 1.25)]
var wheel_pivots: Array[Node3D] = []
var wheel_meshes: Array[Node3D] = []
var steering := 0.0
var throttle := 0.0
var brake_input := 0.0
var handbrake := false
var run_state := "driving"
var crash_reason := ""
var run_id := 0
## Flat tires as a wheel bitmask. Newly flattened tires play the pop sound on both seats.
var punctured_tires := 0:
	set(value):
		if value & ~punctured_tires & 15:
			tire_popped.emit.call_deferred()
		punctured_tires = value
## Tires touching thorns this frame, as a wheel bitmask.
var thorn_contact := 0
var smoke: CPUParticles3D
var last_impact_sound := -1.0
signal impacted(strength: float)
signal tire_popped
## Tire health lost per second while a tire sits in thorns.
const THORN_WEAR := 1.0
## Extra rolling resistance of a flat tire, and drag of a bare hub on the ground.
const FLAT_TIRE_DRAG := 45.0
## A flat rides a little lower: more than the suspension can soak up lifts the
## diagonally opposite wheel off the road. It is drawn more squashed than that.
const FLAT_RADIUS := 0.82
const FLAT_LOOK := 0.55
const HUB_SCRAPE := 240.0
var rollover_time := 0.0
var driving_enabled := false
## While R is held the car stays still and repairs; release to drive on.
var repairing := false
## Set each frame by main: the navigator (or the shared keyboard) holds R.
var repair_held := false
var repair_part := -1
## Repairs only start below this speed: 15 km/h.
const REPAIR_MAX_SPEED := 15.0 / 3.6
var remote := false
var on_road := true
var grounded_wheels := 0
var signed_speed := 0.0
var distance_driven := 0.0
var wheel_spin := 0.0
var reset_transform := Transform3D.IDENTITY
var reset_pending := false
var recovery_grace := 0
var recovery_serial := 0
var impact_strength := 0.0
var steering_wheel: Node3D
var crack_pattern: Control
var crack_view: SubViewport
var cabin_time := 0.0
var headlights: Array[SpotLight3D] = []
var lamp_material: StandardMaterial3D
var damage: Damage
## Velocity before this physics step's collisions, for impact speeds.
var prev_linear_velocity := Vector3.ZERO
var prev_angular_velocity := Vector3.ZERO
var touching: Dictionary = {}
var sim_time := 0.0

func _ready() -> void:
	damage = Damage.new(self)
	mass = 1050.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.26, 0.12)
	# A light cabin protects occupants without treating its empty volume as heavy metal.
	inertia = Vector3(1450, 1750, 400)
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.02
	angular_damp = 1.5
	continuous_cd = true
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 8
	var physics_mat := PhysicsMaterial.new()
	physics_mat.friction = 0.35
	physics_mat.bounce = 0.07
	physics_material_override = physics_mat
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.78, 0.65, 3.8)
	shape.shape = box
	shape.position.y = 0.1
	add_child(shape)
	# The old chassis-only collider let the entire cabin sink through the ground.
	var roof := CollisionShape3D.new()
	roof.name = "RoofCollision"
	var roof_box := BoxShape3D.new()
	roof_box.size = Vector3(1.94, 0.24, 2.35)
	roof.shape = roof_box
	roof.position = Vector3(0, 1.62, 0.38)
	add_child(roof)
	for x in [-0.88, 0.88]:
		var side := CollisionShape3D.new()
		var side_box := BoxShape3D.new()
		side_box.size = Vector3(0.18, 1.35, 2.25)
		side.shape = side_box
		side.position = Vector3(x, 0.98, 0.38)
		add_child(side)
	_build_model()
	damage.part_broken.connect(_on_part_broken)
	# The navigator has no contacts of its own; mirrored damage drives its crash sound.
	damage.damaged.connect(func(amount: float):
		if remote:
			impacted.emit(clampf(amount * 2.5, 0.15, 1.0)))
	body_entered.connect(func(_body: Node):
		impact_strength = clampf(linear_velocity.length() / 12.0, 0.0, 1.0))

func _build_model() -> void:
	var paint := Geo.material(Color("d3924b"))
	var dark := Geo.material(Color("243632"))
	var rubber := Geo.material(Color("1c2727"))
	var trim := Geo.material(Color("c3c4a9"))
	var seat := Geo.material(Color("55645a"))
	Geo.box(self, Vector3(1.9, 0.55, 3.9), Vector3(0, 0.05, 0), paint)
	damage.register(Damage.ENGINE, Geo.box(self, Vector3(1.84, 0.26, 1.15), Vector3(0, 0.43, -1.28), paint))
	Geo.box(self, Vector3(1.8, 0.14, 0.66), Vector3(0, 0.64, -0.58), dark)
	damage.register(Damage.FRONT_BUMPER, Geo.box(self, Vector3(1.94, 0.19, 0.16), Vector3(0, -0.13, -2.03), trim))
	damage.register(Damage.REAR_BUMPER, Geo.box(self, Vector3(1.94, 0.19, 0.16), Vector3(0, -0.13, 2.03), trim))
	# The tinted pane is drawn for the chase view only; its cracks are a separate
	# layer drawn onto the glass for every camera.
	var glass_mat := Geo.material(Color(0.75, 0.86, 0.86, 0.18), 0.1)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var glass := Geo.box(self, Vector3(1.68, 0.98, 0.02), Vector3(0, 1.15, -0.7), glass_mat)
	glass.rotation.x = 0.3
	glass.layers = 2
	damage.register(Damage.WINDSHIELD, glass)
	Geo.box(self, Vector3(1.9, 0.14, 2.25), Vector3(0, 1.65, 0.38), paint)
	for x in [-0.88, 0.88]:
		Geo.box(self, Vector3(0.08, 1.1, 0.10), Vector3(x, 1.12, -0.68), paint)
		Geo.box(self, Vector3(0.1, 1.15, 0.10), Vector3(x, 1.08, 1.43), paint)
		Geo.box(self, Vector3(0.1, 0.5, 2.25), Vector3(x, 0.45, 0.35), paint)
	for x in [-0.44, 0.44]:
		Geo.box(self, Vector3(0.62, 0.25, 0.65), Vector3(x, 0.45, 0.35), seat)
		var seat_back := Geo.box(self, Vector3(0.62, 0.55, 0.18), Vector3(x, 0.73, 0.68), seat)
		# Hide the backrest from both first-person cameras, as with the occupants.
		seat_back.layers = 2
	steering_wheel = Node3D.new()
	steering_wheel.position = Vector3(-0.44, 0.79, -0.48)
	steering_wheel.rotation.x = -0.3
	add_child(steering_wheel)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.18
	torus.outer_radius = 0.22
	torus.rings = 12
	torus.ring_segments = 6
	var ring := Geo.instance(steering_wheel, torus, Vector3.ZERO, rubber)
	ring.rotation.x = PI / 2.0
	Geo.box(steering_wheel, Vector3(0.39, 0.04, 0.04), Vector3.ZERO, trim)
	_build_occupants()
	_build_windshield_cracks(glass)
	for i in suspension_points.size():
		var pivot := Node3D.new()
		add_child(pivot)
		wheel_pivots.append(pivot)
		var wheel := Node3D.new()
		pivot.add_child(wheel)
		wheel_meshes.append(wheel)
		var tire := Geo.cylinder(wheel, WHEEL_RADIUS, 0.24, Vector3.ZERO, rubber, -1, 12)
		tire.rotation.z = PI / 2.0
		var hub := Geo.cylinder(wheel, 0.19, 0.255, Vector3.ZERO, trim, -1, 8)
		hub.rotation.z = PI / 2.0
		pivot.position = suspension_points[i] - Vector3.UP * 0.3
		damage.register(i, wheel)
	lamp_material = Geo.material(Color("f8e6ae"))
	lamp_material.emission_enabled = true
	lamp_material.emission = Color("f4d692")
	for x in [-0.66, 0.66]:
		Geo.box(self, Vector3(0.34, 0.23, 0.06), Vector3(x, 0.23, -1.98), lamp_material)
		var light := SpotLight3D.new()
		light.position = Vector3(x, 0.35, -2.05)
		light.light_color = Color("ffe4ac")
		light.light_energy = 1.2
		light.spot_range = 40.0
		light.spot_angle = 34.0
		light.visible = false
		add_child(light)
		headlights.append(light)
	# A wrecked engine smokes from under the missing hood.
	smoke = CPUParticles3D.new()
	smoke.position = Vector3(0, 0.55, -1.3)
	smoke.emitting = false
	smoke.amount = 24
	smoke.lifetime = 1.6
	smoke.direction = Vector3.UP
	smoke.spread = 25.0
	smoke.initial_velocity_min = 1.2
	smoke.initial_velocity_max = 2.2
	smoke.gravity = Vector3(0, 0.6, 0)
	smoke.scale_amount_min = 0.6
	smoke.scale_amount_max = 1.4
	var puff := SphereMesh.new()
	puff.radius = 0.22
	puff.height = 0.44
	puff.radial_segments = 6
	puff.rings = 3
	var smoke_mat := Geo.material(Color(0.32, 0.32, 0.3, 0.55))
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff.material = smoke_mat
	smoke.mesh = puff
	smoke.local_coords = false
	add_child(smoke)

func _physics_process(delta: float) -> void:
	recovery_grace = maxi(0, recovery_grace - 1)
	if remote:
		return
	var steer_target := 0.0
	throttle = 0.0
	brake_input = 0.0
	handbrake = false
	if run_state != "driving":
		driving_enabled = false
	# Repairs run only while R is held; letting go leaves parts part-repaired.
	if driving_enabled and repair_held:
		start_repair()
	else:
		repairing = false
	if repairing:
		repair_part = damage.repair_step(delta) if run_state == "driving" else -1
		if repair_part == -1:
			repairing = false
	if driving_enabled and not repairing:
		steer_target = Input.get_axis("steer_right", "steer_left")
		var forward := Input.get_action_strength("accelerate")
		var reverse := Input.get_action_strength("reverse")
		if reverse > 0.0 and signed_speed > 1.0:
			brake_input = reverse
		elif forward > 0.0 and signed_speed < -1.0:
			brake_input = forward
		else:
			throttle = forward - reverse
		handbrake = Input.is_action_pressed("handbrake")
	else:
		brake_input = 1.0
	steering = move_toward(steering, steer_target, delta * (3.6 if steer_target != 0.0 else 5.2))
	angular_damp = 0.45 if grounded_wheels == 0 else 1.5
	signed_speed = linear_velocity.dot(-global_basis.z)
	distance_driven += Vector2(linear_velocity.x, linear_velocity.z).length() * delta if driving_enabled and grounded_wheels > 0 and recovery_grace == 0 and not reset_pending else 0.0
	impact_strength = move_toward(impact_strength, 0.0, delta * 2.0)
	wheel_spin += signed_speed * delta / WHEEL_RADIUS
	steering_wheel.rotation.z = steering * 1.9
	update_wheel_visuals()
	update_cabin(delta)
	update_tire_visuals()

## Simple occupants: a head and a body each, and the driver's two floating
## sphere hands, which ride the steering wheel.
func _build_occupants() -> void:
	var dark := Geo.material(Color("243632"))
	for seat in 2:
		var x := -0.43 if seat == 0 else 0.43
		var skin := Geo.material(Color("c3ad84") if seat == 0 else Color("b9ccba"))
		var shirt := dark if seat == 0 else Geo.material(Color("3f4f6a"))
		var layer := DRIVER_BODY_LAYER if seat == 0 else NAVIGATOR_BODY_LAYER
		var head := Geo.sphere(self, 0.17, Vector3(x, 1.3, 0.12), skin)
		head.name = "DriverHead" if seat == 0 else "NavigatorHead"
		head.layers = layer
		var torso := Geo.box(self, Vector3(0.42, 0.52, 0.26), Vector3(x, 0.87, 0.32), shirt)
		torso.name = "DriverBody" if seat == 0 else "NavigatorBody"
		torso.layers = layer
		if seat == 0:
			# Hands stay on the rim and turn with the wheel.
			for side in [-1.0, 1.0]:
				var hand := Geo.sphere(steering_wheel, 0.07, Vector3(side * 0.15, 0.14, 0.04), skin)
				hand.name = "DriverHand"

## The same procedural crack pattern as before, now painted onto the glass
## itself, so it sits on the windshield in every view and stays in perspective.
func _build_windshield_cracks(glass: Node3D) -> void:
	crack_view = SubViewport.new()
	crack_view.name = "CrackTexture"
	crack_view.size = Vector2i(672, 320)
	crack_view.transparent_bg = true
	crack_view.disable_3d = true
	crack_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(crack_view)
	crack_pattern = Cracks.new()
	crack_pattern.origin = Vector2(0.56, 0.32)
	crack_view.add_child(crack_pattern)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = crack_view.get_texture()
	var quad := QuadMesh.new()
	# Only the part of the pane below the roof line, seen from inside the cabin.
	quad.size = Vector2(1.66, 0.79)
	var overlay := MeshInstance3D.new()
	overlay.name = "WindshieldCracks"
	overlay.mesh = quad
	overlay.material_override = mat
	# Just inside the pane, toward the cabin.
	overlay.position = Vector3(0, -0.085, 0.012)
	glass.add_child(overlay)

## Shared by the driver and the navigator's copy: glass cracks follow damage,
func update_cabin(delta: float) -> void:
	cabin_time += delta
	if crack_pattern != null:
		var value := damage.windshield_crack()
		if not is_equal_approx(crack_pattern.crack, value):
			crack_pattern.crack = value
			crack_view.render_target_update_mode = SubViewport.UPDATE_ONCE

## Shared by the driver and the navigator's interpolated copy.
func update_wheel_visuals() -> void:
	for i in wheel_pivots.size():
		var wear := 1.0 - damage.health[i]
		wheel_pivots[i].rotation.y = (steering_angle() if i < 2 else 0.0) + damage.wheel_toe(i)
		wheel_meshes[i].rotation.x = -wheel_spin
		# A bent wheel wobbles as it turns.
		wheel_meshes[i].rotation.z = sin(wheel_spin) * wear * 0.18

func steering_angle() -> float:
	return steering * lerpf(0.53, 0.23, clampf(absf(signed_speed) / MAX_SPEED, 0.0, 1.0)) * damage.steer_scale()

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if reset_pending:
		state.transform = reset_transform
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		reset_pending = false
		recovery_serial += 1
		prev_linear_velocity = Vector3.ZERO
		prev_angular_velocity = Vector3.ZERO
		return
	if remote:
		return
	_detect_impacts(state)
	grounded_wheels = 0
	var up := state.transform.basis.y
	var forward := -state.transform.basis.z
	for i in suspension_points.size():
		var local: Vector3 = suspension_points[i]
		var origin := state.transform * local
		var radius := WHEEL_RADIUS * (FLAT_RADIUS if punctured_tires & (1 << i) else 1.0)
		var query := PhysicsRayQueryParameters3D.create(origin, origin - up * (SPRING_LENGTH + radius))
		query.exclude = [get_rid()]
		# A lost wheel drags its hub; a flat tire still rolls, just badly.
		if not damage.alive(i) and not punctured_tires & (1 << i):
			_scrape(state, origin, up)
			continue
		var hit := state.get_space_state().intersect_ray(query)
		if hit.is_empty():
			wheel_pivots[i].position.y = -SPRING_LENGTH
			continue
		grounded_wheels += 1
		var distance: float = origin.distance_to(hit.position)
		var compression := clampf(SPRING_LENGTH - (distance - radius), 0.0, SPRING_LENGTH)
		var offset: Vector3 = origin - state.transform.origin
		var velocity := state.linear_velocity + state.angular_velocity.cross(offset - state.transform.basis * center_of_mass)
		var spring_force := clampf(compression * SPRING_STRENGTH - velocity.dot(up) * SPRING_DAMPING, 0.0, 14000.0)
		state.apply_force(up * spring_force, offset)
		wheel_pivots[i].position.y = -(distance - radius)
		var tire_forward := forward.rotated(up, (steering_angle() if i < 2 else 0.0) + damage.wheel_toe(i))
		tire_forward = tire_forward.slide(hit.normal).normalized()
		var tire_side := tire_forward.cross(hit.normal).normalized()
		var lateral := velocity.dot(tire_side)
		var grip := (1.15 if on_road else 0.68) * damage.wheel_grip(i)
		if handbrake and i >= 2:
			grip *= 0.24
		var side_force := clampf(-lateral * mass * 3.0, -spring_force * grip, spring_force * grip)
		# Apply tire force near the center of mass: enough roll to feel weight, not tip constantly.
		var tire_offset := offset - up * 0.18
		state.apply_force(tire_side * side_force, tire_offset)
		var speed := velocity.dot(tire_forward)
		var speed_limit := (MAX_SPEED if throttle >= 0.0 else 9.0) * damage.speed_scale()
		var drive := throttle * ENGINE_FORCE * lerpf(LAUNCH_POWER, 1.0, clampf(absf(speed) / LAUNCH_FULL_SPEED, 0.0, 1.0)) * damage.power_scale() / 4.0 * clampf(1.0 - absf(speed) / speed_limit, 0.0, 1.0)
		var brake_force := -speed * (1700.0 * brake_input + (700.0 if handbrake else 0.0))
		var rolling := -speed * ((16.0 if on_road else 100.0) + (FLAT_TIRE_DRAG if punctured_tires & (1 << i) else 0.0))
		var traction := clampf(drive + brake_force + rolling, -spring_force * 1.3, spring_force * 1.3)
		state.apply_force(tire_forward * traction, tire_offset)
	if run_state == "game_over" and punctured_tires != 0 and grounded_wheels > 0:
		# Flat tires and tangled brambles bring the wreck to a halt, without cancelling gravity.
		state.apply_central_force(-Vector3(state.linear_velocity.x, 0, state.linear_velocity.z) * mass * 7.0)
	# Aerodynamic drag and gentle roll damping; never lock pitch/roll or erase collisions.
	state.apply_central_force(-state.linear_velocity * state.linear_velocity.length() * 0.8)
	if grounded_wheels > 1:
		var roll_rate := state.angular_velocity.dot(forward)
		state.apply_torque(-forward * roll_rate * 850.0)
	prev_linear_velocity = state.linear_velocity
	prev_angular_velocity = state.angular_velocity

## A missing wheel leaves its hub dragging along the ground.
func _scrape(state: PhysicsDirectBodyState3D, origin: Vector3, up: Vector3) -> void:
	var query := PhysicsRayQueryParameters3D.create(origin, origin - up * 0.75)
	query.exclude = [get_rid()]
	var hit := state.get_space_state().intersect_ray(query)
	if hit.is_empty():
		return
	var offset: Vector3 = hit.position - state.transform.origin
	var velocity := state.linear_velocity + state.angular_velocity.cross(offset)
	var slide: Vector3 = velocity.slide(hit.normal)
	# Weak support stops the hub sinking through; strong friction drags that corner back.
	var depth: float = 0.75 - origin.distance_to(hit.position)
	state.apply_force(hit.normal * clampf(depth * 9000.0 - velocity.dot(hit.normal) * 900.0, 0.0, 5000.0), offset)
	state.apply_force(-slide.limit_length(10.0) * HUB_SCRAPE, offset)

func _detect_impacts(state: PhysicsDirectBodyState3D) -> void:
	# One collision reports several contact points and may bounce for a few frames;
	# count each object once until it has been clear of the car for a moment.
	sim_time += state.step
	var time := sim_time
	var to_local := state.transform.affine_inverse()
	# Gather every contact point of each newly touched object: a flat wall touches
	# both front corners, and the hit should land in the middle, not one corner.
	var hits: Dictionary = {}
	for c in state.get_contact_count():
		var id := state.get_contact_collider_id(c)
		if not hits.has(id) and touching.has(id) and time - float(touching[id]) < 0.35:
			touching[id] = time
			continue
		touching[id] = time
		# Contact positions and normals are reported in global space.
		var point := state.get_contact_local_position(c)
		var normal := state.get_contact_local_normal(c)
		var r := point - state.transform.origin
		var closing := absf((prev_linear_velocity + prev_angular_velocity.cross(r)).dot(normal))
		if not hits.has(id):
			hits[id] = {"sum": Vector3.ZERO, "count": 0, "closing": 0.0, "ground": true}
		var hit: Dictionary = hits[id]
		hit.sum += point
		hit.count += 1
		hit.closing = maxf(hit.closing, closing)
		hit.ground = hit.ground and normal.dot(Vector3.UP) > 0.7
	for hit: Dictionary in hits.values():
		if hit.ground and state.transform.basis.y.dot(Vector3.UP) > 0.3:
			# Ground under the floor: only a hard landing hurts.
			damage.apply_landing(hit.closing)
		else:
			damage.apply_impact(to_local * (hit.sum / hit.count), hit.closing)
			if hit.closing > 3.0 and time - last_impact_sound > 0.15:
				last_impact_sound = time
				impacted.emit.call_deferred(clampf((hit.closing - 3.0) / 25.0, 0.12, 1.0))
	if touching.size() > 32:
		for id in touching.keys():
			if time - float(touching[id]) > 1.0:
				touching.erase(id)

func _on_part_broken(part: int) -> void:
	if part == Damage.FRONT_BUMPER:
		lamp_material.emission_enabled = false
		lamp_material.albedo_color = Color("4a4a42")
		for light in headlights:
			light.visible = false
	if part == Damage.ENGINE:
		smoke.emitting = true

## Starts repairs when the car is slow enough and something is damaged.
## Returns "" on success, otherwise why repairs could not start.
func start_repair() -> String:
	var refusal := repair_refusal()
	if not refusal.is_empty():
		return refusal
	repairing = true
	repair_part = damage.next_repair()
	return ""

## Why repairs cannot start right now, or "". Works on the navigator's mirror too.
func repair_refusal() -> String:
	if run_state != "driving":
		return "unavailable"
	if damage.next_repair() == -1:
		return "nothing"
	if absf(signed_speed) >= REPAIR_MAX_SPEED:
		return "too_fast"
	return ""

func _part_repaired(part: int) -> void:
	if part <= Damage.WHEEL_RR:
		punctured_tires &= ~(1 << part)
		update_tire_visuals()
	if part == Damage.FRONT_BUMPER:
		lamp_material.emission_enabled = true
		lamp_material.albedo_color = Color("f8e6ae")
	if part == Damage.ENGINE:
		smoke.emitting = false

func _damage_reset() -> void:
	repairing = false
	repair_part = -1
	thorn_contact = 0
	smoke.emitting = false
	lamp_material.emission_enabled = true
	lamp_material.albedo_color = Color("f8e6ae")

func begin_fall(reason: String) -> void:
	if remote or run_state != "driving":
		return
	run_state = "falling"
	crash_reason = reason
	driving_enabled = false

func finish_run(reason: String = "") -> void:
	if remote or run_state == "game_over":
		return
	if not reason.is_empty():
		crash_reason = reason
	run_state = "game_over"
	driving_enabled = false
	throttle = 0.0
	brake_input = 1.0
	impact_strength = 1.0

func check_rollover(delta: float) -> void:
	if run_state != "driving":
		return
	# Let airborne tricks finish; fail once the body has landed on its roof/side.
	if global_basis.y.dot(Vector3.UP) < 0.25 and get_contact_count() > 0:
		rollover_time += delta
	else:
		rollover_time = 0.0
	if rollover_time >= 0.65:
		finish_run("You rolled the car")

## Thorns tear at every tire touching them until each goes flat. Flats never end
## the run; they slow the car down until the police catch it.
func wear_tires(mask: int, delta: float) -> void:
	thorn_contact = mask & 15
	if remote or run_state != "driving" or mask == 0:
		return
	for wheel in 4:
		if mask & (1 << wheel):
			damage.wear_tire(wheel, THORN_WEAR * delta)

func flatten_tire(wheel: int) -> void:
	punctured_tires |= 1 << wheel
	update_tire_visuals()

func update_tire_visuals() -> void:
	for i in wheel_pivots.size():
		wheel_pivots[i].scale.y = FLAT_LOOK if punctured_tires & (1 << i) else 1.0

func recover(point: Vector3, direction: Vector3) -> void:
	if run_state != "driving":
		return
	var flat := Vector3(direction.x, 0.0, direction.z).normalized()
	reset_transform = Transform3D(Basis.looking_at(flat), point + Vector3.UP * 1.05)
	reset_pending = true
	recovery_grace = 3

func toggle_lights() -> void:
	if not damage.headlights_ok():
		return
	for light in headlights:
		light.visible = not light.visible
