import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class BluetoothModelTest(unittest.TestCase):
    def test_names(self):
        self.assertTrue(M.is_address_like("0B:14:9D:C7:8F:B9"))
        self.assertTrue(M.is_uuid_like("0000110b-0000-1000-8000-00805f9b34fb"))
        self.assertFalse(M.has_human_name({"Alias": "0B-14-9D-C7-8F-B9"}))
        self.assertTrue(M.has_human_name({"Alias": "AIWA Headphone HP-04"}))

    def test_lists(self):
        l = M.device_lists([{"Alias": "b", "Paired": True}, {"Alias": "a", "Connected": True},
                            {"Alias": "c"}, {"Alias": "AA:BB:CC:DD:EE:FF"}])
        self.assertEqual([M.device_label(d) for d in l["connected"]], ["a"])
        self.assertEqual([M.device_label(d) for d in l["known"]], ["b"])
        self.assertEqual([M.device_label(d) for d in l["discovered"]], ["c"])

    def test_icon_status(self):
        self.assertEqual(M.bar_icon(None, 0), "")
        self.assertEqual(M.bar_icon({"Powered": False}, 0), "󰂲")
        self.assertEqual(M.bar_icon({"Powered": True}, 1), "󰂱")
        self.assertEqual(M.status_text({"Connected": True, "Battery": 80}, "connected", ""), "80%")
        self.assertEqual(M.status_text({}, "known", "connecting"), "Connecting…")
        self.assertEqual(M.action_tooltip({}, "discovered"), "Pair")


if __name__ == "__main__":
    unittest.main()
