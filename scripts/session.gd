extends Node
## Desktop localhost/LAN co-op. The driver owns physics; navigator interpolates.
## This is Godot's WebSocket RPC protocol, not the future public Node relay protocol.

signal status_changed(message: String)
signal connection_lost

const PORT := 18765
const INTERPOLATION_DELAY := 0.10
const SNAPSHOT_INTERVAL := 1.0 / 30.0
var car: RigidBody3D
var world: Node3D
var peer: WebSocketMultiplayerPeer
var role := "local"
var navigator_id := 0
var last_graph_revision := -1
var snapshot_timer := 0.0
var graph_timer := 0.0
var sequence := 0
var last_sequence := -1
var reset_serial := 0
var received_reset := -1
var snapshots: Array[Dictionary] = []
var clock_offset := 0.0
var last_received_at := 0.0
var stale := false
var snapshots_received := 0
var graph_received := false

func _ready() -> void:
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_failed)
	multiplayer.server_disconnected.connect(_failed)

func _new_peer() -> WebSocketMultiplayerPeer:
	var socket := WebSocketMultiplayerPeer.new()
	socket.inbound_buffer_size = 1048576
	socket.outbound_buffer_size = 1048576
	socket.max_queued_packets = 128
	socket.handshake_timeout = 5.0
	return socket

func host(bind_address: String = "*") -> Error:
	stop()
	peer = _new_peer()
	var error := peer.create_server(PORT, bind_address)
	if error != OK:
		status_changed.emit("PORT %d BUSY / CLOSE THE OTHER HOST" % PORT)
		peer = null
		return error
	role = "host"
	multiplayer.multiplayer_peer = peer
	status_changed.emit("DRIVER / HOSTING ON PORT %d" % PORT)
	return OK

func join(address: String) -> Error:
	stop()
	peer = _new_peer()
	var url := address.strip_edges()
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "ws://" + url
	if url.get_slice("://", 1).find(":") == -1:
		url += ":%d" % PORT
	var error := peer.create_client(url)
	if error != OK:
		status_changed.emit("COULD NOT CONNECT / CHECK HOST ADDRESS")
		peer = null
		return error
	role = "join"
	car.remote = true
	car.freeze = true
	car.collision_layer = 0
	car.collision_mask = 0
	world.allow_generation = false
	multiplayer.multiplayer_peer = peer
	status_changed.emit("NAVIGATOR / CONNECTING TO DRIVER")
	return OK

func stop() -> void:
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peer = null
	role = "local"
	navigator_id = 0
	snapshots.clear()
	sequence = 0
	last_sequence = -1
	received_reset = -1
	last_graph_revision = -1
	snapshots_received = 0
	graph_received = false
	stale = false
	last_received_at = 0.0
	car.remote = false
	car.freeze = false
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.collision_layer = 1
	car.collision_mask = 1
	world.allow_generation = true

func _peer_connected(id: int) -> void:
	if role != "host":
		return
	if navigator_id != 0:
		peer.disconnect_peer(id)
		return
	navigator_id = id
	peer.get_peer(id).set_no_delay(true)
	last_graph_revision = -1
	car.driving_enabled = true
	status_changed.emit("DRIVER / NAVIGATOR CONNECTED")

func _peer_disconnected(id: int) -> void:
	if role == "host" and id == navigator_id:
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("NAVIGATOR LEFT / ESC TO RESUME OR REHOST")

func _connected() -> void:
	status_changed.emit("NAVIGATOR / RECEIVING WORLD")

func _failed() -> void:
	status_changed.emit("CONNECTION LOST / ESC TO RECONNECT")
	connection_lost.emit()

func _process(delta: float) -> void:
	if role == "host" and navigator_id != 0:
		snapshot_timer += delta
		graph_timer += delta
		var socket := peer.get_peer(navigator_id)
		# Do not pile new snapshots behind a slow connection.
		if socket.get_current_outbound_buffered_amount() > 32768:
			return
		if world.graph_revision != last_graph_revision and graph_timer > 0.25:
			graph_timer = 0.0
			_receive_graph.rpc_id(navigator_id, world.export_graph())
			last_graph_revision = world.graph_revision
		if snapshot_timer >= SNAPSHOT_INTERVAL:
			snapshot_timer = fmod(snapshot_timer, SNAPSHOT_INTERVAL)
			sequence += 1
			reset_serial = car.recovery_serial
			_receive_snapshot.rpc_id(navigator_id, {"seq": sequence, "time": Time.get_ticks_msec() / 1000.0, "transform": car.global_transform, "velocity": car.linear_velocity, "speed": car.signed_speed, "steering": car.steering, "throttle": car.throttle, "distance": car.distance_driven, "grounded": car.grounded_wheels, "reset": reset_serial})
	elif role == "join":
		_interpolate(delta)

@rpc("authority", "call_remote", "reliable")
func _receive_graph(data: Array) -> void:
	if role != "join" or data.size() > 100:
		return
	world.import_graph(data)
	graph_received = true
	status_changed.emit("NAVIGATOR / CONNECTED TO DRIVER")

@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_snapshot(data: Dictionary) -> void:
	if role != "join" or int(data.get("seq", -1)) <= last_sequence:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var received_transform: Transform3D = data.transform
	if not received_transform.origin.is_finite():
		return
	if snapshots.is_empty() or int(data.reset) != received_reset:
		snapshots.clear()
		clock_offset = now - float(data.time)
		car.global_transform = received_transform
		received_reset = int(data.reset)
	else:
		# Lowest recent transit offset avoids turning arrival jitter into render jitter.
		clock_offset = minf(clock_offset + 0.0002, now - float(data.time))
	last_sequence = int(data.seq)
	last_received_at = now
	snapshots_received += 1
	snapshots.append(data)
	if snapshots.size() > 20:
		snapshots.pop_front()
	if stale:
		stale = false
		status_changed.emit("NAVIGATOR / CONNECTION RESTORED")

func _interpolate(delta: float) -> void:
	if snapshots.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_received_at > 1.0:
		if not stale:
			stale = true
			status_changed.emit("CONNECTION STALLED / WAITING FOR DRIVER")
		return
	var render_time := now - clock_offset - INTERPOLATION_DELAY
	while snapshots.size() > 2 and float(snapshots[1].time) <= render_time:
		snapshots.pop_front()
	var a: Dictionary = snapshots[0]
	var b: Dictionary = snapshots[mini(1, snapshots.size() - 1)]
	var span := float(b.time) - float(a.time)
	var weight := clampf((render_time - float(a.time)) / span, 0.0, 1.0) if span > 0.0 else 1.0
	var transform_a: Transform3D = a.transform
	car.global_transform = transform_a.interpolate_with(b.transform, weight)
	car.signed_speed = lerpf(a.speed, b.speed, weight)
	car.steering = lerpf(a.steering, b.steering, weight)
	car.throttle = b.throttle
	car.distance_driven = b.distance
	car.grounded_wheels = b.grounded
	car.wheel_spin += car.signed_speed * delta / car.WHEEL_RADIUS
	car.steering_wheel.rotation.z = car.steering * 1.9
	for i in car.wheel_pivots.size():
		car.wheel_pivots[i].rotation.y = car.steering_angle() if i < 2 else 0.0
		car.wheel_meshes[i].rotation.x = -car.wheel_spin

