extends RefCounted
## Navigator-side optimistic continuation of the driver's car.
##
## Instead of drawing the car 100 ms in the past and freezing whenever the network
## hiccups, the navigator predicts where the driver's car is *now* from the latest
## pose (position, velocity, spin) and keeps it moving through gaps. When a newer
## pose arrives, the jump between the old guess and the new one is not shown
## directly: it becomes an offset that fades out over SMOOTHING seconds.

## Longest stretch to keep extrapolating without news before holding still.
const MAX_AHEAD := 0.6
## Seconds for a correction to fade (about two thirds gone after this long).
const SMOOTHING := 0.12
## Corrections larger than this (teleports, restarts) snap instead of sliding.
const SNAP_DISTANCE := 8.0

var has_pose := false
var pose_time := 0.0
var pose_transform := Transform3D.IDENTITY
var pose_velocity := Vector3.ZERO
var pose_spin := Vector3.ZERO
var rendered := Transform3D.IDENTITY
var offset := Vector3.ZERO
var rotation_offset := Quaternion.IDENTITY
var _fresh := false
var _snap := true

## Feed a pose stamped with the driver's clock. Older or duplicate poses are ignored.
## `snap` (a restart or recovery) jumps straight to it instead of easing.
func accept(time: float, transform: Transform3D, velocity: Vector3, spin: Vector3, snap: bool = false) -> bool:
	if has_pose and time <= pose_time and not snap:
		return false
	pose_time = time
	pose_transform = transform
	pose_velocity = velocity
	pose_spin = spin
	has_pose = true
	_fresh = true
	_snap = _snap or snap
	return true

func reset() -> void:
	has_pose = false
	_snap = true
	offset = Vector3.ZERO
	rotation_offset = Quaternion.IDENTITY

## Where the latest pose says the car is at driver time `time`: constant speed and
## turn rate, so a car mid-corner keeps turning instead of sliding off on a tangent.
func predict_at(time: float) -> Transform3D:
	var ahead := clampf(time - pose_time, 0.0, MAX_AHEAD)
	var basis := pose_transform.basis
	var velocity := pose_velocity
	var turn := pose_spin.length() * ahead
	if turn > 0.0001:
		var axis := pose_spin.normalized()
		basis = Basis(axis, turn) * basis
		# Average heading over the interval approximates the arc.
		velocity = velocity.rotated(axis, turn * 0.5)
	return Transform3D(basis.orthonormalized(), pose_transform.origin + velocity * ahead)

## Advance one rendered frame and return the transform to show.
func step(time: float, frame_delta: float) -> Transform3D:
	var target := predict_at(time)
	if _fresh:
		_fresh = false
		if _snap:
			offset = Vector3.ZERO
			rotation_offset = Quaternion.IDENTITY
		else:
			# Keep the car where it was on screen; let the difference fade instead.
			offset = rendered.origin - target.origin
			rotation_offset = rendered.basis.get_rotation_quaternion() * target.basis.get_rotation_quaternion().inverse()
			if offset.length() > SNAP_DISTANCE:
				offset = Vector3.ZERO
				rotation_offset = Quaternion.IDENTITY
		_snap = false
	var keep := exp(-maxf(frame_delta, 0.0) / SMOOTHING)
	offset *= keep
	rotation_offset = Quaternion.IDENTITY.slerp(rotation_offset.normalized(), keep)
	rendered = Transform3D(Basis(rotation_offset) * target.basis, target.origin + offset)
	return rendered
