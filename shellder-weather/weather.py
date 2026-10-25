#!/usr/bin/env python3
"""shellder-weather — port of omarchy.weather.

Original: /usr/share/omarchy/shell/plugins/panels/weather/{BarWidget.qml,
Panel.qml,Model.js}.

  bar           current-condition glyph (hidden until there is data)
  left click    Weather panel: big glyph and temperature, location (click to
                search and set a city), feels / wind / humidity, 3-day forecast
  right click   notification with omarchy-weather-status, as in Omarchy
  middle click  refresh

Data, as in the original: open-meteo for current conditions and the daily
forecast (fast, needs coordinates), wttr.in for auto-detected location and as
fallback. The location lives in Omarchy's own
~/.local/state/omarchy/settings/weather.json (omarchy-weather-location), so it
is shared with the Omarchy bar. Settings: "unit" (metric|imperial) and
"refreshMinutes" (default 15), same keys as omarchy.weather.
"""

import datetime as dt
import json
import locale
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from shellder_kit import loop  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

LOCATION_FILE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                             "omarchy", "settings", "weather.json")

CSS = """
.wx-icon { font-size: 64px; }
.wx-temp { font-size: 56px; font-weight: bold; }
.wx-unit { font-size: %(display)dpx; }
.wx-location { font-size: %(body)dpx; letter-spacing: 1px; }
.wx-location-row:hover .wx-location { color: %(accent)s; }
.wx-stat-label { font-size: %(body_small)dpx; color: %(dim15)s; }
.wx-stat { font-size: %(title)dpx; }
.wx-day-icon { font-size: %(display)dpx; }
.wx-day-name { font-size: %(caption)dpx; font-weight: bold; color: %(dim14)s; }
.wx-day-max { font-size: %(body)dpx; }
.wx-day-min { font-size: %(body)dpx; color: %(dim15)s; }
.wx-suggest-desc { font-size: %(body_small)dpx; color: %(dim15)s; }
"""


class WeatherPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-weather", width=480, css=CSS)
        self.editing = False
        self.suggestions = []
        self.geocode_timer = None

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        top = Gtk.Box(spacing=16)
        self.icon = P.label("—", "wx-icon")
        top.append(self.icon)
        temp = Gtk.Box(spacing=2, valign=Gtk.Align.CENTER)
        self.temp = P.label("—", "wx-temp", valign=Gtk.Align.BASELINE)
        self.unit = P.label("", "wx-unit", valign=Gtk.Align.BASELINE)
        temp.append(self.temp)
        temp.append(self.unit)
        top.append(temp)

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, hexpand=True,
                        valign=Gtk.Align.CENTER)
        self.loc_row = Gtk.Box(spacing=6)
        self.loc_row.add_css_class("wx-location-row")
        self.loc_row.set_cursor_from_name("pointer")
        self.loc_row.set_tooltip_text("Set location")
        self.loc_row.append(P.label("", "wx-location"))  # nf-fa-map_marker
        self.loc = P.label("", "wx-location", xalign=0, ellipsize=3, hexpand=True)
        self.loc_row.append(self.loc)
        P.on_click_gesture(self.loc_row, self.start_editing)
        right.append(self.loc_row)

        self.edit_row = Gtk.Box(spacing=6)
        self.entry = Gtk.Entry(placeholder_text="Search city", hexpand=True)
        self.entry.add_css_class("sk-entry")
        self.entry.connect("changed", lambda e: self.schedule_geocode())
        self.entry.connect("activate", lambda e: self.commit())
        self.edit_row.append(self.entry)
        self.edit_row.append(P.action_button("✕", self.clear_location, "Clear location"))
        right.append(self.edit_row)

        self.stats = Gtk.Box(spacing=36)
        self.stat_values = {}
        for name in ("FEELS", "WIND", "HUMID"):
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
            col.append(P.label(name, "wx-stat-label", xalign=0))
            v = P.label("", "wx-stat", xalign=0)
            col.append(v)
            self.stat_values[name] = v
            self.stats.append(col)
        right.append(self.stats)
        top.append(right)
        card.append(top)

        self.suggest_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.append(self.suggest_box)
        self.fetching = P.label("Fetching forecast…", "wx-suggest-desc", xalign=0)
        card.append(self.fetching)
        self.forecast_sep = P.separator()
        card.append(self.forecast_sep)
        self.forecast = Gtk.Box(spacing=44, halign=Gtk.Align.CENTER)
        card.append(self.forecast)

    # ---- location ---------------------------------------------------------------

    def start_editing(self):
        self.editing = True
        self.entry.set_text(self.plugin.location["name"])
        self.refresh()
        self.entry.grab_focus()
        self.entry.select_region(0, -1)

    def cancel_editing(self):
        self.editing = False
        self.suggestions = []
        self.refresh()

    def schedule_geocode(self):
        if self.geocode_timer:
            loop.source_remove(self.geocode_timer)
        self.geocode_timer = loop.timeout_add(300, self._geocode)

    def _geocode(self):
        self.geocode_timer = None
        query = self.entry.get_text().strip()
        if len(query) < 2:
            self.suggestions = []
            self.refresh_suggestions()
            return False
        url = ("https://geocoding-api.open-meteo.com/v1/search?name=%s&count=5&language=en&format=json"
               % urllib.parse.quote(query))

        def done(ok, out, err):
            if self.editing and self.entry.get_text().strip() == query:
                self.suggestions = M.parse_geocoding(out) if ok else []
                self.refresh_suggestions()
        self.plugin.run_cmd(["curl", "-fsS", "--max-time", "5", url], done)
        return False

    def refresh_suggestions(self):
        Gtk = P.Gtk
        P.clear(self.suggest_box)
        self.suggest_box.set_visible(self.editing and bool(self.suggestions))
        for s in self.suggestions:
            row = Gtk.Box(spacing=8)
            row.append(P.label(s["name"], xalign=0))
            if s["description"]:
                row.append(P.label(s["description"], "wx-suggest-desc", xalign=0))
            self.suggest_box.append(P.row(row, on_click=lambda s=s: self.pick(s)))

    def commit(self):
        text = self.entry.get_text().strip()
        if not text:
            self.clear_location()
        elif self.suggestions:
            self.pick(self.suggestions[0])
        else:
            self.plugin.save_location(text, None, None)
            self.cancel_editing()

    def pick(self, s):
        self.plugin.save_location(s["name"], s["latitude"], s["longitude"])
        self.cancel_editing()

    def clear_location(self):
        self.plugin.save_location("", None, None)
        self.cancel_editing()

    def on_key(self, keyval, ch):
        if self.editing and keyval == P.Gdk.KEY_Escape:
            self.cancel_editing()
            return True
        if not self.editing and keyval == P.Gdk.KEY_Return:
            self.start_editing()
            return True
        return False

    def on_close(self):
        self.editing = False

    # ---- refresh ------------------------------------------------------------------

    def refresh(self):
        if self.window is None:
            return
        Gtk = P.Gtk
        pl = self.plugin
        cur, imperial = pl.current(), pl.imperial()
        self.icon.set_label(pl.label or "—")
        self.temp.set_label((cur["tempF"] if imperial else cur["tempC"]) if cur else "—")
        self.unit.set_label(("°F" if imperial else "°C") if cur else "")
        loc = pl.report_location()
        self.loc.set_label(loc.upper())
        self.loc_row.set_visible(not self.editing and loc != "")
        self.edit_row.set_visible(self.editing)
        self.stats.set_visible(bool(cur))
        if cur:
            self.stat_values["FEELS"].set_label(M.format_temp(cur["feelsF"] if imperial else cur["feelsC"], imperial))
            self.stat_values["WIND"].set_label(("%s mph" % cur["windMph"]) if imperial else ("%s km/h" % cur["windKmh"]))
            self.stat_values["HUMID"].set_label("%s%%" % cur["humidity"])
        self.fetching.set_visible(cur is None)
        self.refresh_suggestions()

        days = pl.forecast_days()
        self.forecast_sep.set_visible(bool(days))
        self.forecast.set_visible(bool(days))
        P.clear(self.forecast)
        for d in days:
            row = Gtk.Box(spacing=10)
            row.append(P.label(M.icon_for_open_meteo(d["code"]) if d.get("code") is not None else d.get("icon", ""),
                               "wx-day-icon"))
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
            col.append(P.label(M.day_name(d["date"]).upper(), "wx-day-name", xalign=0))
            temps = Gtk.Box(spacing=6)
            temps.append(P.label((d["maxF"] if imperial else d["maxC"]) + "°", "wx-day-max"))
            temps.append(P.label((d["minF"] if imperial else d["minC"]) + "°", "wx-day-min"))
            col.append(temps)
            row.append(col)
            self.forecast.append(row)


