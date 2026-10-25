import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class NetworkModelTest(unittest.TestCase):
    def test_status_icons(self):
        st = M.parse_network_status("ethernet\tenp16s0\t\t\n")
        self.assertEqual(st["kind"], "ethernet")
        self.assertEqual(M.connection_icon("ethernet", -1), "󰈀")
        self.assertEqual(M.connection_icon("wifi", 100), "󰤨")
        self.assertEqual(M.connection_icon("wifi", 10), "󰤯")
        self.assertEqual(M.connection_icon("disconnected", -1), "󰤮")

    def test_formats(self):
        self.assertEqual(M.format_header_speed("1000"), "1gbit")
        self.assertEqual(M.format_header_speed("2500"), "2.5gbit")
        self.assertEqual(M.format_bytes(9835362693), "9.16 GB")
        self.assertEqual(M.format_ping(1.27), "1.3 ms")
        self.assertEqual(M.format_ping(11.8), "12 ms")
        self.assertEqual(M.format_ping(None), "Timeout")
        self.assertEqual(M.band_section_title("auto", "5"), "WI-FI BAND: 5GHZ")

    def test_rolling(self):
        r = M.throughput_state({}, {"iface": "e", "rx_bytes": "1000", "tx_bytes": "0"}, 10.0)
        r = M.throughput_state(r, {"iface": "e", "rx_bytes": "4000", "tx_bytes": "300"}, 11.5)
        self.assertEqual((r["down"], r["up"]), (2000.0, 200.0))
        p = M.ping_state({}, {"iface": "e", "internet_ping_ms": "10"})
        p = M.ping_state(p, {"iface": "e", "internet_ping_ms": "timeout"})
        self.assertEqual(M.packet_loss(p["internet"]), 50)
        self.assertEqual(M.average_ping(p["internet"]), 10)

    def test_wifi(self):
        rows = M.sort_wifi([{"ssid": "b", "connected": False, "known": False, "signal": 80},
                            {"ssid": "a", "connected": False, "known": True, "signal": 20}])
        self.assertEqual([r["ssid"] for r in rows], ["a", "b"])
        self.assertEqual(M.wifi_section_title(rows, 0), "KNOWN NETWORKS")
        self.assertEqual(M.wifi_section_title(rows, 1), "OTHER NETWORKS")
        self.assertEqual(M.nmcli_split(r"*:My\:Net:70:WPA2"), ["*", "My:Net", "70", "WPA2"])
        self.assertFalse(M.requires_credentials("--"))


if __name__ == "__main__":
    unittest.main()
