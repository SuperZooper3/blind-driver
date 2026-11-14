extends SceneTree
const Warning = preload("res://scripts/direction_warning.gd")
var failures := 0

class RoadFixture extends Node:
	var roads := [{"id": 1, "profile": "scenic"}]
	var direction := Vector3.FORWARD
	var distance := 0.0
	func nearest_road(_point: Vector3) -> Dictionary:
		return {"road_id": 1, "direction": direction, "distance": distance}

class CarFixture extends Node3D:
	var run_state := "driving"
	var grounded_wheels := 4
	var linear_velocity := Vector3.ZERO

func check(value: bool, description: String) -> void:
	print(("PASS: " if value else "FAIL: ") + description)
	if not value: failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var road := RoadFixture.new()
	var car := CarFixture.new()
	root.add_child(road)
	root.add_child(car)
	check(not Warning.points_wrong_way(road, car), "forward heading at rest is correct")
	car.rotation.y = PI
	check(Warning.points_wrong_way(road, car), "backward heading at rest warns before acceleration")
	car.rotation.y = 0
	car.linear_velocity = Vector3.BACK * 5
	check(Warning.points_wrong_way(road, car), "reverse travel down the road warns despite forward nose")
	car.rotation.y = PI
	car.linear_velocity = Vector3.FORWARD * 5
	check(not Warning.points_wrong_way(road, car), "actual travel takes precedence over nose when reversing")
	road.direction = Vector3.LEFT
	car.linear_velocity = Vector3.LEFT * 12
	check(not Warning.points_wrong_way(road, car), "correct travel around a bend uses local road tangent")
	car.linear_velocity = Vector3.RIGHT * 12
	check(Warning.points_wrong_way(road, car), "opposite travel around a bend warns")
	for profile in ["culdesac", "cliff"]:
		road.roads[0].profile = profile
		check(not Warning.points_wrong_way(road, car), "return from " + profile + " is allowed")
	road.roads[0].profile = "scenic"
	road.distance = 30
	check(not Warning.points_wrong_way(road, car), "deep forest does not guess an unrelated route")
	road.distance = 0
	car.grounded_wheels = 0
	check(not Warning.points_wrong_way(road, car), "airborne motion does not create a warning")
	car.grounded_wheels = 4
	car.run_state = "game_over"
	check(not Warning.points_wrong_way(road, car), "game over clears warning")
	road.free()
	car.free()
	quit(1 if failures else 0)
