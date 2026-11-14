"""Short tasks with semantic controls and current visible evidence."""


def prompt(role: str, speed: float, course: str, readable: bool = True) -> str:
    common = (
        f"You are {role.upper()} in Blind Driver, cooperating with the other seat to drive at least 500m safely. "
        f"Game speed {speed:g}%; it keeps moving while you think. Inspect this NEW image. "
        "hud is an exact transcript of the visible instruments. Previous notes may be wrong/stale. "
        "message is spoken to your partner; notes are private, brief visible facts plus what to check next. "
        "Answer the newest partner request. Send a changed instruction, warning, question, answer or useful acknowledgment; otherwise message=\"\". "
        "Do not repeat routine clear/straight broadcasts. Notes max 600 characters; message max 240. Return ONLY JSON. "
    )
    if course == "basic":
        common += "Basic road has bends, rocks, trees and roadside thorns, no police/jumps. Cruise 50–55 km/h when clear; 25–35 on bends. "
    else:
        common += "Standard road has forks, cliffs, police, jumps and bridges: heed visible signs and map. "
    if role == "driver":
        return common + (
            'Return {"pedal":"accelerate|coast|brake|reverse|park","steering":"left|straight|right","message":"","notes":""}. '
            "Your view is BLURRED; navigator supplies road direction. Use HUD speed to choose pedal. "
            "accelerate presses W for 1 game second; coast releases W/S; brake presses S for 0.2 game seconds; "
            "reverse presses S for 0.3 game seconds (only when stopped and rear confirmed clear); park holds SPACE at rest. "
            "left/right steers for 0.15 game seconds then straightens; straight releases steering immediately. "
            "Optional pedal_seconds or steering_seconds (0.05–1) changes that pulse's duration. "
            "If current speed exceeds the navigator's target, COAST or BRAKE, never accelerate. "
            "At target coast; below target accelerate unless asked to wait. If braking near zero, coast/park so we don't reverse. "
            "Do not invent a clear road from the blurred image. Follow fresh turn advice; ask for direction when uncertain. "
            "After crash/off-road release throttle and follow one recovery step. A requested maneuver is not proof it worked. "
            "Notes: current speed, target speed, newest instruction; no lengthy narrative."
        )
    return common + (
        'Return {"view":"map|chase|rear|seat","message":"","notes":""}. '
        "You cannot drive. Driver cannot operate your views. Put ONLY driving instructions/questions in message, never view-control instructions or narration. "
        "view selects what YOU look at NEXT: map opens M; chase closes map and selects C chase camera; rear holds B; seat returns forward inside cabin. "
        "Repeated view choices are idempotent. This image is the CURRENT view, not the one you are selecting. "
        "At departure read map, then select chase to watch the car against both road edges. "
        "Map opening needs 0.38 game seconds; wait for a later readable image. "
        + ("Map is north-up; orange arrow is car heading. Clockwise heading change is right, counterclockwise left. " if readable else "Map rotates with the car, forward is up. ") +
        "Scale bar is a ruler, not the visible route length. Keep the next bend in notes and recheck map when due. "
        "In chase view compare the CAR to the nearby road edges AND look farther ahead for bends/rocks. "
        "Road to car's left means steer LEFT, road to right means RIGHT. Call a short correction before the car leaves the road. "
        "Give a concrete target speed and direction. Say straighten once aligned. Recommend 50–55 on clear straight road; slow before hazards. "
        "OFF ROAD/crash: slow, locate road and obstruction in chase view, give one recovery maneuver and verify the next image. "
        "If blocked, check rear before advising reverse. Do not loop 'stop and assess': YOU must locate a clear direction or change view. "
        "Notes: car left/right/center of road; upcoming bend; hazard; map plan. Mark unknowns, do not invent clearance."
    )


def current_task(role: str, observation: dict) -> str:
    if role == "driver":
        return "Choose pedal from CURRENT speed versus target; choose steering from latest navigator instruction. A coast decision must use pedal=coast."
    view, hud = observation.get("view", {}), observation.get("hud", {})
    if view.get("map") == "opening":
        return "Map still opening: keep view=map and wait."
    if view.get("map") == "open":
        return "Read road ahead relative to orange arrow. Record next bend in notes; select view=chase now to watch the road. Tell driver the driving plan, not how to use map."
    if view.get("facing") == "rear":
        return "Check rear clearance. Tell driver whether reverse is safe, then select chase to face forward."
    if hud.get("surface") == "OFF ROAD" or observation.get("sound_captions"):
        return "Recovery priority: select chase; identify road LEFT/RIGHT of CAR and give a specific low-speed recovery step. No routine map check while moving off-road."
    if observation.get("map_check", {}).get("last_open_view") is None:
        return "Select map now and tell driver to wait for the initial route check."
    if observation.get("map_check", {}).get("due"):
        return "If current alignment is safe, select map to plan the approaching bend. Otherwise correct alignment first in chase."
    return "Keep chase view. Watch alignment and upcoming bend/obstacle. Cruise target 50–55 if clear. Speak only a necessary correction or answer."
