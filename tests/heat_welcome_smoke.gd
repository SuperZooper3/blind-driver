extends SceneTree
var failed := false
func _initialize() -> void:
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok
func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game._start("split")
	game.set_process(false)
	game.set_physics_process(false)
	game.car.freeze = true
	var ui = game.ui
	ui.update_heat(0, 0, 0, false, false, 0.0)
	check(not ui.welcome_active and ui.welcomed_regions.is_empty(), "menus and the intro defer the welcome")
	ui.update_heat(0, 0, 0, true, false, 0.35)
	ui.update_heat(0, 0, 0, true, false, 0.0)
	check(ui.heat_label.text == "HEAT 1 / 5  ·  SPRING", "bottom-left heat display names spring")
	var both := true
	for welcome: Control in ui.heat_welcomes:
		both = both and welcome.visible and welcome.heading.text == "Welcome to Spring" and welcome.reveal > 0.1 and welcome.reveal < 0.9
	check(both, "both seat titles wipe in together, separately from the blurred road")
	var elapsed: float = ui.welcome_elapsed
	ui.update_heat(0, 0, 0, false, false, 2.0)
	check(not ui.welcome_active and ui.welcome_elapsed == elapsed, "pausing hides and pauses the welcome instead of replaying it")
	ui.update_heat(4, 0, 0, true, false, 5.0)
	ui.update_heat(4, 0, 0, true, false, 0.0)
	check(ui.heat_label.text == "HEAT 5 / 5  ·  HELL" and not ui.welcome_active, "heat can rise without welcoming the player to scenery they have not reached")
	ui.update_heat(4, 4, 0, true, false, 0.65)
	ui.update_heat(4, 4, 0, true, false, 0.0)
	check(ui.heat_welcomes[0].heading.text == "Welcome to Hell" and ui.heat_welcomes[1].heading.text == "Welcome to Hell" and ui.heat_welcomes[0].reveal == 1.0, "entering hell welcomes both players by name")
	check(ui.map_clip.z_index > ui.heat_welcomes[1].z_index and ui.repair_overlays[1].z_index > ui.heat_welcomes[1].z_index, "the map and repairs remain above the welcome")
	ui.update_heat(4, 4, 0, true, false, 5.0)
	ui.update_heat(4, 0, 0, true, false, 0.0)
	check(not ui.welcome_active, "backtracking to a visited region does not repeat the title")
	ui.update_heat(0, 0, 1, true, false, 0.0)
	check(ui.welcome_active and ui.heat_welcomes[0].heading.text == "Welcome to Spring" and ui.welcomed_regions.size() == 1, "a new ride welcomes players to spring again")
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
