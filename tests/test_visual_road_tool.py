from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw
from tools.ai_harness.vision import road_edges


class VisibleRoadTests(unittest.TestCase):
    def measure(self, left, right, view=None, color="#8f8c6e", extra=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "seat.png"
            image = Image.new("RGB", (640, 400), "#95b080")
            draw = ImageDraw.Draw(image)
            draw.rectangle((left, 72, right, 300), fill=color)
            if extra:
                draw.rectangle(extra, fill=color)
            image.save(path)
            return road_edges(path, view or {"camera": "chase", "map": "closed", "facing": "forward"})

    def test_centered_and_both_shoulder_positions_are_distinct_visible_measurements(self):
        centered = self.measure(170, 470)
        self.assertAlmostEqual(centered["road_center_x"], .5, places=2)
        left_of_road = self.measure(360, 639)
        self.assertLess(left_of_road["car_x_approx"], left_of_road["road_left_x"])
        self.assertTrue(left_of_road["edge_clipped"])
        right_of_road = self.measure(0, 280)
        self.assertGreater(right_of_road["car_x_approx"], right_of_road["road_right_x"])

    def test_ambiguous_colors_occlusion_and_nonforward_views_abstain(self):
        self.assertIsNone(self.measure(170, 470, color="#ff6a00"))
        self.assertIsNone(self.measure(170, 470, color="#8aac73"))
        self.assertIsNone(self.measure(30, 200, extra=(400, 72, 630, 300)))
        for changed in ({"map": "open"}, {"map": "opening"}, {"map": "closing"}, {"facing": "rear"}, {"camera": "seat"}):
            view = {"camera": "chase", "map": "closed", "facing": "forward", **changed}
            self.assertIsNone(self.measure(170, 470, view))
