extends Node
## Driver-authoritative co-op, over direct LAN RPC or an outbound public relay.

signal status_changed(message: String)
signal connection_lost
signal navigator_joined
signal room_created(code: String)
signal online_joined
signal online_error(message: String)
signal ride_restored
## "host" (this game drives) or "join" (this game navigates), as the relay assigns seats.
signal seat_changed(role: String)
## Seats were swapped between rides; main starts the new ride as `role`.
signal seats_swapped(role: String)
## Direct local-network link state for the menu and header, e.g. "Direct link to 10.0.33.215".
signal direct_status_changed(text: String, wanted: bool)

const Log = preload("res://scripts/network_log.gd")
const PORT := 18765
var port := PORT
## Full snapshots (police, damage, run state…) are drawn this far behind to interpolate.
const INTERPOLATION_DELAY := 0.20
## The car's pose goes out at this rate; the navigator predicts between and beyond poses.
const SNAPSHOT_INTERVAL := 1.0 / 30.0
## Everything else changes slowly and goes out at this rate, or at once when it matters.
const FULL_INTERVAL := 0.1
const Predictor = preload("res://scripts/pose_predictor.gd")
const DirectLink = preload("res://scripts/direct_link.gd")
const Wire = preload("res://scripts/wire_protocol.gd")
const Relay = preload("res://scripts/relay_client.gd")
var car: RigidBody3D
var world: Node3D
var police: Node3D
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
var predictor := Predictor.new()
var direct: Node
var direct_wanted := false
var direct_offer: Dictionary = {}
var latest_pose: Dictionary = {}
var last_pose_sequence := -1
var pose_sequence := 0
var full_timer := 0.0
var last_full_signature := ""
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
	# Integration checks can use a free port without disrupting a running game.
	var requested_port := OS.get_environment("BLIND_DRIVER_LAN_PORT")
	if requested_port.is_valid_int() and int(requested_port) > 0 and int(requested_port) <= 65535:
		port = int(requested_port)
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_failed)
	multiplayer.server_disconnected.connect(_failed)
	relay = Relay.new()
	relay.name = "Relay"
	add_child(relay)
	relay.seat_assigned.connect(func(seat: String): _take_seat("host" if seat == "driver" else "join"))
	relay.seats_swapped.connect(func(seat: String):
		if seat == "driver":
			# Our partner is still connected; they are now the navigator.
			_online_peer_joined()
		else:
			status_changed.emit("SEATS SWAPPED / WAITING FOR THE NEW DRIVER")
		seats_swapped.emit(role))
	relay.room_created.connect(func(code: String):
		room_code = code
		status_changed.emit("Room %s ready. Waiting for your friend…" % code)
		room_created.emit(code))
	relay.joined.connect(func(): online_joined.emit())
	relay.waiting.connect(func(message: String): status_changed.emit(message))
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
		_forget_poses()
		status_changed.emit("Driver connected. Syncing the ride…")
		if not graph_received:
			online_joined.emit())
	relay.navigator_joined.connect(_online_peer_joined)
	relay.navigator_left.connect(func():
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("Navigator left. They can return to this lobby."))
	relay.graph_received.connect(_receive_graph)
	relay.snapshot_received.connect(_receive_snapshot)
	relay.pose_received.connect(_receive_pose)
	direct = DirectLink.new()
	direct.name = "DirectLink"
	add_child(direct)
	# Game data from the partner arrives the same way whichever path it took.
	direct.message_received.connect(func(message: Dictionary): relay.handle_game_message(message))
	direct.link_changed.connect(_direct_link_changed)
	relay.direct_offer.connect(_partner_direct_offer)
	relay.failed.connect(func(message: String):
		role = "disconnected"
		navigator_id = 0
		car.driving_enabled = false
		status_changed.emit("ONLINE CONNECTION LOST / OPEN ONLINE MENU")
		connection_lost.emit()
		online_error.emit(message))

## Create a room. `seat` is "driver" or "navigator"; the friend who joins gets the other one.
func host_online(address: String, lobby: String = "", seat: String = "driver") -> Error:
	stop()
	online = true
	_take_seat("join" if seat == "navigator" and lobby.is_empty() else "host")
	status_changed.emit("Creating your room…")
	return relay.start(address, "create", "", lobby, seat)

