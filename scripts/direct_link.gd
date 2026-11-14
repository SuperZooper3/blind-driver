extends Node
## Optional direct connection between the two players' computers on the same local
## network, so game traffic skips the internet relay. The relay is still used to find
## each other: each side sends its local IPv4 addresses, listening port and a random
## key through it (see Session.set_direct).
##
## Both computers listen and both try to connect, because home and office networks are
## often one-way (a Mac with its firewall in stealth mode accepts nothing inbound but
## can still connect out). The link opened by the side with the smaller key is
## preferred, so both games settle on the same one; if that direction is blocked,
## the other direction is used. Messages are the relay's JSON (pose, snapshot, graph).
##
## Not secure: the key only stops connecting to the wrong game, and traffic is not
## encrypted. It is meant for two friends on one network.

signal message_received(message: Dictionary)
## `address` is the partner's IP on success, "" when the link is lost.
signal link_changed(address: String)

const PORT_FIRST := 18770
const PORT_LAST := 18779
## How long the non-preferred direction waits before giving up on the preferred one.
const PREFER_WAIT := 1.0
## Nothing heard over the link for this long means it is dead.
const SILENCE_LIMIT := 3.0
const RETRY_SECONDS := 8.0

var enabled := false
var server: TCPServer
var port := 0
var my_key := ""
var partner_key := ""
var partner_addresses: PackedStringArray = []
var partner_port := 0
## Every connection in progress or open: {peer, address, outgoing, verified, opened_at, heard_at}.
var links: Array[Dictionary] = []
var active: Dictionary = {}
var retry_at := 0.0
var listening_allowed := true
## Game messages received over the link (diagnostics and tests).
var received_count := 0

func now() -> float:
	return Time.get_ticks_msec() / 1000.0

## Open the listener. Returns the offer to send to the partner, or {} if unavailable.
func start() -> Dictionary:
	stop()
	if OS.has_feature("web"):
		return {}
	enabled = true
	var bytes := Crypto.new().generate_random_bytes(16)
	my_key = bytes.hex_encode()
	# Tests can simulate a computer whose firewall refuses all incoming connections.
	listening_allowed = OS.get_environment("BLIND_DRIVER_DIRECT_NO_LISTEN") != "1"
	if listening_allowed:
		server = TCPServer.new()
		for candidate in range(PORT_FIRST, PORT_LAST + 1):
			if server.listen(candidate, "*") == OK:
				port = candidate
				break
		if port == 0:
			server = null
	return {"addrs": local_addresses(), "port": port, "key": my_key}

func stop() -> void:
	var had_link := not active.is_empty()
	enabled = false
	for link: Dictionary in links:
		link.peer.close(1000, "Direct link off")
	links.clear()
	active = {}
	if server != null:
		server.stop()
	server = null
	port = 0
	partner_key = ""
	partner_addresses = []
	partner_port = 0
	if had_link:
		link_changed.emit("")

func is_linked() -> bool:
	return not active.is_empty()

func partner_address() -> String:
	return "" if active.is_empty() else str(active.address)

## The partner's offer arrived through the relay: try their addresses.
func set_partner(addresses: Array, partner_port_number: int, key: String) -> void:
	partner_addresses = PackedStringArray(addresses)
	partner_port = partner_port_number
	partner_key = key
	retry_at = 0.0

## Private IPv4 addresses on this computer, most likely LAN first.
static func local_addresses() -> PackedStringArray:
	var result: PackedStringArray = []
	if OS.get_environment("BLIND_DRIVER_DIRECT_LOOPBACK") == "1":
		result.append("127.0.0.1")
	for address in IP.get_local_addresses():
		if is_private_ipv4(address) and not result.has(address):
			result.append(address)
	return result.slice(0, 8)

static func is_private_ipv4(address: String) -> bool:
	var parts := address.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if not part.is_valid_int() or int(part) < 0 or int(part) > 255:
			return false
	var a := int(parts[0])
	var b := int(parts[1])
	return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254)

## The side with the smaller key connects in the preferred direction.
func _preferred(link: Dictionary) -> bool:
	return link.outgoing == (my_key < partner_key)

