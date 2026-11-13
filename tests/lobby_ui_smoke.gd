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
	root.add_child(game)
	game.ui._load_preferences(path)
	check(game.ui.lobby_name.text == "forest-friends" and game.ui.preferred_seat == "navigator", "start screen pre-fills the saved lobby and remembers the seat")
	check(not game.ui.relay_address.is_visible_in_tree() and not game.ui.address.is_visible_in_tree(), "connection URLs and LAN addresses are absent from the start screen")
	check(not InputMap.has_action("recover"), "keyboard and gamepad recovery action is removed")
	game.car.remote = true
	game.car.freeze = true
	game.car.signed_speed = 25.0
	game.car.distance_driven = 1234.56
	await process_frame
	await process_frame
	check(is_equal_approx(game.ui.dashboard.speed_kmh, 90.0) and is_equal_approx(game.ui.dashboard.distance_km, 1.23456), "gauge and trip odometer use shared car speed and distance")
	game.ui.set_online_busy(true)
	game._leave_online()
	check(game.ui.lobby_name.text == "forest-friends" and game.ui.lobby_name.editable, "leaving or cancelling keeps the name for the next visit")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
