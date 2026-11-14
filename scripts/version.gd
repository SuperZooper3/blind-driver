extends RefCounted
## The one version number players see ("PROTOTYPE 02" in the header and start screen).
## Bump PROTOTYPE by one in every change merged to main (see AGENTS.md), so both
## players can check at a glance that they are on the same build.
const PROTOTYPE := 3

static func label() -> String:
	return "PROTOTYPE %02d" % PROTOTYPE
