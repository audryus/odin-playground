import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402


class AudioModelTest(unittest.TestCase):
    def test_names(self):
        self.assertEqual(M.output_volume_name(0.5, True), "Muted")
        self.assertEqual(M.output_volume_name(0, False), "Silenced")
        self.assertEqual(M.output_volume_name(1, False), "Concert hall")
        self.assertEqual(M.output_volume_name(0.43, False), "Easy listening")
        self.assertEqual(M.output_volume_name(0.05, False), "Whisper")

    def test_icons(self):
        self.assertEqual(M.output_icon(0.8, False, False), "\uf028")
        self.assertEqual(M.output_icon(0.4, False, False), "\uf027")
        self.assertEqual(M.output_icon(0.1, False, False), "\uf026")
        self.assertEqual(M.output_icon(0.4, False, True), "\U000f02cb")
        self.assertEqual(M.output_icon(0.4, True, False), "\ueee8")

    def test_labels_and_glyphs(self):
        hdmi = {"name": "alsa_output.pci.hdmi-stereo", "description": "Navi 31 HDMI/DP Audio",
                "properties": {"node.nick": "SAMSUNG"}}
        self.assertEqual(M.node_label(hdmi), "SAMSUNG")
        self.assertEqual(M.sink_glyph(hdmi), "󰍹")
        self.assertEqual(M.friendly_device_label("Built-in Audio Analog Output"), "Analog")
        self.assertEqual(M.volume_of({"volume": {"fl": {"value_percent": "40%"}, "fr": {"value_percent": "60%"}}}), 0.5)
        self.assertEqual(M.parse_sink_availability("a\t1\nb\t0\n"), {"a": True, "b": False})


if __name__ == "__main__":
    unittest.main()
