extends SceneTree
const Settings = preload("res://scripts/lobby_settings.gd")
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition
func _run() -> void:
	var path := "user://lobby-check-%d.cfg" % OS.get_process_id()
	var old := ConfigFile.new()
	old.set_value("unrelated", "preserve", "yes")
	old.save(path)
	check(Settings.write("http://127.0.0.1:12345", "forest-friends", "navigator", path) == OK, "lobby preferences save locally")
	var restored := Settings.read(path)
	check(restored.name == "forest-friends" and restored.seat == "navigator" and restored.address == "http://127.0.0.1:12345", "name, seat, and server survive a fresh settings load")
	old.load(path)
	check(old.get_value("unrelated", "preserve") == "yes", "saving a lobby preserves unrelated preferences")
	check(Settings.normalize_name(" Forest  Friends ") == "forest-friends" and Settings.normalize_name("bad/name").is_empty(), "friendly names normalize consistently and invalid names are rejected")
	var game = load("res://scenes/main.tscn").instantiate()
	# Window events can arrive while _ready() is still constructing the world,
	# before the UI exists. Exercise the real viewport input dispatch at that point.
	var startup_input := {"sent": false}
	var diagnostics_key := InputEventKey.new()
	diagnostics_key.physical_keycode = KEY_F8
	diagnostics_key.pressed = true
	game.child_entered_tree.connect(func(child: Node):
		if child.name == "World":
			check(game.ui == null, "startup input arrives before the menu is constructed")
			root.push_input(InputEventMouseMotion.new())
			root.push_input(diagnostics_key)
			startup_input.sent = true)
	root.add_child(game)
	check(startup_input.sent and game.is_node_ready() and not game.ui.diagnostics_panel.visible, "startup completes with early mouse and keyboard input ignored")
	root.push_input(diagnostics_key)
	check(game.ui.diagnostics_panel.visible, "F8 opens diagnostics after startup")
	root.push_input(diagnostics_key)
	game.ui._load_preferences(path)
	check(game.ui.preferred_seat == "navigator", "start screen remembers the preferred seat")
	check(game.ui.room_code_field.is_visible_in_tree() and game.ui.create_room_button.is_visible_in_tree() and not game.ui.share_box.visible, "start screen offers Create a room and a room-code box")
	var Relay = preload("res://scripts/relay_client.gd")
	check(Relay.normalize_share(" k7q-4mz ") == "K7Q4MZ" and Relay.normalize_share("K7Q4M0").is_empty() and Relay.normalize_share("ABC").is_empty(), "typed codes forgive case, spaces and dashes but reject lookalikes and wrong lengths")
	game.ui.room_code_field.text = "nope"
	game.ui._join_room()
	check(not game.ui.connecting and game.ui.online_status.text.contains("6 letters"), "a malformed code is explained instead of contacting the server")
	game.ui.display_lobby_ready("K7Q4MZ")
	check(game.ui.share_box.visible and game.ui.room_code_label.text == "K7Q4MZ", "a created room shows its code to share")
	check(not game.ui.relay_address.is_visible_in_tree() and not game.ui.address.is_visible_in_tree(), "connection URLs and LAN addresses are absent from the start screen")
	check(not InputMap.has_action("recover"), "keyboard and gamepad recovery action is removed")
	var Version = preload("res://scripts/version.gd")
	check(game.ui.version_label.text.contains(Version.label()) and Version.label() == "PROTOTYPE %02d" % Version.PROTOTYPE, "the start screen shows the prototype number")
	check(game.ui.direct_toggle.is_visible_in_tree(), "the direct connection switch is on the start screen")
	game._check_partner_build(Version.PROTOTYPE - 1)
	check(game.ui.version_label.text.contains("PROTOTYPE %02d" % (Version.PROTOTYPE - 1)) and game.ui.online_status.text.contains("update"), "a partner on another version is called out")
	game._check_partner_build(-1)
	check(game.ui.version_label.text.contains("older version"), "a partner from before version numbers is called out too")
	game.car.remote = true
	game.car.freeze = true
	game.car.signed_speed = 25.0
	game.car.distance_driven = 1234.56
	await process_frame
	await process_frame
	check(is_equal_approx(game.ui.dashboard.speed_kmh, 90.0) and is_equal_approx(game.ui.dashboard.distance_km, 1.23456), "gauge and trip odometer use shared car speed and distance")
	game.ui.set_online_busy(true)
	game._leave_online()
	check(game.ui.room_code_field.editable and not game.ui.share_box.visible and game.ui.preferred_seat == "navigator", "leaving or cancelling clears the room but keeps the seat choice")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
