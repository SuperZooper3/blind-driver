extends RefCounted
## One bounded JSONL log per process; credentials and payloads are never recorded.
const DIRECTORY := "user://network_logs"
const MAX_BYTES := 2097152
static var file: FileAccess
static var path := ""
static var part := 0

static func event(name: String, details: Dictionary = {}) -> void:
	if file == null or file.get_position() > MAX_BYTES:
		_open()
	var entry := {"time": Time.get_datetime_string_from_system(true), "monotonic_ms": Time.get_ticks_msec(), "pid": OS.get_process_id(), "event": name}
	entry.merge(details, false)
	var line := JSON.stringify(entry)
	if file != null:
		file.store_line(line)
		file.flush()
	print("[network] ", line)

static func _open() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIRECTORY))
	var files := DirAccess.get_files_at(DIRECTORY)
	files.sort()
	# Keep recent files from other processes; prune older sessions and our rotations.
	var owned: Array[String] = []
	for name in files:
		if name.begins_with("network-") and name.ends_with(".jsonl"):
			var parts := name.split("-")
			if parts.size() == 4:
				var pid := int(parts[2])
				if (pid == OS.get_process_id() or Time.get_unix_time_from_system() - FileAccess.get_modified_time(DIRECTORY.path_join(name)) > 86400.0) and DIRECTORY.path_join(name) != path:
					owned.append(name)
	while owned.size() >= 12:
		var oldest: String = owned.pop_front()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIRECTORY.path_join(oldest)))
	part += 1
	path = DIRECTORY.path_join("network-%d-%d-%d.jsonl" % [int(Time.get_unix_time_from_system()), OS.get_process_id(), part])
	file = FileAccess.open(path, FileAccess.WRITE)

static func folder() -> String:
	return ProjectSettings.globalize_path(DIRECTORY)

static func close() -> void:
	if file != null:
		file.close()
	file = null
