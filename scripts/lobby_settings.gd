extends RefCounted
## Per-computer convenience settings; no room credentials or saved simulation state.
const PATH := "user://network.cfg"
const DEFAULT_RELAY := "https://blind-driver-relay.onrender.com"

static func read(path: String = PATH) -> Dictionary:
	var config := ConfigFile.new()
	config.load(path)
	return {"address": str(config.get_value("relay", "address", DEFAULT_RELAY)), "name": str(config.get_value("lobby", "name", "")), "seat": str(config.get_value("lobby", "seat", "driver")), "direct": bool(config.get_value("lobby", "direct", false))}

static func write(address: String, lobby: String, seat: String, path: String = PATH, direct: bool = false) -> Error:
	var config := ConfigFile.new()
	config.load(path)
	config.set_value("relay", "address", address.strip_edges())
	config.set_value("lobby", "name", lobby.strip_edges())
	config.set_value("lobby", "seat", seat)
	config.set_value("lobby", "direct", direct)
	return config.save(path)

static func normalize_name(value: String) -> String:
	if value.length() > 40:
		return ""
	var pattern := RegEx.new()
	pattern.compile("^[A-Za-z0-9 -]+$")
	if pattern.search(value) == null:
		return ""
	var spaces := RegEx.new()
	spaces.compile("[ -]+")
	var result := spaces.sub(value.strip_edges().to_lower(), "-", true)
	if result.length() < 3 or result.begins_with("-") or result.ends_with("-"):
		return ""
	return result
