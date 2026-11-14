extends RefCounted
## Each computer keeps its own best survival distance, including a shared online ride.
const DEFAULT_PATH := "user://records.cfg"
var path := DEFAULT_PATH
var best_distance := 0.0
var saved_distance := 0.0
var previous_best := 0.0
var new_best := false

func _init() -> void:
	var override_path := OS.get_environment("BLIND_DRIVER_RECORDS_PATH")
	if not override_path.is_empty():
		path = override_path

func load_record() -> void:
	best_distance = _read_best()
	saved_distance = best_distance
	begin_run()

func _read_best() -> float:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return 0.0
	var value: Variant = config.get_value("records", "distance_m", 0.0)
	if not (value is float or value is int) or not is_finite(float(value)):
		return 0.0
	return clampf(float(value), 0.0, 1.0e10)

func begin_run() -> void:
	previous_best = best_distance
	new_best = false

func observe(distance: float) -> void:
	if is_finite(distance) and distance > best_distance:
		best_distance = distance
	new_best = distance > previous_best and distance >= 1.0

func save_record() -> Error:
	if best_distance <= saved_distance:
		return OK
	# A local co-op second window may have written a larger record since we loaded.
	best_distance = maxf(best_distance, _read_best())
	var config := ConfigFile.new()
	config.set_value("records", "distance_m", best_distance)
	var temporary := path + ".%d.tmp" % OS.get_process_id()
	var error := config.save(temporary)
	if error == OK:
		error = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))
	if error == OK:
		saved_distance = best_distance
	return error
