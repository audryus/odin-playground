#!/usr/bin/env python3
"""shellder-power — port of omarchy.power (battery, power profile, system stats).

Original: /usr/share/omarchy/shell/plugins/panels/power/{Panel.qml,Model.js}.

  bar          battery icon (or "NN% icon" with showPercentage); hidden when
               there is no battery, as in Omarchy
  left click   the power panel: hero with rotating status phrases and the
               percentage, charge bar, battery size/cycles/time/rate, power
               profile buttons (omarchy-powerprofiles-set)
  right click  toggles showPercentage (saved in shell.json)

UPower is read over D-Bus (org.freedesktop.UPower DisplayDevice), so the bar
updates on PropertiesChanged without polling; the panel refreshes its details
every 5 s while open, like the original.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from gi.repository import Gio, GLib  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

UPOWER = "org.freedesktop.UPower"
DISPLAY_DEVICE = "/org/freedesktop/UPower/devices/DisplayDevice"

CSS = """
.pw-percent { font-size: %(display_large)dpx; font-weight: bold; }
.pw-info-label { font-size: %(body_small)dpx; opacity: 0.6; }
.pw-info-value { font-size: %(body_small)dpx; }
button.pw-profile { padding: 8px 10px; }
button.pw-profile .pw-icon { font-size: %(title)dpx; }
button.pw-profile .pw-name { font-size: %(body_small)dpx; }
"""


class ChargeBar:
    """The 8 px charge bar under the hero (pulses while charging)."""

    def __init__(self, plugin):
        Gtk = P.Gtk
        self.plugin = plugin
        self.fraction = 0.0
        self.pulse = 1.0
        self.area = Gtk.DrawingArea(hexpand=True, content_height=8)
        self.area.set_draw_func(self._draw)

    def set(self, fraction):
        self.fraction = fraction
        self.area.queue_draw()

    def _draw(self, area, cr, w, h):
        import math
        th = self.plugin.theme
        r = h / 2

        def pill(width, color):
            cr.set_source_rgba(*color)
            cr.new_sub_path()
            cr.arc(width - r, r, r, -math.pi / 2, math.pi / 2)
            cr.arc(r, r, r, math.pi / 2, 3 * math.pi / 2)
            cr.close_path()
            cr.fill()
        fg = th.bar_text
        pill(w, (fg[0], fg[1], fg[2], 0.12))
        pill(max(h, w * self.fraction), (fg[0], fg[1], fg[2], fg[3] * self.pulse))


class PowerPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-power", width=380, css=CSS)
        self.battery_info = {}
        self.system_info = {}
        self.profiles = []
        self.active_profile = ""
        self.phrase_index = 0
        self.timers = []

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        self.percent = P.label("—", "pw-percent")
        box, self.hero = P.hero("", "Battery", "", trailing=self.percent)
        card.append(box)
        self.bar = ChargeBar(self.plugin)
        card.append(self.bar.area)

        self.info = Gtk.Box(spacing=20, homogeneous=True)
        self.info_values = {}
        for column in (("Battery size", "Charge cycles"), ("time", "rate")):
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            for key in column:
                row = Gtk.Box(spacing=8)
                lbl = P.label(key, "pw-info-label", xalign=0, hexpand=True)
                val = P.label("", "pw-info-value", xalign=1)
                row.append(lbl)
                row.append(val)
                col.append(row)
                self.info_values[key] = (lbl, val)
            self.info.append(col)
        card.append(self.info)
        card.append(P.separator())
        card.append(P.section("POWER PROFILE"))
        self.profile_row = Gtk.Box(spacing=6, homogeneous=True)
        card.append(self.profile_row)

    def on_open(self):
        self.refresh_details()
        self.timers = [GLib.timeout_add(5000, self._details_tick),
                       GLib.timeout_add(2800, self._phrase_tick)]

    def on_close(self):
        for t in self.timers:
            GLib.source_remove(t)
        self.timers = []

    def _details_tick(self):
        self.refresh_details()
        return True

    def _phrase_tick(self):
        self.phrase_index += 1
        self.refresh()
        return True

    def refresh_details(self):
        p = self.plugin

        def battery(ok, out, err):
            self.battery_info = M.parse_key_value(out) or self.battery_info
            self.refresh()

        def system(ok, out, err):
            self.system_info = M.parse_key_value(out) or self.system_info

        def profiles(ok, out, err):
            parsed = M.parse_profiles(out)
            if parsed["profiles"]:
                self.profiles = parsed["profiles"]
                self.active_profile = parsed["activeProfile"]
                self.rebuild_profiles()
        p.run_cmd(["omarchy-battery-status", "--shell"], battery)
        p.run_cmd(["omarchy-powerprofiles-list", "--active-state"], profiles)
        p.run_cmd(["omarchy-system-stats"], system)

    def rebuild_profiles(self):
        Gtk = P.Gtk
        P.clear(self.profile_row)
        for name in self.profiles:
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            inner.append(P.label(M.profile_icon(name), "pw-icon"))
            inner.append(P.label(name[:1].upper() + name[1:], "pw-name"))
            b = Gtk.Button(child=inner)
            b.add_css_class("sk-button")
            b.add_css_class("pw-profile")
            if name == self.active_profile:
                b.add_css_class("selected")
            b.set_cursor_from_name("pointer")
            b.connect("clicked", lambda _b, n=name: self.set_profile(n))
            self.profile_row.append(b)

    def set_profile(self, name):
        mode = "battery" if self.plugin.on_battery else "ac"
        self.plugin.run_cmd(["omarchy-powerprofiles-set", mode, name], lambda *_: self.refresh_details())

    def on_key(self, keyval, ch):
        K = P.Gdk
        if keyval in (K.KEY_Left, K.KEY_Right) and self.profiles:
            i = self.profiles.index(self.active_profile) if self.active_profile in self.profiles else 0
            i = M.select_profile_index(i, -1 if keyval == K.KEY_Left else 1, self.profiles)
            self.set_profile(self.profiles[i])
            return True
        return False

    def refresh(self):
        if self.window is None:
            return
        pl = self.plugin
        d, on_batt = pl.device, pl.on_battery
        fraction = M.battery_fraction(d)
        full = d.get("state") == M.FULLY_CHARGED and not M.charge_threshold_active(d, on_batt)
        threshold = M.charge_threshold_active(d, on_batt)
        charging = d.get("present") and not on_batt and not (full or threshold or fraction >= 1)
        phrases = [] if full else (M.CHARGING_PHRASES if charging else
                                   (M.ON_BATTERY_PHRASES if on_batt else []))
        status = "Fully charged" if full else (phrases[self.phrase_index % len(phrases)]
                                               if phrases else M.mode_label(d, on_batt))
        P.set_hero(self.hero, icon=M.battery_icon(d, on_batt), meta=status)
        self.percent.set_label(self.battery_info.get("percentage") or "—")
        self.bar.pulse = 1.0
        self.bar.set(fraction)

        info = self.battery_info
        idle = full or threshold or (not on_batt and fraction >= 1)
        rows = {
            "Battery size": ("Battery size", info.get("size", "")),
            "Charge cycles": ("Charge cycles", info.get("cycles") or "—"),
            "time": ("Charge limit" if threshold else ("Time left" if on_batt else "Time to full"),
                     (info.get("threshold") or "-") if threshold else ("-" if idle else info.get("time") or "—")),
            "rate": ("Battery state" if threshold else ("Discharging" if on_batt else "Charging"),
                     "Holding" if threshold else ("-" if idle else info.get("rate", ""))),
        }
        for key, (label, value) in rows.items():
            lbl, val = self.info_values[key]
            lbl.set_label(label)
            val.set_label(value)
        self.info.set_visible("percentage" in info)


class Power(Plugin):
    def on_start(self):
        self.device = {}
        self.on_battery = False
        self.panel = PowerPanel(self)
        self.proxy = None
        self.upower = None
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            self.proxy = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, UPOWER,
                                                DISPLAY_DEVICE, UPOWER + ".Device", None)
            self.upower = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, UPOWER,
                                                 "/org/freedesktop/UPower", UPOWER, None)
            self.proxy.connect("g-properties-changed", lambda *_: self.read_upower())
            self.upower.connect("g-properties-changed", lambda *_: self.read_upower())
        except GLib.Error as e:
            print("shellder-power: no UPower: %s" % e, file=sys.stderr)
        self.read_upower()

    def read_upower(self):
        def prop(proxy, name, default):
            v = proxy.get_cached_property(name) if proxy else None
            return v.unpack() if v is not None else default
        self.device = {
            "present": bool(prop(self.proxy, "IsPresent", False)),
            "percentage": float(prop(self.proxy, "Percentage", 0.0)) / 100.0,
            "state": int(prop(self.proxy, "State", 0)),
            "rate": float(prop(self.proxy, "EnergyRate", 0.0)),
            "time_to_full": int(prop(self.proxy, "TimeToFull", 0)),
        }
        self.on_battery = bool(prop(self.upower, "OnBattery", False)) and self.device["present"]
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    def render(self):
        if not self.device.get("present"):
            if self.panel.opened:
                self.panel.close()
            self.emit(visible=False)
            return
        icon = M.battery_icon(self.device, self.on_battery)
        if self.setting("showPercentage", False) is True and not self.vertical:
            self.emit(visible=True, icon="",
                      text="%d%% %s" % (round(M.battery_fraction(self.device) * 100), icon))
        else:
            self.emit(visible=True, icon=icon, text="")

    def on_config(self, ev):
        self.panel.theme_changed()
        self.render()

    def on_click(self, ev):
        if not self.device.get("present"):
            return
        if ev.get("button") == "right":
            self.save_settings({"showPercentage": not (self.setting("showPercentage", False) is True)})
            self.render()
        elif ev.get("button") == "left":
            self.panel.toggle(ev)


if __name__ == "__main__":
    Power().run()
