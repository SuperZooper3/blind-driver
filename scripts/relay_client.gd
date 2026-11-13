extends Node
## Outbound WSS transport with resumable seats, application heartbeats and diagnostics.
signal room_created(code: String)
signal joined
signal navigator_joined
signal navigator_left
signal graph_received(roads: Array)
signal snapshot_received(state: Dictionary)
signal failed(message: String)
signal recovering(message: String)
signal restored(peer_connected: bool)
signal peer_waiting
signal peer_restored
signal check_updated(message: String)
signal check_finished(message: String)

const Wire = preload("res://scripts/wire_protocol.gd")
const Log = preload("res://scripts/network_log.gd")
const VERSION := 2
const RECOVERY_SECONDS := 120.0
var socket: WebSocketPeer
var active := false
var is_ready := false
var handshake_sent := false
var intent := "create"
var room_code := ""
var token := ""
var seat_role := ""
var url := ""
var started_at := 0.0
var attempt_started := 0.0
var outage_started := -1.0
var next_attempt := 0.0
var retry_count := 0
var reconnects := 0
var last_received := 0.0
var last_pong := 0.0
var last_ping := 0.0
var ping_id := 0
var pending: Dictionary = {}
var rtts: Array[float] = []
var probes_sent := 0
var probes_missed := 0
var last_poll := 0.0
var max_poll_gap := 0.0
var last_summary := 0.0
var close_code := 0
var close_reason := ""
var check_started := 0.0
var check_duration := 75.0
var check_samples := 0
var backpressure_since := -1.0

func now() -> float:
	return Time.get_ticks_msec() / 1000.0

func start(address: String, action: String, code: String = "") -> Error:
	stop()
	intent = action
	url = normalize_url(address)
	if url.is_empty():
		_fail("Enter a relay address starting with https:// or wss://.")
		return ERR_INVALID_PARAMETER
	intent = action
	room_code = code.strip_edges().replace("-", "").to_upper()
	if intent == "join" and (room_code.length() != 18 or not room_code.is_valid_hex_number(false)):
		_fail("Paste the 18-character room code from the driver.")
		return ERR_INVALID_PARAMETER
	token = ""
	seat_role = ""
	retry_count = 0
	reconnects = 0
	outage_started = -1.0
	pending.clear()
	rtts.clear()
	probes_sent = 0
	probes_missed = 0
	max_poll_gap = 0.0
	last_poll = 0.0
	close_code = 0
	close_reason = ""
	check_started = 0.0
	check_samples = 0
	started_at = now()
	last_summary = started_at
	active = true
	Log.event("connection_start", {"mode": intent, "protocol": VERSION})
	_connect()
	return OK

static func normalize_url(address: String) -> String:
	var result := address.strip_edges().trim_suffix("/")
	if result.begins_with("https://"):
		result = "wss://" + result.trim_prefix("https://")
	elif result.begins_with("http://"):
		result = "ws://" + result.trim_prefix("http://")
	if not result.begins_with("ws://") and not result.begins_with("wss://"):
		return ""
	var authority := result.get_slice("://", 1)
	if authority.is_empty() or authority.contains(" ") or authority.contains("?") or authority.contains("#") or authority.contains("@"):
		return ""
	if not authority.contains("/"):
		result += "/ws"
	return result

func _connect() -> void:
	is_ready = false
	handshake_sent = false
	socket = WebSocketPeer.new()
	socket.inbound_buffer_size = 1048576
	socket.outbound_buffer_size = 1048576
	socket.max_queued_packets = 256
	attempt_started = now()
	last_received = attempt_started
	last_pong = attempt_started
	last_ping = 0.0
	backpressure_since = -1.0
	Log.event("connect_attempt", {"attempt": retry_count + 1, "resuming": not token.is_empty()})
	var error := socket.connect_to_url(url)
	if error != OK:
		_lost("Could not open relay socket", error)

func stop() -> void:
	if active:
		Log.event("connection_stop", {"mode": intent})
	active = false
	is_ready = false
	handshake_sent = false
	if socket != null:
		if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			socket.send_text(JSON.stringify({"type": "leave"}))
			socket.poll()
		socket.close(1000, "Leaving room")
	socket = null
	token = ""
	pending.clear()

func _exit_tree() -> void:
	stop()

