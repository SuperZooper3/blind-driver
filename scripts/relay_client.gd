extends Node
## Outbound-only WSS client. Both players connect to Render; neither hosts a port.

signal room_created(code: String)
signal joined
signal navigator_joined
signal navigator_left
signal graph_received(roads: Array)
signal snapshot_received(state: Dictionary)
signal failed(message: String)

const Wire = preload("res://scripts/wire_protocol.gd")
var socket: WebSocketPeer
var active := false
var handshake_sent := false
var intent := "create"
var room_code := ""
var started_at := 0.0

func start(address: String, action: String, code: String = "") -> Error:
	stop()
	var url := normalize_url(address)
	if url.is_empty():
		failed.emit("Enter the relay address from Render, starting with https:// or wss://.")
		return ERR_INVALID_PARAMETER
	intent = action
	room_code = code.strip_edges().replace("-", "").to_upper()
	if intent == "join" and room_code.length() != 18:
		failed.emit("Paste the 18-character room code from the driver.")
		return ERR_INVALID_PARAMETER
	socket = WebSocketPeer.new()
	socket.inbound_buffer_size = 1048576
	socket.outbound_buffer_size = 1048576
	socket.max_queued_packets = 128
	var error := socket.connect_to_url(url)
	if error != OK:
		failed.emit("Could not open the relay address. Check the URL.")
		return error
	active = true
	started_at = Time.get_ticks_msec() / 1000.0
	return OK

static func normalize_url(address: String) -> String:
	var url := address.strip_edges().trim_suffix("/")
	if url.begins_with("https://"):
		url = "wss://" + url.trim_prefix("https://")
	elif url.begins_with("http://"):
		url = "ws://" + url.trim_prefix("http://")
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		return ""
	var authority := url.get_slice("://", 1)
	if authority.is_empty() or authority.contains(" ") or authority.contains("?") or authority.contains("#"):
		return ""
	if not authority.contains("/"):
		url += "/ws"
	return url

func stop() -> void:
	active = false
	handshake_sent = false
	if socket != null:
		socket.close(1000, "Leaving room")
	socket = null

func _process(_delta: float) -> void:
	if not active or socket == null:
		return
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not handshake_sent:
			handshake_sent = true
			_send({"type": intent, "version": 1, "room": room_code})
		var count := 0
		while active and socket != null and socket.get_available_packet_count() > 0 and count < 64:
			count += 1
			var packet := socket.get_packet()
			if packet.size() > 524288:
				_fail("Relay sent an oversized message.")
				return
			var decoded: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if not decoded is Dictionary:
				_fail("Relay sent an invalid message.")
				return
			_handle(decoded)
	elif state == WebSocketPeer.STATE_CLOSED:
		_fail("Relay disconnected. Check the address, wake /healthz, then create or rejoin a room.")
	elif Time.get_ticks_msec() / 1000.0 - started_at > 90.0:
		_fail("Relay timed out. Open its /healthz page to wake it, then retry.")

func _handle(message: Dictionary) -> void:
	match message.get("type", ""):
		"created":
			if typeof(message.get("room")) != TYPE_STRING or message.room.length() != 18 or message.get("version") != 1:
				_fail("Relay protocol version differs from this game.")
				return
			room_code = message.room
			room_created.emit(room_code)
		"joined":
			if message.get("version") != 1:
				_fail("Relay protocol version differs from this game.")
				return
			joined.emit()
		"navigator_joined":
			navigator_joined.emit()
		"navigator_left":
			navigator_left.emit()
		"graph":
			if not message.get("roads") is Array:
				_fail("Invalid road data from relay.")
				return
			var roads := Wire.graph_from_json(message.roads)
			if roads.is_empty():
				_fail("Invalid road data from relay.")
			else:
				graph_received.emit(roads)
		"snapshot":
			if not message.get("state") is Dictionary:
				_fail("Invalid car state from relay.")
				return
			var snapshot := Wire.snapshot_from_json(message.state)
			if snapshot.is_empty():
				_fail("Invalid car state from relay.")
			else:
				snapshot_received.emit(snapshot)
		"error", "room_closed":
			_fail(str(message.get("message", "Room closed. Create a new room.")))

func _send(message: Dictionary) -> void:
	if socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))

func send_graph(roads: Array) -> void:
	_send({"type": "graph", "roads": Wire.graph_to_json(roads)})

func send_snapshot(state: Dictionary) -> void:
	_send({"type": "snapshot", "state": Wire.snapshot_to_json(state)})

func buffered_bytes() -> int:
	return socket.get_current_outbound_buffered_amount() if socket != null else 0

func _fail(message: String) -> void:
	stop()
	failed.emit(message)
