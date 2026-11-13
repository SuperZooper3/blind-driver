extends Node
## Driver-authoritative co-op, over direct LAN RPC or an outbound public relay.

signal status_changed(message: String)
signal connection_lost
signal navigator_joined
signal room_created(code: String)
signal online_joined
signal online_error(message: String)
signal ride_restored

const Log = preload("res://scripts/network_log.gd")
const PORT := 18765
const INTERPOLATION_DELAY := 0.10
const SNAPSHOT_INTERVAL := 1.0 / 30.0
const Relay = preload("res://scripts/relay_client.gd")
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
var relay: Node
var online := false
var room_code := ""
var recovering := false
var lan_url := ""
var lan_retry_at := 0.0
var lan_outage_at := -1.0
var lan_retries := 0
var last_metrics := 0.0

func _ready() -> void:
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_failed)
	multiplayer.server_disconnected.connect(_failed)
	relay = Relay.new()
	relay.name = "Relay"
	add_child(relay)
	relay.room_created.connect(func(code: String):
		room_code = code
		status_changed.emit("ROOM READY / SHARE THE CODE WITH YOUR NAVIGATOR")
		room_created.emit(code))
	relay.joined.connect(func(): online_joined.emit())
	relay.recovering.connect(func(message: String):
		recovering = true
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit(message)
		connection_lost.emit())
	relay.restored.connect(_online_restored)
	relay.peer_waiting.connect(func():
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("PARTNER RECONNECTING / HOLDING THE RIDE"))
	relay.peer_restored.connect(func():
		snapshots.clear()
		last_sequence = -1
		status_changed.emit("DRIVER RETURNED / SYNCING THE RIDE"))
	relay.navigator_joined.connect(_online_peer_joined)
	relay.navigator_left.connect(func():
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("NAVIGATOR LEFT / REJOIN WITH THE SAME ROOM CODE"))
	relay.graph_received.connect(_receive_graph)
	relay.snapshot_received.connect(_receive_snapshot)
	relay.failed.connect(func(message: String):
		role = "disconnected"
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("ONLINE CONNECTION LOST / OPEN ONLINE MENU")
		connection_lost.emit()
		online_error.emit(message))

func host_online(address: String) -> Error:
	stop()
	online = true
	role = "host"
	car.driving_enabled = false
	status_changed.emit("CONNECTING TO RELAY / CREATING ROOM")
	return relay.start(address, "create")

func join_online(address: String, code: String) -> Error:
	stop()
	online = true
	role = "join"
	car.remote = true
	car.freeze = true
	car.collision_layer = 0
	car.collision_mask = 0
	world.allow_generation = false
	status_changed.emit("CONNECTING TO RELAY / JOINING ROOM")
	return relay.start(address, "join", code)

func _online_restored(peer_connected: bool) -> void:
	recovering = false
	snapshots.clear()
	last_sequence = -1
	last_graph_revision = -1
	Log.event("ride_restored", {"role": role, "peer_connected": peer_connected})
	if role == "host" and peer_connected:
		_online_peer_joined()
	else:
		status_changed.emit("CONNECTION RESTORED / WAITING FOR DRIVER" if role == "join" else "CONNECTED / WAITING FOR NAVIGATOR")
		ride_restored.emit()

func can_drive() -> bool:
	return role == "local" or (role == "host" and navigator_id != 0 and not recovering and (not online or relay.is_ready))

func _online_peer_joined() -> void:
	recovering = false
	navigator_id = 1 # Presence marker; relay mode does not send native RPCs.
	last_graph_revision = -1
	navigator_joined.emit()
	status_changed.emit("ONLINE DRIVER / NAVIGATOR CONNECTED")

func _new_peer() -> WebSocketMultiplayerPeer:
	var socket := WebSocketMultiplayerPeer.new()
	socket.inbound_buffer_size = 1048576
	socket.outbound_buffer_size = 1048576
	socket.max_queued_packets = 128
	socket.handshake_timeout = 15.0
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
	lan_url = url
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
	if relay != null:
		relay.stop()
	online = false
	recovering = false
	lan_url = ""
	lan_retry_at = 0.0
	lan_outage_at = -1.0
	lan_retries = 0
	room_code = ""
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
	Log.event("lan_navigator_joined")
	navigator_id = id
	peer.get_peer(id).set_no_delay(true)
	last_graph_revision = -1
	navigator_joined.emit()
	status_changed.emit("DRIVER / NAVIGATOR CONNECTED")

func _peer_disconnected(id: int) -> void:
	if role == "host" and id == navigator_id:
		Log.event("lan_navigator_disconnected")
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("NAVIGATOR DISCONNECTED / WAITING FOR REJOIN")

func _connected() -> void:
	recovering = false
	lan_outage_at = -1.0
	lan_retries = 0
	lan_retry_at = 0.0
	snapshots.clear()
	last_sequence = -1
	Log.event("lan_connected")
	status_changed.emit("NAVIGATOR / RECEIVING WORLD")

