import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class PowerModelTest(unittest.TestCase):
    def dev(self, pct, state, rate=10, ttf=3600):
        return {"present": True, "percentage": pct, "state": state, "rate": rate, "time_to_full": ttf}

    def test_icons(self):
        self.assertEqual(M.battery_icon(self.dev(0.55, M.DISCHARGING), True), "󰁿")
        self.assertEqual(M.battery_icon(self.dev(0.55, M.CHARGING), False), M.CHARGING_ICONS[5])
        self.assertEqual(M.battery_icon(self.dev(1.0, M.FULLY_CHARGED), False), "󰂅")
        self.assertEqual(M.battery_icon({"present": False}, False), "")

    def test_threshold(self):
        self.assertTrue(M.charge_threshold_active(self.dev(0.8, M.PENDING_CHARGE), False))
        self.assertTrue(M.charge_threshold_active(self.dev(0.8, M.CHARGING, rate=0.1), False))
        self.assertFalse(M.charge_threshold_active(self.dev(0.8, M.CHARGING), False))
        self.assertFalse(M.charge_threshold_active(self.dev(0.8, M.CHARGING), True))
        self.assertEqual(M.mode_label(self.dev(0.8, M.PENDING_CHARGE), False), "Threshold")

    def test_profiles(self):
        p = M.parse_profiles("power-saver\t0\nbalanced\t0\nperformance\t1\n")
        self.assertEqual(p["profiles"], ["power-saver", "balanced", "performance"])
        self.assertEqual(p["activeProfile"], "performance")
        self.assertEqual(M.select_profile_index(2, 1, p["profiles"]), 2)
        self.assertEqual(M.parse_key_value("cpu\t3%\nmemory\t12GB / 46GB"), {"cpu": "3%", "memory": "12GB / 46GB"})


if __name__ == "__main__":
    unittest.main()