func send(message: Dictionary) -> bool:
	if active.is_empty() or active.peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return active.peer.send_text(JSON.stringify(message)) == OK

func buffered_bytes() -> int:
	return 0 if active.is_empty() else active.peer.get_current_outbound_buffered_amount()

func _process(_delta: float) -> void:
	if not enabled:
		return
	var time := now()
	_accept_incoming(time)
	if active.is_empty() and partner_port > 0 and not partner_key.is_empty() and time >= retry_at:
		retry_at = time + RETRY_SECONDS
		_dial(time)
	for link: Dictionary in links.duplicate():
		_poll(link, time)
	_choose(time)
	if not active.is_empty() and time - float(active.last_sent) > 0.5:
		# Keep the link visibly alive in both directions, even for the navigator.
		send({"type": "direct_ping"})
		active.last_sent = time

func _accept_incoming(time: float) -> void:
	while server != null and server.is_connection_available():
		var stream := server.take_connection()
		var peer := WebSocketPeer.new()
		if peer.accept_stream(stream) == OK:
			links.append({"peer": peer, "address": stream.get_connected_host(), "outgoing": false, "verified": false, "opened_at": time, "heard_at": time, "last_sent": time})

func _dial(time: float) -> void:
	for address in partner_addresses:
		var already := false
		for link: Dictionary in links:
			already = already or (link.outgoing and link.address == address)
		if already:
			continue
		var peer := WebSocketPeer.new()
		if peer.connect_to_url("ws://%s:%d/" % [address, partner_port]) == OK:
			links.append({"peer": peer, "address": address, "outgoing": true, "verified": false, "opened_at": time, "heard_at": time, "last_sent": time, "hello_sent": false})

func _poll(link: Dictionary, time: float) -> void:
	var peer: WebSocketPeer = link.peer
	peer.poll()
	var state := peer.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED or (not link.verified and time - float(link.opened_at) > 4.0) or (link.verified and time - float(link.heard_at) > SILENCE_LIMIT):
		_drop(link)
		return
	if state != WebSocketPeer.STATE_OPEN:
		return
	if link.outgoing and not link.get("hello_sent", false):
		link.hello_sent = true
		peer.set_no_delay(true)
		# Prove we are the partner the relay introduced: echo the key they advertised.
		peer.send_text(JSON.stringify({"type": "direct_hello", "key": partner_key}))
	var count := 0
	while peer.get_available_packet_count() > 0 and count < 256:
		count += 1
		var decoded: Variant = JSON.parse_string(peer.get_packet().get_string_from_utf8())
		if not decoded is Dictionary:
			continue
		var message: Dictionary = decoded
		link.heard_at = time
		match str(message.get("type", "")):
			"direct_hello":
				if not link.outgoing and str(message.get("key", "")) == my_key:
					link.verified = true
					peer.set_no_delay(true)
					peer.send_text(JSON.stringify({"type": "direct_welcome"}))
				elif not link.outgoing:
					_drop(link)
					return
			"direct_welcome":
				if link.outgoing:
					link.verified = true
			"direct_ping":
				pass
			_:
				if link.verified:
					received_count += 1
					message_received.emit(message)

func _choose(time: float) -> void:
	var best: Dictionary = {}
	for link: Dictionary in links:
		if not link.verified:
			continue
		if _preferred(link):
			best = link
			break
		# The other direction only takes over if the preferred one has not appeared.
		if best.is_empty() and (time - float(link.opened_at) >= PREFER_WAIT or not active.is_empty() and active == link):
			best = link
	if best.is_empty() or best == active:
		return
	active = best
	# Close the spares so both games end up on the same connection.
	for link: Dictionary in links.duplicate():
		if link != active and link.verified:
			link.peer.close(1000, "Duplicate direct link")
			links.erase(link)
	link_changed.emit(str(active.address))

func _drop(link: Dictionary) -> void:
	link.peer.close()
	links.erase(link)
	if link == active:
		active = {}
		retry_at = now() + 1.0
		link_changed.emit("")