func _failed() -> void:
	if role != "join" or online:
		return
	call_deferred("_schedule_lan_retry")

func _schedule_lan_retry() -> void:
	if role != "join" or online or lan_url.is_empty():
		return
	recovering = true
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peer = null
	var time := Time.get_ticks_msec() / 1000.0
	if lan_outage_at < 0.0:
		lan_outage_at = time
	lan_retries += 1
	lan_retry_at = time + minf(8.0, pow(2.0, mini(lan_retries - 1, 3)))
	Log.event("lan_reconnect_scheduled", {"attempt": lan_retries})
	status_changed.emit("LAN CONNECTION LOST / RETRYING AUTOMATICALLY")
	connection_lost.emit()

func _process(delta: float) -> void:
	var time := Time.get_ticks_msec() / 1000.0
	if not online and role == "join" and recovering:
		if time - lan_outage_at >= 120.0:
			role = "disconnected"
			status_changed.emit("LAN RECOVERY TIMED OUT / JOIN THE HOST AGAIN")
		elif lan_retry_at > 0.0 and time >= lan_retry_at:
			lan_retry_at = 0.0
			peer = _new_peer()
			if peer.create_client(lan_url) == OK:
				multiplayer.multiplayer_peer = peer
			else:
				_schedule_lan_retry()
	if role in ["host", "join"] and time - last_metrics > 10.0:
		last_metrics = time
		Log.event("game_network_summary", {"role": role, "online": online, "recovering": recovering, "snapshots_received": snapshots_received, "snapshot_age_ms": roundi((time - last_received_at) * 1000) if last_received_at > 0.0 else -1, "graph_revision": world.graph_revision, "last_sequence": last_sequence})
	if role == "host" and navigator_id != 0:
		snapshot_timer += delta
		graph_timer += delta
		# Do not pile new snapshots behind a slow connection.
		var buffered: int = relay.buffered_bytes() if online else peer.get_peer(navigator_id).get_current_outbound_buffered_amount()
		if buffered > 32768:
			return
		if world.graph_revision != last_graph_revision and (graph_timer > 0.25 or car.recovery_grace > 0):
			graph_timer = 0.0
			if online:
				if relay.send_graph(world.export_graph()):
					last_graph_revision = world.graph_revision
			else:
				_receive_graph.rpc_id(navigator_id, world.export_graph())
				last_graph_revision = world.graph_revision
		# A restart/recovery must never publish the new run with the old pose or graph.
		if car.reset_pending or car.recovery_grace > 0 or world.graph_revision != last_graph_revision:
			return
		if snapshot_timer >= SNAPSHOT_INTERVAL:
			snapshot_timer = fmod(snapshot_timer, SNAPSHOT_INTERVAL)
			sequence += 1
			reset_serial = car.recovery_serial
			var wheels: Array = []
			for wheel: Node3D in car.wheel_pivots:
				wheels.append(wheel.position.y)
			var snapshot := {"seq": sequence, "time": Time.get_ticks_msec() / 1000.0, "transform": car.global_transform, "velocity": car.linear_velocity, "speed": car.signed_speed, "steering": car.steering, "throttle": car.throttle, "distance": car.distance_driven, "grounded": car.grounded_wheels, "reset": reset_serial, "lights": car.headlights[0].visible, "angular_velocity": car.angular_velocity, "wheels": wheels, "run_state": car.run_state, "crash_reason": car.crash_reason, "run_id": car.run_id, "on_road": car.on_road, "impact": car.impact_strength}
			if online:
				relay.send_snapshot(snapshot)
			else:
				_receive_snapshot.rpc_id(navigator_id, snapshot)
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
		Log.event("snapshot_stream_restored")
		stale = false
		status_changed.emit("NAVIGATOR / CONNECTION RESTORED")

func _interpolate(delta: float) -> void:
	if snapshots.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_received_at > 1.0:
		if not stale:
			stale = true
			Log.event("snapshot_stream_stalled", {"age_ms": roundi((now - last_received_at) * 1000)})
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
	car.linear_velocity = b.velocity
	car.angular_velocity = b.angular_velocity
	car.run_state = b.run_state
	car.crash_reason = b.crash_reason
	car.run_id = b.run_id
	car.on_road = b.on_road
	car.impact_strength = b.impact
	for light: SpotLight3D in car.headlights:
		light.visible = b.lights
	car.wheel_spin += car.signed_speed * delta / car.WHEEL_RADIUS
	car.steering_wheel.rotation.z = car.steering * 1.9
	for i in car.wheel_pivots.size():
		car.wheel_pivots[i].position.y = lerpf(a.wheels[i], b.wheels[i], weight)
		car.wheel_pivots[i].rotation.y = car.steering_angle() if i < 2 else 0.0
		car.wheel_meshes[i].rotation.x = -car.wheel_spin

