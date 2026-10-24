#!/usr/bin/env python3
"""shellder-monitor — port of omarchy.monitor (Display panel).

Original: /usr/share/omarchy/shell/plugins/panels/monitor/{Panel.qml,Model.js}.

  bar      󰍹 (one output) / 󰍺 (several); scroll changes the focused
           output's brightness in 5% steps (with Omarchy's OSD)
  click    Display panel: brightness name and slider, text size slider
           (omarchy-display-text-size), scale pills filtered to scales valid
           for the focused mode (omarchy-hyprland-monitor-scaling), and the
           output list with enable/disable (hl.monitor via hyprctl eval)

State comes from omarchy-monitor-state, refreshed on open and every 5 s while
open, like the original.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from gi.repository import GLib  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

CSS = """
.mon-value { font-size: %(caption)dpx; font-weight: bold; color: %(dim14)s; }
button.mon-scale { font-size: %(caption)dpx; padding: 4px 4px; }
.mon-row-icon { font-size: %(title)dpx; }
.mon-row-check { font-size: %(subtitle)dpx; }
.mon-row.disabled { opacity: 0.45; }
"""


def section_header(title):
    """PanelSectionHeader with a right-aligned value (e.g. "62%")."""
    Gtk = P.Gtk
    row = Gtk.Box(spacing=8)
    row.append(P.label(title, "sk-section", xalign=0, hexpand=True))
    value = P.label("", "mon-value", xalign=1)
    row.append(value)
    return row, value


class DisplayPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-monitor", width=380, css=CSS)
        self.timer = None
        self.debounce = None

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        box, self.hero = P.hero("󰍹", "Display", "")
        card.append(box)

        self.bright_sep = P.separator()
        card.append(self.bright_sep)
        self.bright_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        head, self.bright_value = section_header("BRIGHTNESS")
        self.bright_slider = P.slider(50, self.on_brightness, 1, 100, 1)
        self.bright_box.append(head)
        self.bright_box.append(self.bright_slider)
        card.append(self.bright_box)

        card.append(P.separator())
        text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        head, self.text_value = section_header("TEXT SIZE")
        self.text_slider = P.slider(3, self.on_text_size, 0, len(M.TEXT_SIZE_STOPS) - 1, 1)
        for i in range(len(M.TEXT_SIZE_STOPS)):
            self.text_slider.add_mark(i, P.Gtk.PositionType.BOTTOM, None)
        text_box.append(head)
        text_box.append(self.text_slider)
        card.append(text_box)

        card.append(P.separator())
        scale_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        head, self.scale_monitor = section_header("SCALE")
        self.scale_row = Gtk.Box(spacing=3, homogeneous=True)
        scale_box.append(head)
        scale_box.append(self.scale_row)
        card.append(scale_box)

        self.displays_sep = P.separator()
        card.append(self.displays_sep)
        self.displays_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        card.append(self.displays_box)

    def on_open(self):
        self.plugin.refresh()
        self.timer = GLib.timeout_add(5000, lambda: self.plugin.refresh() or True)

    def on_close(self):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None

    # ---- actions ------------------------------------------------------------

    def on_brightness(self, value):
        st = self.plugin.state
        st["brightness"] = M.clamp_brightness(value)
        self.update_hero()
        # Debounced like the original (180 ms) while dragging.
        if self.debounce:
            GLib.source_remove(self.debounce)
        self.debounce = GLib.timeout_add(180, self._apply_brightness)

    def _apply_brightness(self):
        self.debounce = None
        self.plugin.set_brightness(self.plugin.state["brightness"], osd=False)
        return False

    def on_text_size(self, value):
        px = M.TEXT_SIZE_STOPS[round(value)]
        self.text_value.set_label("%dpx" % px)
        self.plugin.run_cmd(["omarchy-display-text-size", str(px)])

    def set_scale(self, scale):
        self.plugin.run_cmd(["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale],
                            lambda *_: self.plugin.refresh())

    def toggle_display(self, d):
        st = self.plugin.state
        if d.get("enabled") and st["enabledCount"] <= 1:
            return
        out = json.dumps(d["name"])
        expr = ("hl.monitor({ output = %s, disabled = true })" % out if d.get("enabled") else
                'hl.monitor({ output = %s, disabled = false, mode = "preferred", position = "auto", scale = "auto" })' % out)
        self.plugin.run_cmd(["hyprctl", "eval", expr], lambda *_: self.plugin.refresh())

    def on_key(self, keyval, ch):
        K = P.Gdk
        if keyval in (K.KEY_Left, K.KEY_Right) and self.plugin.state["brightnessAvailable"]:
            delta = 5 if keyval == K.KEY_Right else -5
            self.plugin.set_brightness(self.plugin.state["brightness"] + delta, osd=False)
            return True
        return False

    # ---- refresh -------------------------------------------------------------

    def update_hero(self):
        st = self.plugin.state
        meta = M.brightness_name(st["brightness"]) if st["brightnessAvailable"] else "Fixed brightness"
        P.set_hero(self.hero, icon="󰍺" if len(st["displays"]) > 1 else "󰍹", meta=meta)
        self.bright_value.set_label("%d%%" % st["brightness"])

    def refresh(self):
        if self.window is None:
            return
        st = self.plugin.state
        self.update_hero()
        for w in (self.bright_sep, self.bright_box):
            w.set_visible(st["brightnessAvailable"])
        P.set_slider(self.bright_slider, st["brightness"])

        base = self.plugin.theme.size("body", 12)
        idx = M.nearest_text_stop(base)
        P.set_slider(self.text_slider, idx)
        self.text_value.set_label("%dpx" % base)

        focused = next((d for d in st["displays"] if d.get("focused")), {})
        scales = M.available_scales(M.SCALE_PRESETS, focused.get("width"), focused.get("height"))
        active = M.matching_scale_index(scales, st["scale"], focused.get("width"), focused.get("height"))
        self.scale_monitor.set_label(st["focused"] if st["enabledCount"] > 1 else "")
        P.clear(self.scale_row)
        for i, s in enumerate(scales):
            eff = M.clean_scale(s, focused.get("width"), focused.get("height")) or M.normalize_scale(s)
            b = P.button(eff + "x", lambda s=s: self.set_scale(s))
            b.add_css_class("mon-scale")
            if i == active:
                b.add_css_class("selected")
            self.scale_row.append(b)

        many = len(st["displays"]) > 1
        self.displays_sep.set_visible(many)
        self.displays_box.set_visible(many)
        P.clear(self.displays_box)
        if many:
            self.displays_box.append(P.section("DISPLAYS"))
            for d in st["displays"]:
                can = (not d.get("enabled")) or st["enabledCount"] > 1
                name = d.get("name", "") + (" · focused" if d.get("focused") else "")
                r = P.row(P.label("󰍹", "mon-row-icon"),
                          P.label(name, xalign=0, hexpand=True),
                          P.label("󰄬" if d.get("enabled") else "", "mon-row-check"),
                          selected=bool(d.get("focused")),
                          on_click=(lambda d=d: self.toggle_display(d)) if can else None)
                r.add_css_class("mon-row")
                if not can:
                    r.add_css_class("disabled")
                self.displays_box.append(r)


class Monitor(Plugin):
    def on_start(self):
        self.state = M.parse_state("")
        self.panel = DisplayPanel(self)
        self.refresh()
        # Outputs come and go: keep the bar glyph right without the panel open.
        self.every(10, self.refresh)

    def refresh(self):
        def done(ok, out, err):
            if ok:
                self.state = M.parse_state(out)
            self.render()
            if self.panel.opened:
                self.panel.refresh()
        self.run_cmd(["omarchy-monitor-state"], done)

    def render(self):
        self.emit(icon="󰍺" if len(self.state["displays"]) > 1 else "󰍹", text="")

    def set_brightness(self, value, osd=True):
        percent = M.clamp_brightness(value)
        self.state["brightness"] = percent
        argv = ["omarchy-brightness-display"] + ([] if osd else ["--no-osd"])
        if self.state["focused"]:
            argv += ["--monitor", self.state["focused"]]
        self.run_cmd(argv + ["%d%%" % percent])
        if self.panel.opened:
            self.panel.update_hero()

    def on_config(self, ev):
        self.panel.theme_changed()
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    def on_click(self, ev):
        if ev.get("button") == "left":
            self.panel.toggle(ev)

    def on_scroll(self, ev):
        if not self.state["brightnessAvailable"]:
            return
        self.set_brightness(self.state["brightness"] + (5 if ev.get("direction") == "up" else -5))


if __name__ == "__main__":
    Monitor().run()