## Join by room code (or legacy lobby name). The relay assigns whichever seat is free.
func join_online(address: String, code: String = "", lobby: String = "") -> Error:
	stop()
	online = true
	_take_seat("join")
	status_changed.emit("Joining your friend's room…")
	return relay.start(address, "join", code, lobby)

## Switch this game between owning the car (host/driver) and mirroring it (join/navigator).
func _take_seat(value: String) -> void:
	if value == role:
		return
	role = value
	navigator_id = 0
	snapshots.clear()
	_forget_poses()
	last_sequence = -1
	received_reset = -1
	last_graph_revision = -1
	graph_received = false
	stale = false
	var driving := value == "host"
	car.remote = not driving
	car.freeze = not driving
	car.collision_layer = 1 if driving else 0
	car.collision_mask = 1 if driving else 0
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.driving_enabled = false
	world.allow_generation = driving
	seat_changed.emit(value)

func _online_restored(peer_connected: bool) -> void:
	recovering = false
	if direct_wanted and not direct_offer.is_empty():
		# The partner may have missed our addresses while we were away.
		relay.send_direct(direct_offer)
	snapshots.clear()
	last_sequence = -1
	_forget_poses()
	last_graph_revision = -1
	Log.event("ride_restored", {"role": role, "peer_connected": peer_connected})
	if role == "host" and peer_connected:
		_online_peer_joined()
	else:
		status_changed.emit("CONNECTION RESTORED / WAITING FOR DRIVER" if role == "join" else "CONNECTED / WAITING FOR NAVIGATOR")
		if role == "join" and peer_connected and not graph_received:
			online_joined.emit()
		ride_restored.emit()

## Turn the direct local-network link on or off for both players. Either player may;
## the partner's game follows. Falls back to the relay whenever the link is down.
func set_direct(on: bool) -> void:
	if not online:
		return
	if not on:
		direct.stop()
		direct_wanted = false
		direct_offer = {}
		relay.send_direct({"on": false})
		direct_status_changed.emit("Direct link off. Using the internet relay.", false)
		return
	_start_direct(false)

func _start_direct(reply: bool) -> void:
	if not direct.enabled:
		var offer: Dictionary = direct.start()
		if offer.is_empty():
			direct_status_changed.emit("Direct links need the desktop game.", false)
			return
		direct_offer = offer.merged({"on": true})
	direct_wanted = true
	relay.send_direct(direct_offer.merged({"reply": reply}, true))
	if not direct.is_linked():
		var listening := "listening on port %d" % direct.port if direct.port > 0 else "not listening (port busy or blocked)"
		direct_status_changed.emit("Looking for your partner on this network (%s: %s)…" % [", ".join(direct_offer.addrs), listening], true)

func _partner_direct_offer(offer: Dictionary) -> void:
	if not offer.get("on", false):
		direct.stop()
		direct_wanted = false
		direct_offer = {}
		direct_status_changed.emit("Your partner turned the direct link off. Using the internet relay.", false)
		return
	# Follow the partner: listen too, answer with our addresses once, and dial theirs.
	if not direct.enabled or not offer.get("reply", false):
		_start_direct(true)
	direct.set_partner(offer.get("addrs", []), int(offer.get("port", 0)), str(offer.get("key", "")))

func _direct_link_changed(address: String) -> void:
	# Re-send the road map over whichever path now carries the game.
	last_graph_revision = -1
	if address.is_empty():
		Log.event("direct_link_lost")
		if direct_wanted:
			direct_status_changed.emit("Direct link lost. Using the internet relay and retrying…", true)
	else:
		Log.event("direct_link_up", {"outgoing": bool(direct.active.outgoing)})
		direct_status_changed.emit("Direct link to %s. Game data skips the internet." % address, true)

## Both players are in the room right now, so seats can be swapped.
func can_swap() -> bool:
	if not online or recovering or not relay.is_ready:
		return false
	return navigator_id != 0 if role == "host" else (role == "join" and not stale and snapshots_received > 0)

func request_swap() -> void:
	if can_swap():
		relay.request_swap()

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
	var error := peer.create_server(port, bind_address)
	if error != OK:
		status_changed.emit("PORT %d BUSY / CLOSE THE OTHER HOST" % port)
		peer = null
		return error
	role = "host"
	multiplayer.multiplayer_peer = peer
	status_changed.emit("DRIVER / HOSTING ON PORT %d" % port)
	return OK

