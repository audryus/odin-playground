import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class WeatherModelTest(unittest.TestCase):
    def test_location(self):
        loc = M.parse_location_file('{"name": " Santos ", "latitude": -23.96, "longitude": -46.33}')
        self.assertEqual(loc, {"name": "Santos", "latitude": -23.96, "longitude": -46.33})
        self.assertEqual(M.parse_location_file("nope")["name"], "")
        self.assertEqual(M.wttr_location_query("", -23.96, -46.33), "-23.96,-46.33")
        self.assertEqual(M.wttr_location_query("São Paulo", None, None), "S%C3%A3o%20Paulo")

    def test_units(self):
        self.assertTrue(M.should_use_imperial("", "en_US.UTF-8", ""))
        self.assertFalse(M.should_use_imperial("", "en_US.UTF-8", "Brazil"))
        self.assertTrue(M.should_use_imperial("imperial", "pt_BR", "Brazil"))
        self.assertEqual(M.rounded(22.5), "23")
        self.assertEqual(M.format_temp("22", False), "22°C")

    def test_icons(self):
        self.assertEqual(M.icon_for_open_meteo(0), "")
        self.assertEqual(M.icon_for_open_meteo(0, night=True), "")
        self.assertEqual(M.icon_for_open_meteo(61), "")
        self.assertEqual(M.icon_for_code(999), "")
        self.assertEqual(M.current_icon({"code": 3, "isDay": 1}), "")

    def test_forecast(self):
        rep = {"daily": {"time": ["2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27"],
                         "temperature_2m_max": [25, 26.4, 27, 28], "temperature_2m_min": [15, 16, 17, 18],
                         "weather_code": [0, 1, 61, 95]}}
        days = M.open_meteo_days(rep, "2026-10-24")
        self.assertEqual([d["date"] for d in days], ["2026-10-25", "2026-10-26", "2026-10-27"])
        self.assertEqual(days[0]["maxC"], "26")
        self.assertEqual(M.day_name("2026-10-25"), "Sunday")


if __name__ == "__main__":
    unittest.main()
