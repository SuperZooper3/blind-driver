extends RefCounted
## The release players see in the header and start screen.
## PROTOTYPE remains the increasing internal build ID for existing relay clients
## and browser diagnostics. Bump both values on merge (see AGENTS.md).
const PROTOTYPE := 33
const RELEASE := "1.0.1"

static func label() -> String:
	return "RELEASE " + RELEASE