func _process(_delta: float) -> void:
	if not active:
		return
	var time := now()
	if last_poll > 0.0:
		var gap := time - last_poll
		max_poll_gap = maxf(max_poll_gap, gap)
		if gap > 1.0:
			Log.event("client_poll_stall", {"gap_ms": roundi(gap * 1000)})
	last_poll = time
	if outage_started >= 0.0 and time - outage_started >= RECOVERY_SECONDS:
		_fail("Could not restore the connection within 2 minutes. Check the connection and create a new room.")
		return
	if intent == "check" and check_started > 0.0 and time - check_started >= check_duration:
		_finish_check()
		return
	if socket == null:
		if time >= next_attempt:
			_connect()
		return
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not handshake_sent:
			handshake_sent = true
			var hello := {"type": intent, "version": VERSION, "room": room_code}
			if not token.is_empty():
				hello = {"type": "resume", "version": VERSION, "room": room_code, "token": token, "role": seat_role}
			_send(hello)
		var count := 0
		while active and socket != null and socket.get_available_packet_count() > 0 and count < 128:
			count += 1
			var packet := socket.get_packet()
			if packet.size() > 524288:
				_fail("Relay sent an oversized message.")
				return
			var decoded: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if not decoded is Dictionary:
				_fail("Relay sent an invalid message.")
				return
			last_received = time
			_handle(decoded)
		if not active or socket == null:
			return
		if not is_ready and time - attempt_started > 90.0:
			_lost("Room handshake timed out")
			return
		if is_ready:
			for id in pending.keys():
				if time - float(pending[id]) > 5.0:
					pending.erase(id)
					probes_missed += 1
					Log.event("probe_missed", {"id": id})
			if time - last_pong > 15.0:
				_lost("No heartbeat reply for 15 seconds")
				return
			if buffered_bytes() > 65536:
				if backpressure_since < 0.0:
					backpressure_since = time
				if time - backpressure_since > 10.0:
					_lost("Outbound connection stalled")
					return
			else:
				backpressure_since = -1.0
			if time - last_ping >= (1.0 if intent == "check" else 2.0):
				# Leave five seconds for the final diagnostic replies.
				if intent != "check" or time - check_started < check_duration - 5.0:
					ping_id += 1
					if _send({"type": "ping", "id": ping_id}):
						pending[ping_id] = time
						probes_sent += 1
				last_ping = time
	elif state == WebSocketPeer.STATE_CLOSED:
		close_code = socket.get_close_code()
		close_reason = socket.get_close_reason().left(120)
		Log.event("socket_closed", {"code": close_code, "reason": close_reason})
		if close_code in [1008, 1009, 4001]:
			_fail("Server closed the connection (%d): %s. See network logs." % [close_code, close_reason])
		else:
			_lost("Socket closed (%d): %s" % [close_code, close_reason])
	elif time - attempt_started > 90.0:
		_lost("Relay connection timed out")
	if active and time - last_summary >= 10.0:
		last_summary = time
		Log.event("connection_summary", metrics())
	if intent == "check" and active:
		check_updated.emit(check_report())

func _handle(message: Dictionary) -> void:
	var type := str(message.get("type", ""))
	match type:
		"created", "joined", "resumed", "check_ready":
			if message.get("version") != VERSION:
				_fail("Relay protocol differs. Deploy the updated relay and update both games.")
				return
			if type != "check_ready":
				if typeof(message.get("room")) != TYPE_STRING or str(message.room).length() != 18 or typeof(message.get("token")) != TYPE_STRING or str(message.token).length() != 64:
					_fail("Relay sent invalid room credentials.")
					return
				room_code = message.room
				token = message.token
				seat_role = message.get("role", "")
			is_ready = true
			outage_started = -1.0
			retry_count = 0
			last_pong = now()
			Log.event(type, {"role": seat_role, "peer_connected": message.get("peer_connected", false), "connection": message.get("connection", ""), "instance": message.get("instance", "")})
			match type:
				"created": room_created.emit(room_code)
				"joined": joined.emit()
				"resumed": restored.emit(bool(message.get("peer_connected", false)))
				"check_ready":
					if check_started == 0.0:
						check_started = now()
		"pong":
			var id := int(message.get("id", -1))
			if pending.has(id):
				var rtt := (now() - float(pending[id])) * 1000.0
				pending.erase(id)
				rtts.append(rtt)
				check_samples += 1
				if rtts.size() > 300:
					rtts.pop_front()
				last_pong = now()
		"navigator_joined": navigator_joined.emit()
		"navigator_left": navigator_left.emit()
		"peer_reconnecting":
			Log.event("peer_reconnecting", {"role": message.get("role", "")})
			peer_waiting.emit()
		"peer_restored": peer_restored.emit()
		"graph":
			if not message.get("roads") is Array:
				_fail("Invalid road data from relay.")
				return
			var roads := Wire.graph_from_json(message.get("roads", []))
			if roads.is_empty():
				_fail("Invalid road data from relay.")
			else:
				graph_received.emit(roads)
		"snapshot":
			if not message.get("state") is Dictionary:
				_fail("Invalid car state from relay.")
				return
			var snapshot := Wire.snapshot_from_json(message.get("state", {}))
			if snapshot.is_empty():
				_fail("Invalid car state from relay.")
			else:
				snapshot_received.emit(snapshot)
		"error", "room_closed":
			Log.event("server_rejected", {"code": message.get("code", type)})
			_fail(str(message.get("message", "Room closed. Create a new room.")))

