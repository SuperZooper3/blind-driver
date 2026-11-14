extends RefCounted
## Shared by the opening and terrain generation, including remote clients.
const CENTER := Vector3(16.5, 0.0, 18.0)
## Includes the steps, roof overhang, and room for surrounding tree crowns.
const CLEARING := Rect2(4.0, 5.0, 24.0, 26.0)

static func contains(at: Vector3) -> bool:
	return CLEARING.has_point(Vector2(at.x, at.z))
