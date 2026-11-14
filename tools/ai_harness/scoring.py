"""Versioned evaluation score; raw measurements always remain available."""
DEFAULT_SCORING = {"version": "progress_safety_v1", "hit": 25.0,
                   "offroad_second": 2.0, "damage_fraction": 100.0, "failure": 100.0}


def score_frame(frame, scoring=None):
    weights = scoring or DEFAULT_SCORING
    health = frame.get("part_health") or []
    damage = sum(1 - max(0, min(1, float(v))) for v in health) / len(health) if health else 0
    progress = max(0, float(frame.get("forward_progress_m") or 0))
    terms = {
        "penalty_hits": max(0, int(frame.get("impact_events") or 0)) * weights["hit"],
        "penalty_offroad": max(0, float(frame.get("offroad_sim_seconds") or 0)) * weights["offroad_second"],
        "penalty_damage": damage * weights["damage_fraction"],
        "penalty_failure": weights["failure"] if frame.get("run_state") == "game_over" else 0.0,
    }
    return {"score": progress-sum(terms.values()), "score_progress": progress,
            "damage_fraction": damage, "penalty_total": sum(terms.values()), **terms}
