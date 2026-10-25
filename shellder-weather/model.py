"""Weather logic — port of Omarchy's weather Model.js
(/usr/share/omarchy/shell/plugins/panels/weather/Model.js). Pure, tested.

The icon glyphs are BMP private-use code points, written as escapes so no
editor can silently drop them."""

import datetime as dt
import json
import math
import re
import urllib.parse

DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


def parse_location_file(raw):
    unset = {"name": "", "latitude": None, "longitude": None}
    try:
        data = json.loads(str(raw or ""))
    except ValueError:
        return unset
    if not isinstance(data, dict):
        return unset
    lat, lon = _num(data.get("latitude")), _num(data.get("longitude"))
    has = lat is not None and lon is not None
    name = data.get("name")
    return {"name": name.strip() if isinstance(name, str) else "",
            "latitude": lat if has else None, "longitude": lon if has else None}


def _num(v):
    try:
        n = float(v)
    except (TypeError, ValueError):
        return None
    return n if math.isfinite(n) else None


def wttr_location_query(name, lat, lon):
    if _num(lat) is not None and _num(lon) is not None:
        return "%s,%s" % (_fmt_coord(lat), _fmt_coord(lon))
    name = str(name or "").strip()
    return urllib.parse.quote(name) if name else ""


def _fmt_coord(v):
    n = float(v)
    return str(int(n)) if n == int(n) else repr(n)


def parse_geocoding(raw):
    try:
        data = json.loads(str(raw or "{}"))
    except ValueError:
        return []
    out = []
    for r in data.get("results") or []:
        if not r or not r.get("name") or r.get("latitude") is None or r.get("longitude") is None:
            continue
        region = ", ".join(p for p in (r.get("admin1"), r.get("country")) if p)
        out.append({"name": str(r["name"]), "description": region,
                    "latitude": r["latitude"], "longitude": r["longitude"]})
    return out


def rounded(value):
    n = _num(value)
    return "" if n is None else str(int(math.floor(n + 0.5)))


def c_to_f(value):
    n = _num(value)
    return None if n is None else n * 9 / 5 + 32


def format_temp(value, imperial):
    return "" if value in (None, "") else "%s°%s" % (value, "F" if imperial else "C")


def locale_uses_imperial(locale_name):
    name = str(locale_name or "").replace(".", "_")
    return bool(re.match(r"^en[_-]US($|[_.-])", name) or re.match(r"^en[_-]LR($|[_.-])", name)
                or re.match(r"^my($|[_.-])", name))


def country_uses_imperial(country):
    c = re.sub(r"[._-]+", " ", str(country or "").strip()).lower()
    if not c:
        return None
    return c in ("us", "usa", "united states", "united states of america", "liberia", "myanmar", "burma")


def should_use_imperial(unit, locale_name, country):
    u = str(unit or "").strip().lower()
    if u == "imperial":
        return True
    if u == "metric":
        return False
    pref = country_uses_imperial(country)
    return pref if pref is not None else locale_uses_imperial(locale_name)


def day_name(date_string):
    try:
        return DAY_NAMES[dt.date.fromisoformat(str(date_string)[:10]).weekday()]
    except ValueError:
        return ""


def open_meteo_days(report, today):
    daily = (report or {}).get("daily") or {}
    out = []
    for i, date in enumerate(daily.get("time") or []):
        if len(out) >= 3:
            break
        if not date or str(date)[:10] <= today:
            continue
        mx = (daily.get("temperature_2m_max") or [None] * (i + 1))[i]
        mn = (daily.get("temperature_2m_min") or [None] * (i + 1))[i]
        out.append({"date": date, "maxC": rounded(mx), "minC": rounded(mn),
                    "maxF": rounded(c_to_f(mx)), "minF": rounded(c_to_f(mn)),
                    "code": (daily.get("weather_code") or [None] * (i + 1))[i]})
    return out


def open_meteo_current(report):
    cur = (report or {}).get("current")
    if not cur or cur.get("temperature_2m") is None:
        return None
    return {"tempC": rounded(cur["temperature_2m"]), "tempF": rounded(c_to_f(cur["temperature_2m"])),
            "feelsC": rounded(cur.get("apparent_temperature")), "feelsF": rounded(c_to_f(cur.get("apparent_temperature"))),
            "windKmh": rounded(cur.get("wind_speed_10m")),
            "windMph": rounded((_num(cur.get("wind_speed_10m")) or 0) * 0.621371),
            "humidity": rounded(cur.get("relative_humidity_2m")),
            "code": cur.get("weather_code"), "isDay": cur.get("is_day")}


def wttr_current(report):
    """wttr.in j1 current_condition in the same shape as open_meteo_current."""
    cc = ((report or {}).get("current_condition") or [None])[0]
    if not cc:
        return None
    return {"tempC": cc.get("temp_C", ""), "tempF": cc.get("temp_F", ""),
            "feelsC": cc.get("FeelsLikeC", ""), "feelsF": cc.get("FeelsLikeF", ""),
            "windKmh": cc.get("windspeedKmph", ""), "windMph": cc.get("windspeedMiles", ""),
            "humidity": cc.get("humidity", ""), "wttrCode": cc.get("weatherCode")}


def current_icon(cur, fallback=""):
    if not cur:
        return fallback
    if cur.get("code") is not None:
        return icon_for_open_meteo(cur["code"], str(cur.get("isDay")) == "0")
    if cur.get("wttrCode") is not None:
        return icon_for_code(cur["wttrCode"], False)
    return fallback


def icon_for_open_meteo(code, night=False):
    try:
        c = int(code or 0)
    except (TypeError, ValueError):
        c = 0
    if c == 0:
        return icon_for_code(113, night)
    if c in (1, 2):
        return icon_for_code(116, night)
    if c == 3:
        return icon_for_code(119, night)
    if c in (45, 48):
        return icon_for_code(143, night)
    if c in (51, 53, 55, 56, 57, 61):
        return icon_for_code(266, night)
    if c in (63, 65, 66, 67, 80, 81, 82):
        return icon_for_code(308, night)
    if c in (71, 73, 75, 77, 85, 86):
        return icon_for_code(338, night)
    if c in (95, 96, 99):
        return icon_for_code(389, night)
    return icon_for_code(119, night)


_CODES = [
    ((113,), "", ""),
    ((116,), "", ""),
    ((119, 122), "", ""),
    # Omarchy's table has these two double-escaped ("\\ue346"), which shows a
    # literal "" in the bar; the intended glyphs are used here.
    ((143, 248, 260), "", ""),
    ((176, 263, 353), "", ""),
    ((179, 227, 230, 323, 326, 368), "", ""),
    ((182, 185, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377), "", ""),
    ((200, 386, 389, 392, 395), "", ""),
    ((266, 293, 296, 299, 302, 305, 308, 356, 359), "", ""),
    ((329, 332, 335, 338, 371), "", ""),
]


def icon_for_code(code, night=False):
    """wttr.in weather code -> Nerd Font glyph (omarchy-weather-icon's map)."""
    try:
        c = int(code or 0)
    except (TypeError, ValueError):
        c = 0
    for codes, night_glyph, day_glyph in _CODES:
        if c in codes:
            return night_glyph if night else day_glyph
    return ""