func join(address: String) -> Error:
	stop()
	peer = _new_peer()
	var url := address.strip_edges()
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "ws://" + url
		if url.get_slice("://", 1).find(":") == -1:
			url += ":%d" % port
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
	if direct != null:
		direct.stop()
	direct_wanted = false
	direct_offer = {}
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
	_forget_poses()
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
	_forget_poses()
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
		var buffered: int = (direct.buffered_bytes() if direct.is_linked() else relay.buffered_bytes()) if online else peer.get_peer(navigator_id).get_current_outbound_buffered_amount()
		if buffered > 32768:
			return
		if world.graph_revision != last_graph_revision and (graph_timer > 0.25 or car.recovery_grace > 0):
			graph_timer = 0.0
			if online:
				var sent: bool = direct.send({"type": "graph", "roads": Wire.graph_to_json(world.export_graph())}) if direct.is_linked() else relay.send_graph(world.export_graph())
				if sent:
					last_graph_revision = world.graph_revision
			else:
				_receive_graph.rpc_id(navigator_id, world.export_graph())
				last_graph_revision = world.graph_revision
		# A restart/recovery must never publish the new run with the old pose or graph.
		if car.reset_pending or car.recovery_grace > 0 or world.graph_revision != last_graph_revision:
			return
		full_timer += delta
		if snapshot_timer >= SNAPSHOT_INTERVAL:
			snapshot_timer = fmod(snapshot_timer, SNAPSHOT_INTERVAL)
			reset_serial = car.recovery_serial
			var wheels: Array = []
			for wheel: Node3D in car.wheel_pivots:
				wheels.append(wheel.position.y)
			var now := Time.get_ticks_msec() / 1000.0
			# Run-changing events go out at once instead of waiting for the next full snapshot.
			var signature := "%s|%d|%d|%d|%s" % [car.run_state, car.run_id, reset_serial, car.punctured_tires, car.headlights[0].visible]
			if full_timer >= FULL_INTERVAL or signature != last_full_signature:
				full_timer = 0.0
				last_full_signature = signature
				sequence += 1
				var snapshot := {"seq": sequence, "time": now, "transform": car.global_transform, "velocity": car.linear_velocity, "speed": car.signed_speed, "steering": car.steering, "throttle": car.throttle, "distance": car.distance_driven, "grounded": car.grounded_wheels, "reset": reset_serial, "lights": car.headlights[0].visible, "angular_velocity": car.angular_velocity, "wheels": wheels, "run_state": car.run_state, "crash_reason": car.crash_reason, "run_id": car.run_id, "on_road": car.on_road, "impact": car.impact_strength, "tires": car.punctured_tires, "police": police.snapshot(), "challenge_time": world.challenge_time, "damage": car.damage.health_array()}
				if online:
					if not (direct.is_linked() and direct.send({"type": "snapshot", "state": Wire.snapshot_to_json(snapshot)})):
						relay.send_snapshot(snapshot)
				else:
					_receive_snapshot.rpc_id(navigator_id, snapshot)
			else:
				pose_sequence += 1
				var pose := {"seq": pose_sequence, "time": now, "reset": reset_serial, "transform": car.global_transform, "velocity": car.linear_velocity, "angular_velocity": car.angular_velocity, "speed": car.signed_speed, "steering": car.steering, "throttle": car.throttle, "grounded": car.grounded_wheels, "wheels": wheels}
				if online:
					if not (direct.is_linked() and direct.send({"type": "pose", "state": Wire.pose_to_json(pose)})):
						relay.send_pose(pose)
				else:
					_receive_pose.rpc_id(navigator_id, pose)
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
	var restarted := _sync_clock(data, now)
	if restarted or snapshots.is_empty():
		snapshots.clear()
		car.global_transform = received_transform
	last_sequence = int(data.seq)
	last_received_at = now
	snapshots_received += 1
	snapshots.append(data)
	if snapshots.size() > 20:
		snapshots.pop_front()
	# A full snapshot carries a pose too; use it if it is the newest news.
	_use_pose(data, restarted)
	if stale:
		Log.event("snapshot_stream_restored")
		stale = false
		status_changed.emit("NAVIGATOR / CONNECTION RESTORED")