class Weather(Plugin):
    def on_start(self):
        self.location = M.parse_location_file("")
        self.location_mtime = None
        self.wttr = None          # wttr.in j1 report
        self.meteo = None         # open-meteo report
        self.wttr_location = ""
        self.label = ""
        self.panel = WeatherPanel(self)
        self.timer = None
        self.read_location()
        self.every(1.5, self.watch_location)
        self.refresh()

    # ---- data ---------------------------------------------------------------------

    def read_location(self):
        try:
            self.location_mtime = os.stat(LOCATION_FILE).st_mtime
            with open(LOCATION_FILE) as f:
                self.location = M.parse_location_file(f.read())
        except OSError:
            self.location_mtime = None
            self.location = M.parse_location_file("")

    def watch_location(self):
        try:
            m = os.stat(LOCATION_FILE).st_mtime
        except OSError:
            m = None
        if m != self.location_mtime:
            self.read_location()
            self.refresh()

    def has_coords(self):
        return self.location["latitude"] is not None and self.location["longitude"] is not None

    def refresh(self):
        loc = self.location
        query = M.wttr_location_query(loc["name"], loc["latitude"], loc["longitude"])

        def wttr_done(ok, out, err):
            try:
                self.wttr = json.loads(out) if ok else self.wttr
            except ValueError:
                pass
            if not self.has_coords():
                self.refresh_meteo()
            self.update()
        self.run_cmd(["curl", "-fsS", "--max-time", "10", "https://wttr.in/%s?format=j1" % query], wttr_done)
        if not query:
            def where(ok, out, err):
                if ok and out.strip():
                    self.wttr_location = out.strip().split(",")[0]
                    self.update()
            self.run_cmd(["curl", "-fsS", "--max-time", "4", "https://wttr.in/?format=%l"], where)
        if self.has_coords():
            self.refresh_meteo()
        self.schedule_refresh()

    def schedule_refresh(self):
        if self.timer:
            loop.source_remove(self.timer)
        try:
            minutes = max(1, int(self.setting("refreshMinutes", 15)))
        except (TypeError, ValueError):
            minutes = 15
        self.timer = loop.timeout_add_seconds(minutes * 60, lambda: self.refresh() and False)

    def refresh_meteo(self):
        lat, lon = self.location["latitude"], self.location["longitude"]
        if lat is None or lon is None:
            area = ((self.wttr or {}).get("nearest_area") or [None])[0]
            if not area:
                return
            lat, lon = area.get("latitude"), area.get("longitude")
        url = ("https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
               "&daily=weather_code,temperature_2m_max,temperature_2m_min"
               "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
               "&forecast_days=4&timezone=auto" % (lat, lon))

        def done(ok, out, err):
            try:
                self.meteo = json.loads(out) if ok else self.meteo
            except ValueError:
                pass
            self.update()
        self.run_cmd(["curl", "-fsS", "--max-time", "5", url], done)

    def current(self):
        meteo = M.open_meteo_current(self.meteo)
        if self.has_coords() and meteo:
            return meteo
        return M.wttr_current(self.wttr) or meteo

    def country(self):
        area = ((self.wttr or {}).get("nearest_area") or [None])[0] or {}
        return ((area.get("country") or [{}])[0]).get("value", "")

    def imperial(self):
        return M.should_use_imperial(self.setting("unit", ""), locale.getlocale()[0] or os.environ.get("LANG", ""),
                                     self.country())

    def report_location(self):
        area = ((self.wttr or {}).get("nearest_area") or [None])[0] or {}
        name = ((area.get("areaName") or [{}])[0]).get("value", "")
        return self.location["name"] or self.wttr_location or name

    def forecast_days(self):
        today = dt.date.today().isoformat()
        days = M.open_meteo_days(self.meteo, today)
        if days:
            return days
        out = []
        for d in (self.wttr or {}).get("weather") or []:
            if len(out) >= 3:
                break
            if str(d.get("date", ""))[:10] > today:
                hourly = d.get("hourly") or [{}]
                noon = min(hourly, key=lambda h: abs(int(h.get("time") or 0) - 1200))
                out.append({"date": d["date"], "maxC": d.get("maxtempC", ""), "minC": d.get("mintempC", ""),
                            "maxF": d.get("maxtempF", ""), "minF": d.get("mintempF", ""),
                            "icon": M.icon_for_code(noon.get("weatherCode"))})
        return out

    def save_location(self, name, lat, lon):
        if name and lat is not None and lon is not None:
            argv = ["omarchy-weather-location", "--set", name, "%s,%s" % (lat, lon)]
        elif name:
            argv = ["omarchy-weather-location", "--set", name]
        else:
            argv = ["omarchy-weather-location", "--clear"]
        self.location = {"name": name, "latitude": lat, "longitude": lon}
        self.wttr_location = ""
        self.run_cmd(argv, lambda *_: (self.read_location(), self.refresh()))

    # ---- bar ------------------------------------------------------------------------

    def update(self):
        # As in Omarchy: the bar glyph comes from open-meteo whenever it has
        # answered; wttr's only fills in provisionally until then. (The panel
        # numbers prefer wttr without stored coordinates — see current().)
        meteo = M.open_meteo_current(self.meteo)
        if meteo:
            self.label = M.current_icon(meteo, self.label)
        elif not self.label:
            self.label = M.current_icon(M.wttr_current(self.wttr), "")
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    def render(self):
        slot = self.theme.bar_token("statusSlot", 21)
        if not self.label:
            self.emit(visible=False)
        else:
            self.emit(visible=True, segments=[{"id": "weather", "text": self.label, "width": slot,
                                              "font": "iconFont"}])

    def on_config(self, ev):
        self.panel.theme_changed()
        self.render()
        self.schedule_refresh()

    def on_click(self, ev):
        button = ev.get("button")
        if button == "right":
            self.run_cmd(["bash", "-c", 'omarchy-notification-send "$(omarchy-weather-status)"'])
        elif button == "middle":
            self.refresh()
        else:
            self.panel.toggle(ev)


if __name__ == "__main__":
    Weather().run()
