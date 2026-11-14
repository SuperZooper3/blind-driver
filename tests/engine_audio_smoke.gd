extends SceneTree
var failed := false

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	failed = failed or not ok

func _initialize() -> void:
	var motor = preload("res://scripts/engine_audio.gd").new()
	var idle_peak := 0.0
	for i in 2205:
		idle_peak = maxf(idle_peak, absf(motor._rev_sample(0.0)))
	check(idle_peak == 0.0, "no engine idle or tire hiss without throttle")
	var energy := 0.0
	for i in 2205:
		energy += pow(motor._rev_sample(1.0), 2.0)
	check(energy / 2205.0 > 0.01, "active throttle produces audible tonal revs")
	# The short release envelope must reach exact silence even with a broken engine.
	motor.roughness = 1.0
	for i in 500:
		motor._rev_sample(0.0)
	var coast_peak := 0.0
	for i in 2205:
		coast_peak = maxf(coast_peak, absf(motor._rev_sample(0.0)))
	check(coast_peak == 0.0, "releasing throttle removes engine and damage noise while coasting")
	motor.free()
	quit(1 if failed else 0)
