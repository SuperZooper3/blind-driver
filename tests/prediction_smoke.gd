extends SceneTree
## Run: Godot --headless --path . --script tests/prediction_smoke.gd
## Unit checks for the navigator's optimistic continuation (scripts/pose_predictor.gd).
const Predictor = preload("res://scripts/pose_predictor.gd")
const Wire = preload("res://scripts/wire_protocol.gd")
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
	failed = failed or not condition

func _run() -> void:
	var p := Predictor.new()
	var start := Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	# Driving forward (-Z) at 20 m/s while turning left at 0.5 rad/s.
	p.accept(10.0, start, Vector3(0, 0, -20), Vector3(0, 0.5, 0), true)
	var first := p.step(10.0, 1.0 / 60.0)
	check(first.origin.is_equal_approx(start.origin), "the first pose is shown exactly")
	var ahead := p.predict_at(10.3)
	var heading := -ahead.basis.z
	check(absf(ahead.origin.z - -6.0) < 0.2 and ahead.origin.x < -0.2, "the car keeps moving and curving through a gap (%.2f, %.2f)" % [ahead.origin.x, ahead.origin.z])
	check(heading.x < -0.1, "the predicted heading turns with the car's spin")
	var held := p.predict_at(13.0)
	check(held.origin.is_equal_approx(p.predict_at(10.0 + Predictor.MAX_AHEAD).origin), "prediction stops after %.1f s without news instead of running away" % Predictor.MAX_AHEAD)
	# A late correction: the real car was 1.5 m to the right of our guess.
	var shown := p.step(10.2, 1.0 / 60.0)
	var corrected := Transform3D(p.predict_at(10.2).basis, p.predict_at(10.2).origin + Vector3(1.5, 0, 0))
	p.accept(10.2, corrected, Vector3(0, 0, -20), Vector3(0, 0.5, 0))
	var next := p.step(10.2 + 1.0 / 60.0, 1.0 / 60.0)
	var expected := p.predict_at(10.2 + 1.0 / 60.0)
	check(next.origin.distance_to(shown.origin) < 0.6, "a correction does not jump the car on screen (moved %.2f m in one frame)" % next.origin.distance_to(shown.origin))
	for _i in 30:
		next = p.step(10.2 + 1.0 / 60.0, 1.0 / 60.0)
	check(next.origin.distance_to(expected.origin) < 0.05, "the correction has faded within half a second")
	# Teleports (restarts, recoveries) snap instead of sliding across the map.
	p.accept(11.0, Transform3D(Basis.IDENTITY, Vector3(500, 1, 0)), Vector3.ZERO, Vector3.ZERO, true)
	check(p.step(11.0, 1.0 / 60.0).origin.is_equal_approx(Vector3(500, 1, 0)), "a reset snaps straight to the new place")
	check(not p.accept(10.5, start, Vector3.ZERO, Vector3.ZERO), "older poses arriving late are ignored")
	# The compact wire format survives a JSON round trip.
	var pose := {"seq": 4, "time": 12.5, "reset": 2, "transform": Transform3D(Basis(Vector3.UP, 0.7), Vector3(3.14159, -1.5, 120.25)), "velocity": Vector3(1, 0, -18), "angular_velocity": Vector3(0, 0.3, 0), "speed": 18.2, "steering": -0.4, "throttle": 1.0, "grounded": 4, "wheels": [-0.41, -0.4, -0.39, -0.4]}
	var text := JSON.stringify({"type": "pose", "state": Wire.pose_to_json(pose)})
	var back := Wire.pose_from_json(JSON.parse_string(text).state)
	check(not back.is_empty() and back.transform.origin.distance_to(pose.transform.origin) < 0.002 and back.transform.basis.is_equal_approx(pose.transform.basis) and is_equal_approx(back.steering, -0.4), "a pose survives the JSON round trip")
	check(text.length() < 400, "a pose message is small (%d bytes, a full snapshot is ~1000)" % text.length())
	quit(1 if failed else 0)
