import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import model as M  # noqa: E402

XKB = """layouts:
- layout: 'us'
  variant: ''
  brief: 'en'
  description: English (US)
- layout: 'mm'
  variant: 'zawgyi'
  brief: 'my-zwg'
  description: Burmese (Zawgyi)
- layout: 'br'
  variant: ''
  description: Portuguese (Brazil)
option_groups:
- name: 'grp'
  description: Switching to another layout
"""


class KeyboardModelTest(unittest.TestCase):
    def test_briefs_and_label(self):
        b = M.layout_briefs(XKB)
        self.assertEqual(b, {"English (US)": "en", "Burmese (Zawgyi)": "my-zwg"})
        self.assertEqual(M.short_label("English (US)", b), "EN")
        self.assertEqual(M.short_label("Burmese (Zawgyi)", b), "MY")
        self.assertEqual(M.short_label("Portuguese (Brazil)", b), "POR")
        self.assertEqual(M.short_label("", b), "")

    def test_keyboards(self):
        kbs = [{"name": "power-button"}, {"name": "kb1", "active_layout_index": 0},
               {"name": "kb2", "active_layout_index": 1}]
        typed = [k for k in kbs if M.is_typed_keyboard(k["name"])]
        self.assertEqual([k["name"] for k in typed], ["kb1", "kb2"])
        self.assertEqual(M.select_keyboard(typed, "")["name"], "kb2")
        self.assertEqual(M.select_keyboard(typed, "kb1")["name"], "kb1")
        self.assertIsNone(M.select_keyboard([], ""))
        self.assertEqual(M.event_keyboard_name("kb1,English (US)"), "kb1")
        self.assertEqual(M.event_keyboard_name("hl-virtual-keyboard-1,x"), "")
        self.assertTrue(M.multiple_layouts({"layout": "br,us"}))
        self.assertFalse(M.multiple_layouts({"layout": "br"}))
        self.assertTrue(M.multiple_layouts({}))


if __name__ == "__main__":
    unittest.main()
