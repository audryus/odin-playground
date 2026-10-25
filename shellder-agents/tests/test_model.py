import datetime as dt
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class AgentsModelTest(unittest.TestCase):
    now = dt.datetime(2026, 10, 25, 0, 0, tzinfo=dt.timezone.utc)

    def test_windows(self):
        p = {"limits": [{"label": "Session (5-hour)", "percent": 0.35, "resetsAt": "2026-10-25T04:50:00+00:00"},
                        {"label": "Weekly (7-day)", "percent": 0.95, "resetsAt": "2026-10-30T19:00:00+00:00"},
                        {"label": "Old", "percent": 0.5, "resetsAt": "2026-10-24T00:00:00+00:00"}]}
        w = M.limit_windows(p, self.now)
        self.assertEqual([x["title"] for x in w], ["Session", "Weekly", "Old"])
        self.assertEqual(w[2]["percent"], 0)
        self.assertTrue(M.alarming(p, self.now))
        self.assertEqual(M.format_duration((w[0]["reset"] - self.now).total_seconds()), "4h 50m")

    def test_formats(self):
        self.assertEqual(M.format_tokens(177941191), "177.9M")
        self.assertEqual(M.format_tokens(950), "950")
        self.assertEqual(M.friendly_model_name("claude-opus-5-5"), "Opus 5.5")
        self.assertEqual(M.friendly_model_name("claude-haiku-4-5-20251001"), "Haiku 4.5")
        self.assertEqual(M.friendly_model_name("gpt-5.6-sol"), "GPT 5.6 Sol")
        self.assertEqual(M.format_money(3.5, "EUR"), "€3.50")

    def test_has_data(self):
        self.assertFalse(M.has_data({"limits": [], "totalPrompts": 0}))
        self.assertTrue(M.has_data({"activeDays": 3}))
        self.assertTrue(M.has_data({"balance": {"remaining": 4, "funded": 20}}))


if __name__ == "__main__":
    unittest.main()
