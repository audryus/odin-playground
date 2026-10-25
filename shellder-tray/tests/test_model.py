import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class TrayModelTest(unittest.TestCase):
    def test_buckets(self):
        items = [{"id": "a"}, {"id": "b"}, {"id": "c", "status": "Passive"},
                 {"id": "d"}, {"id": "x", "title": "LocalSend"}]
        pinned, drawer, every = M.buckets(items, ["b"], ["d"])
        self.assertEqual([i["id"] for i in pinned], ["b"])
        self.assertEqual([i["id"] for i in drawer], ["a"])
        self.assertEqual([i["id"] for i in every], ["a", "b", "d"])

    def test_toggles(self):
        self.assertEqual(M.toggle_pin("a", [], ["a"]), (["a"], []))
        self.assertEqual(M.toggle_pin("a", ["a"], []), ([], []))
        self.assertEqual(M.toggle_hide("a", ["a"], []), ([], ["a"]))

    def test_drawer_layout(self):
        self.assertEqual(M.drawer_layout(3, 20, 0), (60, 0, 0))
        self.assertEqual(M.drawer_layout(3, 20, 1), (0, 3, 0))
        lead, vis, trail = M.drawer_layout(3, 20, 0.5)
        self.assertEqual((lead, vis), (30, 1))
        self.assertAlmostEqual(lead + vis * 20 + trail, 60)
        self.assertEqual(M.ease_out_cubic(1), 1)

    def test_service(self):
        self.assertEqual(M.parse_service(":1.110/StatusNotifierItem"), (":1.110", "/StatusNotifierItem"))
        self.assertEqual(M.parse_service("/org/ayatana/x", ":1.9"), (":1.9", "/org/ayatana/x"))
        self.assertEqual(M.parse_service("org.kde.foo"), ("org.kde.foo", "/StatusNotifierItem"))

    def test_pixmaps(self):
        pm = [(16, 16, bytes(16 * 16 * 4)), (32, 32, bytes(32 * 32 * 4)), (64, 64, b"")]
        self.assertEqual(M.best_pixmap(pm, 24)[0], 32)
        self.assertEqual(M.best_pixmap(pm, 48)[0], 32)
        self.assertEqual(M.argb_to_rgba(bytes([1, 2, 3, 4])), bytes([2, 3, 4, 1]))
        self.assertEqual(M.tint_rgba(bytes([9, 9, 9, 7]), (1, 2, 3)), bytes([1, 2, 3, 7]))

    def test_menu(self):
        self.assertEqual(M.menu_label("_Open"), "Open")
        self.assertEqual(M.menu_label("a__b"), "a_b")
        layout = [(1, {"label": "Steam", "children-display": "submenu"}, [(9, {}, [])]),
                  (2, {"type": "separator"}, []),
                  (3, {"label": "_Library"}, []),
                  (4, {"label": "Hidden", "visible": False}, []),
                  (5, {"label": "Mute", "toggle-type": "checkmark", "toggle-state": 1, "enabled": False}, [])]
        rows = M.menu_entries(layout, True, "steam")
        self.assertEqual([r["id"] for r in rows], [3, 5])
        self.assertTrue(rows[1]["checked"])
        self.assertFalse(rows[1]["enabled"])
        self.assertEqual(len(M.menu_entries(layout, False, "steam")), 4)

    def test_names(self):
        self.assertEqual(M.display_name({"id": "org/app"}), "app")
        self.assertEqual(M.tooltip({"id": "i", "title": "T"}), "T")
        self.assertTrue(M.is_symbolic("audio-volume-high-symbolic"))


if __name__ == "__main__":
    unittest.main()
