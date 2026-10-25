#!/usr/bin/env python3
"""shellder-clock — date/time on the Shellder bar, with a calendar and a big
hover clock.

Port of Omarchy's clock (omarchy.clock):
  left click    toggles the calendar (calendar_panel.py)
  right click   Shellder's menu, declared in manifest.json (next format,
                calendar, timezone, copy date)
  middle click  timezone picker (omarchy-menu-timezone), as in Omarchy
  hover         a passive card with the time in big digits ("hover": "event")

Settings live in the plugin's entry in Shellder's shell.json, with the same
keys as omarchy.clock in Omarchy's shell.json: format, formatAlt,
verticalFormat, verticalFormatAlt, weekStartDay, birthYear, lifeExpectancy.
"""

import datetime as dt
import os
import shutil
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from shellder_kit import Plugin, loop  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402
from calendar_panel import CalendarPanel  # noqa: E402

BIG_CSS = """
.clock-big { font-size: 64px; font-weight: bold; }
.clock-big-seconds { font-size: %(display)dpx; color: %(dim14)s; }
"""


class BigClock(P.HoverPopup):
    """The hover card: the current time, large, with live seconds."""

    def __init__(self, plugin):
        super().__init__(plugin, "shellder-clock-hover", css=BIG_CSS)
        self.timer = None

    def build(self, card):
        Gtk = P.Gtk
        row = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        self.hm = P.label("", "clock-big", valign=Gtk.Align.BASELINE)
        self.ss = P.label("", "clock-big-seconds", valign=Gtk.Align.BASELINE)
        row.append(self.hm)
        row.append(self.ss)
        card.append(row)

    def refresh(self):
        now = dt.datetime.now()
        ampm = "AP" in self.plugin.configured_format()
        self.hm.set_label(M.format_qt(now, "h:mm AP" if ampm else "HH:mm"))
        self.ss.set_label(M.format_qt(now, "ss"))

    def show(self, event):
        super().show(event)
        if self.timer is None:
            self.timer = loop.timeout_add(250, self._tick)

    def hide(self):
        super().hide()
        if self.timer is not None:
            loop.source_remove(self.timer)
            self.timer = None

    def _tick(self):
        if self.window is not None:
            self.refresh()
        return True


class Clock(Plugin):
    def on_start(self):
        self.calendar = CalendarPanel(self)
        self.big = BigClock(self)
        self.anchor = None  # last hover/click event: where the item is
        self.schedule_tick()

    # ---- formats ------------------------------------------------------------

    def format_key(self):
        return "verticalFormat" if self.vertical else "format"

    def configured_format(self):
        default = M.DEFAULT_VERTICAL_FORMAT if self.vertical else M.DEFAULT_FORMAT
        return self.setting(self.format_key()) or default

    def configured_alt_format(self):
        key = "verticalFormatAlt" if self.vertical else "formatAlt"
        default = M.DEFAULT_VERTICAL_FORMAT_ALT if self.vertical else M.DEFAULT_FORMAT_ALT
        return self.setting(key) or default

    def cycle_format(self):
        ring = M.clock_format_ring(self.configured_format(), self.configured_alt_format(),
                                   M.clock_formats(self.vertical))
        nxt = M.next_clock_format(ring, self.configured_format())
        if nxt and nxt != self.configured_format():
            self.save_settings({self.format_key(): nxt})
            self.render()

    # ---- bar ------------------------------------------------------------------

    def render(self):
        self.emit(text=M.format_qt(dt.datetime.now(), self.configured_format()))

    def schedule_tick(self):
        # Wake right after the minute turns.
        now = dt.datetime.now()
        ms = (60 - now.second) * 1000 - now.microsecond // 1000 + 50
        self.later(ms / 1000, self.on_tick)

    def on_tick(self):
        self.render()
        self.calendar.tick()
        self.schedule_tick()

    # ---- Shellder events ------------------------------------------------------

    def on_config(self, ev):
        self.calendar.theme_changed()
        self.render()

    def on_click(self, ev):
        self.anchor = ev
        button = ev.get("button")
        if button == "left":
            self.big.hide()
            self.calendar.toggle(ev)
        elif button == "middle":
            self.open_timezone_picker()

    def on_hover(self, ev):
        # The big clock is for a glance: not while the calendar is open.
        if ev.get("hovered"):
            self.anchor = ev
        if ev.get("hovered") and not self.calendar.opened:
            self.big.show(ev)
        else:
            self.big.hide()

    def on_menu(self, ev):
        item = ev.get("id")
        if item == "next-format":
            self.cycle_format()
        elif item == "calendar":
            self.big.hide()
            self.calendar.toggle(self.anchor or {"monitor": ev.get("monitor"), "bar": self.bar})

    def open_timezone_picker(self):
        cmd = shutil.which("omarchy-menu-timezone")
        if not cmd:
            print("shellder-clock: omarchy-menu-timezone not found", file=sys.stderr)
            return
        self.run_detached([cmd])


if __name__ == "__main__":
    Clock().run()
