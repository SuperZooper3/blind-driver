"""Conservative measurements of the visible road ribbon in a chase screenshot.

No game state, map coordinates or steering decision is used. This small palette
tool is specific to this game's tan road/shoulder and green terrain; uncertain
or obstructed rows return no measurement. The original image is still supplied.
"""
import colorsys
import statistics

from PIL import Image


def road_edges(image_path, view):
    if view.get("camera") != "chase" or view.get("map") != "closed" or view.get("facing") != "forward":
        return None
    with Image.open(image_path) as source:
        image = source.convert("RGB")
        image.thumbnail((640, 400))
    width, height = image.size
    rows = []
    for row in (.56, .59, .62):
        y = int(height * row)
        segments = []
        for x in range(width):
            r, g, b = image.getpixel((x, y))
            hue, saturation, brightness = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not (32 <= hue * 360 <= 73 and .1 < saturation < .45 and .18 < brightness < .95):
                continue
            if not segments or x - segments[-1][1] > width * .025:
                segments.append([x, x])
            else:
                segments[-1][1] = x
        wide = [(a / width, b / width) for a, b in segments if b - a > width * .12]
        if len(wide) != 1:
            return None
        rows.append(wide[0])
    left, right = (statistics.median(pair[i] for pair in rows) for i in (0, 1))
    if max(a for a, _ in rows) - min(a for a, _ in rows) > .10 or max(b for _, b in rows) - min(b for _, b in rows) > .10:
        return None
    # Chase camera tracks the car. This is an explicitly approximate screen
    # reference, not an engine-provided position or lane-centering controller.
    return {"source": "current screenshot pixels only", "sample_y_fraction": .59,
            "road_left_x": round(left, 3), "road_right_x": round(right, 3),
            "car_x_approx": .5, "road_center_x": round((left + right) / 2, 3),
            "edge_clipped": left <= .01 or right >= .99,
            "caution": "Normalized screen coordinates; tan road plus shoulders. Approximate, verify against image. Not heading or world position."}
