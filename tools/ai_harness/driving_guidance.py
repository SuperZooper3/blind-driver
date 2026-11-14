"""Driving mechanics shared by the raw-key and semantic-control prompts."""

DRIVING_MECHANICS = (
    "This is a car with rolling wheels, not tank steering: A/D changes wheel angle, not heading while stationary. "
    "To turn LEFT from rest, release the handbrake and combine forward throttle + left steering (W+A); "
    "to turn RIGHT from rest use W+D. Use gentle throttle until moving, then reassess. "
    "A moving/coasting car can steer without more gas; do not accelerate unnecessarily at speed. "
    "When stopped or barely rolling, steering alone will not turn the car: first establish slow motion if the path is clear. "
    "Release steering when aligned; holding a turn keeps changing heading while moving. "
    "Reversing changes the yaw response: S+A backs the rear left while the nose swings right; S+D backs the rear right while the nose swings left. "
    "Check rear clearance and use short reverse maneuvers; stop and reassess between recovery steps. "
    "B HELD looks behind; release B to face forward. C ONLY toggles seat/chase camera; it does not look behind. "
    "A visible WRONG WAY warning means travel or stopped heading opposes the road's forward route. "
    "Slow down, let the navigator find clear turning space using road/map/rear views, then coordinate a slow moving turn. "
    "Do not try to spin in place or blindly reverse because of the warning. Verify that the warning clears. "
)