@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_pose(data: Dictionary) -> void:
	if role != "join" or int(data.get("seq", -1)) <= last_pose_sequence:
		return
	var received_transform: Transform3D = data.transform
	if not received_transform.origin.is_finite():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var restarted := _sync_clock(data, now)
	last_pose_sequence = int(data.seq)
	last_received_at = now
	# Counts every car update, pose or full snapshot.
	snapshots_received += 1
	_use_pose(data, restarted)
	if stale:
		Log.event("snapshot_stream_restored")
		stale = false
		status_changed.emit("NAVIGATOR / CONNECTION RESTORED")

## Track the driver's clock and notice restarts/recoveries. Returns true on a new reset.
func _sync_clock(data: Dictionary, now: float) -> bool:
	if received_reset < 0 or int(data.reset) != received_reset:
		clock_offset = now - float(data.time)
		received_reset = int(data.reset)
		return true
	# Lowest recent transit offset avoids turning arrival jitter into render jitter.
	clock_offset = minf(clock_offset + 0.0002, now - float(data.time))
	return false

func _use_pose(data: Dictionary, snap: bool) -> void:
	if predictor.accept(float(data.time), data.transform, data.velocity, data.angular_velocity, snap):
		latest_pose = data

func _forget_poses() -> void:
	predictor.reset()
	latest_pose = {}
	last_pose_sequence = -1
	full_timer = 0.0
	last_full_signature = ""

## Estimated delay from the driver to us beyond the fastest delivery seen, added so the
## prediction aims at where the driver's car is now rather than when it was sent.
func _prediction_lead() -> float:
	# One display frame: what we compute now is seen on the next frame.
	var frame := 1.0 / 60.0
	if not online or relay.rtts.is_empty():
		return 0.01 + frame
	return clampf(relay.rtts.min() / 1000.0, 0.01, 0.15) + frame

func _interpolate(delta: float) -> void:
	if snapshots.is_empty() and latest_pose.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_received_at > 1.0:
		if not stale:
			stale = true
			Log.event("snapshot_stream_stalled", {"age_ms": roundi((now - last_received_at) * 1000)})
			status_changed.emit("CONNECTION STALLED / WAITING FOR DRIVER")
		return
	var driver_now := now - clock_offset + _prediction_lead()
	if not latest_pose.is_empty():
		# Optimistic continuation: show where the driver's car is now, not where it was.
		car.global_transform = predictor.step(driver_now, delta)
		car.signed_speed = latest_pose.speed
		car.steering = latest_pose.steering
		car.throttle = latest_pose.throttle
		car.grounded_wheels = latest_pose.grounded
		car.linear_velocity = latest_pose.velocity
		car.angular_velocity = latest_pose.angular_velocity
		for i in car.wheel_pivots.size():
			car.wheel_pivots[i].position.y = float(latest_pose.wheels[i])
	if snapshots.is_empty():
		_animate_wheels(delta)
		return
	# Slower-changing state is interpolated a little in the past.
	var render_time := now - clock_offset - INTERPOLATION_DELAY
	while snapshots.size() > 2 and float(snapshots[1].time) <= render_time:
		snapshots.pop_front()
	var a: Dictionary = snapshots[0]
	var b: Dictionary = snapshots[mini(1, snapshots.size() - 1)]
	var span := float(b.time) - float(a.time)
	var weight := clampf((render_time - float(a.time)) / span, 0.0, 1.0) if span > 0.0 else 1.0
	var newest: Dictionary = snapshots[-1]
	car.distance_driven = newest.distance
	car.run_state = newest.run_state
	car.crash_reason = newest.crash_reason
	car.run_id = newest.run_id
	car.on_road = newest.on_road
	car.impact_strength = newest.impact
	car.punctured_tires = newest.tires
	car.update_tire_visuals()
	police.apply_snapshot(a.police, b.police, weight)
	# The crossing clock runs while the ride does: carry it forward to the driver's now.
	var clock_ahead := clampf(driver_now - float(newest.time), 0.0, 0.5) if newest.run_state == "driving" else 0.0
	world.set_challenge_time(float(newest.challenge_time) + clock_ahead)
	for light: SpotLight3D in car.headlights:
		light.visible = newest.lights
	if newest.has("damage"):
		car.damage.set_health_array(newest.damage)
	_animate_wheels(delta)

func _animate_wheels(delta: float) -> void:
	car.wheel_spin += car.signed_speed * delta / car.WHEEL_RADIUS
	car.steering_wheel.rotation.z = car.steering * 1.9
	car.update_wheel_visuals()
