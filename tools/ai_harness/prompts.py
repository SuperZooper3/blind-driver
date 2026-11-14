"""Short, image-grounded cooperative driving instructions."""


def prompt(role: str, speed: float, course: str, readable: bool = True) -> str:
    common = (
        f"Play Blind Driver as {role.upper()}. Reach 500m along the road without crashing. "
        f"Simulation runs continuously at {speed:g}% speed. Inspect the NEW image; earlier claims can be wrong. "
        "hud is an exact transcript of the visible instruments, not a route sensor. "
        "Speech reaches only your teammate; notes stay private. Answer their newest request. "
        "Send changed instructions, warnings, questions or answers; otherwise message=\"\". "
        "Never copy a previous 'clear/straight' claim without checking this frame. "
        "Return ONLY JSON: {\"notes\":\"brief fresh observations and next check\",\"hold\":[],\"tap\":[],\"message\":\"\"}. "
        "notes <=600 characters, message <=240. hold REPLACES all own held keys until your next action; [] releases. "
        "tap toggles once. No pause, restart, teleport or hidden state. "
    )
    if course == "basic":
        common += "Basic course: bends, rocks, roadside trees/thorns; no police or jumps. Aim 40–55 km/h on clear straight road, 25–35 for bends. "
    else:
        common += "Standard course includes police, forks, cliffs, jumps and bridges; use map and visible signs. "
    if role == "driver":
        return common + (
            "Your view is BLURRED. Trust fresh navigator directions for steering, not your own claims of clear road. "
            "Keys: W accelerate, S brake THEN reverse below zero, A left, D right, SPACE handbrake; tap H lights. "
            "Read HUD speed and newest instruction. W below target speed; coast [] at target; S to slow if too fast. "
            "Do not accelerate while awaiting the initial route check. Never hold W through uncertainty/off-road/crash. "
            "For a small steering correction add steering_pulse_sim:0.15 to your JSON with A or D in hold; "
            "this releases ONLY steering after 0.15 GAME seconds, retaining other keys. "
            "Use 0.1–0.3s pulses, then await fresh guidance; do not hold steering across multiple exchanges. "
            "A pulse ending is not proof of alignment. Briefly acknowledge a changed maneuver. "
            "If speed is near zero and stop requested, release S (it would reverse); SPACE holds stationary. "
            "After impact ask for a concrete escape direction; reverse only with rear clearance reported by navigator."
        )
    return common + (
        "You are the driver's eyes. Your hold keys: B look behind; taps M map, C chase/seat camera. "
        "At departure (trip near zero) open M to plan the next bend while asking driver to wait. Map takes 0.38 GAME seconds to open; "
        "read it on a later image, store the bend/direction in notes, close M, then authorize driving. "
        "Check map again before your route plan runs out (map_check tells its age); it does not show rocks. "
        + ("Map is NORTH UP: orange arrow is car heading; clockwise from car heading to road heading = right, counterclockwise = left. "
           if readable else "Map rotates with the car, forward is up. ") +
        "Use C for chase view if cabin/roof obscures road or alignment is uncertain; it shows the car and both road edges. "
        "On each road view, locate the CAR relative to road edges, then follow the road farther ahead for a bend/obstacle. "
        "Road left of car = guide LEFT; road right = RIGHT. A straight road does not mean we are on it. "
        "Keep notes short: alignment=left/right/center/unknown; bend=left/right/straight/unknown; hazard; map_plan. Preserve map plan until passed. "
        "Tell driver concrete speed + steering: e.g. 'Coast; pulse A 0.15 game seconds toward the road center, then release.' "
        "Use short corrections then inspect the next view; say straighten when aligned, not blindly 'go straight'. "
        "OFF ROAD or impact overrides the old plan: release W, slow, inspect chase view for road and obstruction. "
        "Give ONE feasible recovery maneuver, then verify its effect. If blocked inspect rear with B before reversing, "
        "release B to face forward afterwards. Do not loop 'stop and assess': YOU must assess and give the next step. "
        "Repeated speech feedback means gather new evidence/change view and resolve the driver's unanswered question. "
        "Never invent turns, clearance or damage; say what remains unknown."
    )


def current_task(role: str, observation: dict) -> str:
    """Ask for the missing evidence, using only this seat's visible UI/text."""
    if role != "navigator":
        return "Implement the navigator's latest maneuver. Check speed before adding throttle."
    view, hud = observation.get("view", {}), observation.get("hud", {})
    if view.get("map") == "opening":
        return "The map is still opening; don't tap M again. Wait for a readable map view."
    if view.get("map") == "open":
        return "Read the orange car arrow and road ahead on this map. Record the next bend and how it differs from car heading. Close M to watch the road."
    if view.get("facing") == "rear":
        return "Check rear clearance for recovery. Tell driver whether reversing is safe, then release B to return forward."
    if hud.get("surface") == "OFF ROAD" or observation.get("sound_captions"):
        return ("URGENT: current HUD/captions require reassessment. Which side is the ROAD relative to the CAR? "
                "Give a concrete slow recovery step with LEFT/RIGHT if visible. If obscured, tap C for chase and request braking. "
                "Do not open the map while moving off-road or repeat 'assess surroundings'.")
    if observation.get("map_check", {}).get("last_open_view") is None:
        return "No map view obtained yet. Open M now and ask driver to wait for your route instruction."
    if observation.get("map_check", {}).get("due"):
        return "Route plan needs updating. If current path is safe, open M for the upcoming bend; otherwise correct immediate alignment first."
    return "Inspect nearby road edges AND the bend farther ahead. Give the next speed/steering correction, or silence if existing guidance is still correct."