func _send(message: Dictionary) -> bool:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var error := socket.send_text(JSON.stringify(message))
	if error != OK:
		_lost("Sending to relay failed", error)
		return false
	return true

func send_graph(roads: Array) -> bool:
	return is_ready and _send({"type": "graph", "roads": Wire.graph_to_json(roads)})

func send_snapshot(state: Dictionary) -> bool:
	return is_ready and _send({"type": "snapshot", "state": Wire.snapshot_to_json(state)})

func buffered_bytes() -> int:
	return socket.get_current_outbound_buffered_amount() if socket != null else 0

func _lost(reason: String, error: int = 0) -> void:
	if not active:
		return
	is_ready = false
	if socket != null:
		socket.close(1000, "Reconnecting")
	socket = null
	probes_missed += pending.size()
	pending.clear()
	if outage_started < 0.0:
		outage_started = now()
	retry_count += 1
	reconnects += 1
	var delay := minf(8.0, pow(2.0, mini(retry_count - 1, 4))) + randf_range(0.0, 0.4)
	next_attempt = now() + delay
	Log.event("reconnect_scheduled", {"reason": reason, "error": error, "attempt": retry_count, "delay_seconds": delay})
	recovering.emit("RECONNECTING / RETRY %d IN %.1f s" % [retry_count, delay])

func metrics() -> Dictionary:
	var ordered := rtts.duplicate()
	ordered.sort()
	var p50: float = ordered[int((ordered.size() - 1) * 0.5)] if not ordered.is_empty() else 0.0
	var p95: float = ordered[int((ordered.size() - 1) * 0.95)] if not ordered.is_empty() else 0.0
	var jitter := 0.0
	for i in range(1, rtts.size()):
		jitter += absf(rtts[i] - rtts[i - 1])
	jitter /= maxf(1.0, rtts.size() - 1)
	return {"ready": is_ready, "rtt_ms": roundi(p50), "p95_ms": roundi(p95), "jitter_ms": roundi(jitter), "replies": check_samples, "sent": probes_sent, "missed": probes_missed, "reconnects": reconnects, "max_poll_gap_ms": roundi(max_poll_gap * 1000.0), "buffered_bytes": buffered_bytes(), "last_close_code": close_code}

func check_report() -> String:
	var data := metrics()
	var elapsed := now() - check_started if check_started > 0.0 else 0.0
	return "CHECK %.0f / %.0f s · %d replies · %d missed\nLatency %d ms · p95 %d ms · jitter %d ms\nReconnects %d · largest frame gap %d ms" % [minf(elapsed, check_duration), check_duration, data.replies, data.missed, data.rtt_ms, data.p95_ms, data.jitter_ms, data.reconnects, data.max_poll_gap_ms]

func _finish_check() -> void:
	probes_missed += pending.size()
	pending.clear()
	var report := check_report()
	var clean := reconnects == 0 and probes_missed == 0 and check_samples >= int((check_duration - 5.0) * 0.8)
	report += "\n" + ("No interruption observed during this check." if clean else "Interruptions or too few replies. See network logs.")
	Log.event("check_finished", metrics())
	stop()
	check_finished.emit(report)

func _fail(message: String) -> void:
	Log.event("connection_failed", {"message": message})
	var checking := intent == "check"
	stop()
	if checking:
		check_finished.emit(message)
	else:
		failed.emit(message)
