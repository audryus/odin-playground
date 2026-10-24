import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class MonitorModelTest(unittest.TestCase):
    def test_clean_scale(self):
        self.assertEqual(M.clean_scale(1, 1920, 1080), "1")
        self.assertEqual(M.clean_scale(1.25, 1920, 1080), "1.25")
        self.assertEqual(M.clean_scale(1.6, 3840, 2160), "1.6")
        self.assertEqual(M.clean_scale(0, 1920, 1080), "")

    def test_available_scales(self):
        self.assertEqual(M.available_scales(M.SCALE_PRESETS, 3840, 2160)[0], "1")
        self.assertIn("2", M.available_scales(M.SCALE_PRESETS, 3840, 2160))

    def test_matching(self):
        scales = M.available_scales(M.SCALE_PRESETS, 1920, 1080)
        self.assertEqual(scales[M.matching_scale_index(scales, "1", 1920, 1080)], "1")

    def test_names(self):
        self.assertEqual(M.brightness_name(100), "Sun blast")
        self.assertEqual(M.brightness_name(50), "Even day")
        self.assertEqual(M.brightness_name(3), "Night owl")

    def test_state(self):
        st = M.parse_state('100\n\nDP-1\n\n\nDP-1\n1\n[{"name":"DP-1","enabled":true,"focused":true,"width":1920,"height":1080}]')
        self.assertTrue(st["brightnessAvailable"])
        self.assertEqual(st["brightness"], 100)
        self.assertEqual(st["focused"], "DP-1")
        self.assertEqual(st["enabledCount"], 1)
        self.assertFalse(M.parse_state("unavailable\n")["brightnessAvailable"])


if __name__ == "__main__":
    unittest.main()
