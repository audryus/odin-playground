import datetime as dt
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import model as M  # noqa: E402


class FormatTest(unittest.TestCase):
    when = dt.datetime(2026, 10, 24, 17, 5, 9)  # Saturday, ISO week 43

    def test_default_formats(self):
        self.assertEqual(M.format_qt(self.when, "dddd HH:mm"), "Saturday 17:05")
        self.assertEqual(M.format_qt(self.when, "dddd h:mm AP"), "Saturday 5:05 PM")
        self.assertEqual(M.format_qt(self.when, "ddd d MMM HH:mm"), "Sat 24 Oct 17:05")
        self.assertEqual(M.format_qt(self.when, "d MMMM 'W'ww yyyy"), "24 October W43 2026")
        self.assertEqual(M.format_qt(self.when, "yyyy-MM-dd HH:mm"), "2026-10-24 17:05")

    def test_vertical_formats(self):
        self.assertEqual(M.format_qt(self.when, "HH\n—\nmm"), "17\n—\n05")
        self.assertEqual(M.format_qt(self.when, "h\n—\nmm\nAP"), "5\n—\n05\nPM")
        self.assertEqual(M.format_qt(self.when, "dd\nMMM\n'W'ww\n''yy"), "24\nOct\nW43\n'26")

    def test_h_is_24h_without_ampm(self):
        self.assertEqual(M.format_qt(self.when, "h:mm"), "17:05")
        midnight = dt.datetime(2026, 1, 1, 0, 7)
        self.assertEqual(M.format_qt(midnight, "h:mm AP"), "12:07 AM")

    def test_ring_cycles_in_fixed_order(self):
        ring = M.clock_format_ring("HH:mm", M.DEFAULT_FORMAT_ALT, M.clock_formats(False))
        self.assertEqual(ring, M.CLOCK_FORMATS)
        self.assertEqual(M.next_clock_format(ring, "HH:mm"), "h:mm AP")
        self.assertEqual(M.next_clock_format(ring, "yyyy-MM-dd HH:mm"), "dddd HH:mm")
        self.assertEqual(M.next_clock_format(ring, "nope"), "dddd HH:mm")

    def test_ring_keeps_custom_format(self):
        ring = M.clock_format_ring("HH:mm:ss", "", M.clock_formats(False))
        self.assertEqual(ring[-1], "HH:mm:ss")
        self.assertEqual(M.next_clock_format(ring, "HH:mm:ss"), "dddd HH:mm")


class CalendarTest(unittest.TestCase):
    def test_week_start(self):
        self.assertEqual(M.normalized_week_start("monday", 0), 1)
        self.assertEqual(M.normalized_week_start("sun", 1), 0)
        self.assertEqual(M.normalized_week_start(None, 0), 0)
        self.assertEqual(M.normalized_week_start("garbage", None), 1)
        self.assertEqual(M.toggled_week_start(1), 0)
        self.assertEqual(M.toggled_week_start(0), 1)
        self.assertEqual(M.toggled_week_start(6), 1)
        self.assertEqual(M.weekday_order(1), [1, 2, 3, 4, 5, 6, 0])

    def test_iso_week(self):
        self.assertEqual(M.iso_week(2026, 0, 1), 1)    # qui 1 jan 2026
        self.assertEqual(M.iso_week(2027, 0, 1), 53)   # sex 1 jan 2027 -> W53 de 2026
        self.assertEqual(M.iso_week(2026, 9, 24), 43)

    def test_grid_is_always_six_weeks(self):
        for month in range(12):
            weeks = M.month_grid(2026, month, 1, "")
            self.assertEqual(len(weeks), 6)
            self.assertTrue(all(len(w["days"]) == 7 for w in weeks))

    def test_grid_october_2026_monday_start(self):
        weeks = M.month_grid(2026, 9, 1, "2026-10-24")
        first = weeks[0]["days"][0]
        self.assertEqual((first["month"], first["day"]), (8, 28))  # seg 28 set
        self.assertFalse(first["inMonth"])
        self.assertEqual(weeks[0]["week"], 40)
        today = [d for w in weeks for d in w["days"] if d["today"]]
        self.assertEqual(len(today), 1)
        self.assertEqual(today[0]["day"], 24)
        self.assertTrue(today[0]["weekend"])

    def test_grid_sunday_start(self):
        weeks = M.month_grid(2026, 9, 0, "")
        self.assertEqual(weeks[0]["days"][0]["weekday"], 0)
        self.assertEqual(weeks[0]["days"][0]["day"], 27)  # dom 27 set

    def test_step_month(self):
        self.assertEqual(M.step_month(2026, 11, 1), {"year": 2027, "month": 0})
        self.assertEqual(M.step_month(2026, 0, -1), {"year": 2025, "month": 11})
        self.assertEqual(M.step_month(2026, 5, -24), {"year": 2024, "month": 5})


class ProgressTest(unittest.TestCase):
    def test_year_progress(self):
        self.assertEqual(M.year_progress_percent(2026, 0, 1), 0)
        self.assertEqual(M.year_progress_percent(2026, 11, 31), 100)
        self.assertEqual(M.days_in_year(2028), 366)

    def test_birth_year(self):
        self.assertEqual(M.parse_birth_year("1979", 2026), 1979)
        self.assertEqual(M.parse_birth_year("2030", 2026), 0)
        self.assertEqual(M.parse_birth_year("1800", 2026), 0)
        self.assertEqual(M.parse_birth_year("79", 2026), 0)
        self.assertEqual(M.age_from_birth_year(1979, 2026), 47)

    def test_life(self):
        self.assertEqual(M.parse_life_expectancy(""), 90)
        self.assertEqual(M.parse_life_expectancy("200"), 90)
        self.assertEqual(M.life_progress_percent(45, 90), 50)
        self.assertEqual(M.life_progress_percent(0, 90), 0)


if __name__ == "__main__":
    unittest.main()
