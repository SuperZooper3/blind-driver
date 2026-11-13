extends RigidBody3D
## Four raycast springs + lateral tire forces, with a little arcade stability.
## The body remains fully physical: gravity, pitching, roll, collisions and jumps.

const Geo = preload("res://scripts/geometry.gd")
const Damage = preload("res://scripts/car_damage.gd")
const SPRING_LENGTH := 0.62
const WHEEL_RADIUS := 0.36
const SPRING_STRENGTH := 28000.0
const SPRING_DAMPING := 3800.0
const ENGINE_FORCE := 7800.0
const MAX_SPEED := 29.0
var suspension_points := [Vector3(-0.88, 0.0, -1.3), Vector3(0.88, 0.0, -1.3), Vector3(-0.88, 0.0, 1.25), Vector3(0.88, 0.0, 1.25)]
var wheel_pivots: Array[Node3D] = []
var wheel_meshes: Array[Node3D] = []
var steering := 0.0
var throttle := 0.0
var brake_input := 0.0
var handbrake := false
var driving_enabled := false
var remote := false
var on_road := true
var grounded_wheels := 0
var signed_speed := 0.0
var distance_driven := 0.0
var wheel_spin := 0.0
var reset_transform := Transform3D.IDENTITY
var reset_pending := false
var recovery_serial := 0
var impact_strength := 0.0
var steering_wheel: Node3D
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
	linear_damp = 0.05
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
	_build_model()
	damage.part_broken.connect(_on_part_broken)
	body_entered.connect(func(_body: Node): impact_strength = clampf(linear_velocity.length() / 12.0, 0.0, 1.0))

func _build_model() -> void:
	var paint := Geo.material(Color("d3924b"))
	var dark := Geo.material(Color("243632"))
	var rubber := Geo.material(Color("1c2727"))
	var trim := Geo.material(Color("c3c4a9"))
	var seat := Geo.material(Color("55645a"))
	Geo.box(self, Vector3(1.9, 0.55, 3.9), Vector3(0, 0.05, 0), paint)
	damage.register(Damage.HOOD, Geo.box(self, Vector3(1.84, 0.26, 1.15), Vector3(0, 0.43, -1.28), paint))
	Geo.box(self, Vector3(1.8, 0.14, 0.66), Vector3(0, 0.64, -0.58), dark)
	damage.register(Damage.FRONT_BUMPER, Geo.box(self, Vector3(1.94, 0.19, 0.16), Vector3(0, -0.13, -2.03), trim))
	damage.register(Damage.REAR_BUMPER, Geo.box(self, Vector3(1.94, 0.19, 0.16), Vector3(0, -0.13, 2.03), trim))
	# Glass is drawn for the chase view only; seat views get the 2D crack overlay.
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
		Geo.box(self, Vector3(0.62, 0.75, 0.18), Vector3(x, 0.83, 0.68), seat)
		var person := Geo.sphere(self, 0.21, Vector3(x, 1.2, 0.32), Geo.material(Color("c3ad84") if x < 0 else Color("b9ccba")))
		# Occupants are visible in chase view but hidden from both seat cameras.
		person.layers = 2
		var torso := Geo.box(self, Vector3(0.43, 0.52, 0.28), Vector3(x, 0.78, 0.32), dark)
		torso.layers = 2
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

func _physics_process(delta: float) -> void:
	if remote:
		return
	var steer_target := 0.0
	throttle = 0.0
	brake_input = 0.0
	handbrake = false
	if driving_enabled:
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
	signed_speed = linear_velocity.dot(-global_basis.z)
	distance_driven += linear_velocity.length() * delta if driving_enabled else 0.0
	impact_strength = move_toward(impact_strength, 0.0, delta * 2.0)
	wheel_spin += signed_speed * delta / WHEEL_RADIUS
	steering_wheel.rotation.z = steering * 1.9
	update_wheel_visuals()

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
		var query := PhysicsRayQueryParameters3D.create(origin, origin - up * (SPRING_LENGTH + WHEEL_RADIUS))
		query.exclude = [get_rid()]
		if not damage.alive(i):
			_scrape(state, origin, up)
			continue
		var hit := state.get_space_state().intersect_ray(query)
		if hit.is_empty():
			wheel_pivots[i].position.y = -SPRING_LENGTH
			continue
		grounded_wheels += 1
		var distance: float = origin.distance_to(hit.position)
		var compression := clampf(SPRING_LENGTH - (distance - WHEEL_RADIUS), 0.0, SPRING_LENGTH)
		var offset: Vector3 = origin - state.transform.origin
		var velocity := state.linear_velocity + state.angular_velocity.cross(offset - state.transform.basis * center_of_mass)
		var spring_force := clampf(compression * SPRING_STRENGTH - velocity.dot(up) * SPRING_DAMPING, 0.0, 14000.0)
		state.apply_force(up * spring_force, offset)
		wheel_pivots[i].position.y = -(distance - WHEEL_RADIUS)
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
		var speed_limit := MAX_SPEED * damage.speed_scale() if throttle >= 0.0 else 9.0
		var drive := throttle * ENGINE_FORCE * damage.engine_scale() / 4.0 * clampf(1.0 - absf(speed) / speed_limit, 0.0, 1.0)
		var brake_force := -speed * (1700.0 * brake_input + (700.0 if handbrake else 0.0))
		var rolling := -speed * (16.0 if on_road else 100.0)
		var traction := clampf(drive + brake_force + rolling, -spring_force * 1.3, spring_force * 1.3)
		state.apply_force(tire_forward * traction, tire_offset)
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
	state.apply_force(-slide.limit_length(12.0) * 520.0, offset)

func _detect_impacts(state: PhysicsDirectBodyState3D) -> void:
	# One collision reports several contact points and may bounce for a few frames;
	# count each object once until it has been clear of the car for a moment.
	sim_time += state.step
	var time := sim_time
	var to_local := state.transform.affine_inverse()
	for c in state.get_contact_count():
		var id := state.get_contact_collider_id(c)
		var recent: bool = touching.has(id) and time - float(touching[id]) < 0.35
		touching[id] = time
		if recent:
			continue
		# Contact positions and normals are reported in global space.
		var point := state.get_contact_local_position(c)
		var normal := state.get_contact_local_normal(c)
		var r := point - state.transform.origin
		var closing := absf((prev_linear_velocity + prev_angular_velocity.cross(r)).dot(normal))
		if normal.dot(Vector3.UP) > 0.7 and state.transform.basis.y.dot(Vector3.UP) > 0.3:
			# Ground under the floor: only a hard landing hurts.
			damage.apply_landing(closing)
		else:
			damage.apply_impact(to_local * point, closing)
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

func _damage_reset() -> void:
	lamp_material.emission_enabled = true
	lamp_material.albedo_color = Color("f8e6ae")

func recover(point: Vector3, direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z).normalized()
	reset_transform = Transform3D(Basis.looking_at(flat), point + Vector3.UP * 1.05)
	reset_pending = true

func toggle_lights() -> void:
	if not damage.headlights_ok():
		return
	for light in headlights:
		light.visible = not light.visible
