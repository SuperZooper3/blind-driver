extends Node
## Peer-to-peer link between two browser games over WebRTC, so game data skips the
## relay. The relay only carries the negotiation (session descriptions and ICE
## candidates). Works on the same network via host candidates, and often across the
## internet via a public STUN server; if it never connects, the relay keeps working.
##
## Two data channels, agreed in advance (negotiated ids, no extra round trip):
## "fast" is unordered with no retransmits, like UDP, for poses and snapshots: a late
## message never holds up newer ones, which removes the relay's stall-then-burst lag.
## "sure" is reliable and ordered, for the road map.
##
## Same interface as DirectLink (send, is_linked, link_changed, message_received…).
## Desktop Godot has no built-in WebRTC; there `available()` is false.

signal message_received(message: Dictionary)
signal link_changed(address: String)
## A negotiation message for the partner, to send through the relay.
signal signal_ready(message: Dictionary)

## Public STUN lets two browsers on different networks find each other. Players on
## the same network don't need it.
const ICE_SERVERS := [{"urls": ["stun:stun.l.google.com:19302"]}]
const CONNECT_TIMEOUT := 12.0
const SILENCE_LIMIT := 3.0
const RETRY_SECONDS := 6.0

var enabled := false
var initiator := false
var peer: WebRTCPeerConnection
var fast: WebRTCDataChannel
var sure: WebRTCDataChannel
## Each negotiation attempt has a number, so late signals from an old attempt are ignored.
var attempt := 0
var linked := false
var started_at := 0.0
var heard_at := 0.0
var last_sent := 0.0
var retry_at := -1.0
var received_count := 0
var pending_candidates: Array[Dictionary] = []

## Browsers always have WebRTC. Desktop Godot only does with the optional
## webrtc-native plugin installed (its peer class is WebRTCLibPeerConnection);
## without it, Godot would pretend to initialize and never connect.
static func available() -> bool:
	return OS.has_feature("web") or ClassDB.class_exists("WebRTCLibPeerConnection")

func now() -> float:
	return Time.get_ticks_msec() / 1000.0

## Start negotiating. The initiator makes the offer; the other side answers it.
func begin(as_initiator: bool) -> void:
	stop()
	enabled = true
	initiator = as_initiator
	if initiator:
		_open(attempt + 1)
		peer.create_offer()

func stop() -> void:
	var was_linked := linked
	enabled = false
	linked = false
	retry_at = -1.0
	pending_candidates.clear()
	if peer != null:
		peer.close()
	peer = null
	fast = null
	sure = null
	if was_linked:
		link_changed.emit("")

func is_linked() -> bool:
	return linked

func partner_address() -> String:
	return "peer-to-peer (WebRTC)" if linked else ""

func buffered_bytes() -> int:
	return 0

## Short human-readable state for diagnostics (browser status object, logs).
func debug_state() -> String:
	if not enabled:
		return "off"
	if peer == null:
		return "waiting (attempt %d, %s)" % [attempt, "will retry" if initiator else "waiting for offer"]
	var names := ["new", "connecting", "connected", "disconnected", "failed", "closed"]
	var channel := func(c: WebRTCDataChannel) -> String: return "none" if c == null else ["connecting", "open", "closing", "closed"][c.get_ready_state()]
	return "%s attempt %d: %s, fast %s, sure %s" % ["offerer" if initiator else "answerer", attempt, names[peer.get_connection_state()], channel.call(fast), channel.call(sure)]

func _open(number: int) -> void:
	if peer != null:
		peer.close()
	attempt = number
	linked = false
	started_at = now()
	heard_at = started_at
	pending_candidates.clear()
	var connection := WebRTCPeerConnection.new()
	peer = connection
	connection.initialize({"iceServers": ICE_SERVERS})
	# Callbacks from a replaced attempt must not touch the current one.
	connection.session_description_created.connect(func(type: String, sdp: String):
		if connection != peer:
			return
		connection.set_local_description(type, sdp)
		signal_ready.emit({"kind": type, "link": number, "sdp": sdp}))
	connection.ice_candidate_created.connect(func(mid: String, index: int, name: String):
		if connection == peer:
			signal_ready.emit({"kind": "ice", "link": number, "mid": mid, "index": index, "name": name}))
	fast = connection.create_data_channel("fast", {"negotiated": true, "id": 1, "ordered": false, "maxRetransmits": 0})
	sure = connection.create_data_channel("sure", {"negotiated": true, "id": 2})

## A negotiation message from the partner, via the relay.
func handle_signal(message: Dictionary) -> void:
	if not enabled:
		return
	var number := int(message.get("link", 0))
	match str(message.get("kind", "")):
		"offer":
			if initiator:
				return
			# A new offer (first try or a retry) replaces any older attempt; keep any
			# of its candidates that arrived first.
			var early := pending_candidates.duplicate()
			_open(number)
			pending_candidates = early
			peer.set_remote_description("offer", str(message.sdp))
			_flush_candidates()
		"answer":
			if initiator and peer != null and number == attempt:
				peer.set_remote_description("answer", str(message.sdp))
				_flush_candidates()
		"ice":
			if peer == null or number != attempt:
				if not initiator and number > attempt:
					# Candidates can overtake their offer; keep them for it.
					pending_candidates.append(message)
				return
			peer.add_ice_candidate(str(message.mid), int(message.index), str(message.name))

func _flush_candidates() -> void:
	for message: Dictionary in pending_candidates:
		if int(message.link) == attempt:
			peer.add_ice_candidate(str(message.mid), int(message.index), str(message.name))
	pending_candidates.clear()

func send(message: Dictionary) -> bool:
	if not linked:
		return false
	var channel := sure if message.get("type", "") == "graph" else fast
	if channel == null or channel.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		return false
	return channel.put_packet(JSON.stringify(message).to_utf8_buffer()) == OK

func _process(_delta: float) -> void:
	if not enabled:
		return
	var time := now()
	if peer == null:
		if initiator and retry_at >= 0.0 and time >= retry_at:
			retry_at = -1.0
			_open(attempt + 1)
			peer.create_offer()
		return
	peer.poll()
	var open := fast != null and sure != null and fast.get_ready_state() == WebRTCDataChannel.STATE_OPEN and sure.get_ready_state() == WebRTCDataChannel.STATE_OPEN
	if open and not linked:
		linked = true
		heard_at = time
		link_changed.emit(partner_address())
	for channel in [fast, sure]:
		while channel != null and channel.get_available_packet_count() > 0:
			var decoded: Variant = JSON.parse_string(channel.get_packet().get_string_from_utf8())
			heard_at = time
			if decoded is Dictionary and decoded.get("type", "") != "direct_ping":
				received_count += 1
				message_received.emit(decoded)
	if linked and time - last_sent > 0.5:
		# Keep both directions visibly alive, even for the navigator who sends no game data.
		last_sent = time
		fast.put_packet(JSON.stringify({"type": "direct_ping"}).to_utf8_buffer())
	var state := peer.get_connection_state()
	var failed := state in [WebRTCPeerConnection.STATE_FAILED, WebRTCPeerConnection.STATE_CLOSED] \
		or (linked and time - heard_at > SILENCE_LIMIT) or (not linked and time - started_at > CONNECT_TIMEOUT)
	if failed:
		_drop()

func _drop() -> void:
	var was_linked := linked
	linked = false
	if peer != null:
		peer.close()
	peer = null
	fast = null
	sure = null
	# The initiator starts a fresh negotiation after a pause; the other side waits for it.
	retry_at = now() + RETRY_SECONDS
	if was_linked:
		link_changed.emit("")
