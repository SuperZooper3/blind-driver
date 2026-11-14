"""Compare where the navigator shows the car with where the driver's car really was.

Usage: python3 tests/lag_report.py driver.txt navigator.txt
Prints error statistics in metres and how often the navigator's car froze while the
real car was moving. Imported by run_checks.py, which applies thresholds.
"""
import bisect
import statistics
import sys


def load(path, tag):
    rows = []
    for line in open(path):
        parts = line.split()
        if len(parts) == 5 and parts[0] == tag:
            rows.append(tuple(float(value) for value in parts[1:]))
    return rows


def at(track, times, t):
    """Driver position at wall time t, linearly interpolated."""
    i = bisect.bisect_left(times, t)
    if i <= 0 or i >= len(track):
        return None
    (t0, *a), (t1, *b) = track[i - 1], track[i]
    w = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
    return [a[k] + (b[k] - a[k]) * w for k in range(3)]


def report(driver_path, navigator_path, settle=3.0):
    driver = load(driver_path, "H")
    navigator = load(navigator_path, "N")
    times = [row[0] for row in driver]
    start = max(driver[0][0], navigator[0][0]) + settle
    errors, frozen, moving = [], 0, 0
    previous = None
    for t, *shown in navigator:
        if t < start:
            previous = shown
            continue
        real = at(driver, times, t)
        real_before = at(driver, times, t - 1 / 60)
        if real is None:
            continue
        errors.append(sum((shown[k] - real[k]) ** 2 for k in range(3)) ** 0.5)
        if previous is not None and real_before is not None:
            real_step = sum((real[k] - real_before[k]) ** 2 for k in range(3)) ** 0.5
            shown_step = sum((shown[k] - previous[k]) ** 2 for k in range(3)) ** 0.5
            if real_step > 0.05:
                moving += 1
                frozen += shown_step < 0.005
        previous = shown
    errors.sort()
    pick = lambda q: errors[min(len(errors) - 1, int(q * len(errors)))]
    return {
        "samples": len(errors),
        "median_m": statistics.median(errors),
        "p90_m": pick(0.9),
        "p99_m": pick(0.99),
        "max_m": errors[-1],
        "frozen_pct": 100.0 * frozen / max(1, moving),
    }


if __name__ == "__main__":
    result = report(sys.argv[1], sys.argv[2])
    print("navigator vs real car: median {median_m:.2f} m, p90 {p90_m:.2f} m, p99 {p99_m:.2f} m, max {max_m:.2f} m; "
          "frozen while moving {frozen_pct:.1f}% of frames ({samples} samples)".format(**result))
