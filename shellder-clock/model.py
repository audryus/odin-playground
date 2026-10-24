"""Clock date math and formats — port of Omarchy's Model.js
(/usr/share/omarchy/shell/plugins/panels/clock/Model.js).

Everything here is pure (no GTK) so it can be tested: `python3 -m unittest`.
Formats are the same Qt date strings Omarchy uses ("dddd HH:mm",
"d MMMM 'W'ww yyyy"...), so the settings are interchangeable.
"""

import datetime as dt
import re

# Same indices as JS Date.getDay(): 0 = Sunday ... 6 = Saturday.
WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

# The interface is English, like Omarchy's: fixed names, independent of the
# system locale.
DAY_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
MONTH_LONG = ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]
MONTH_SHORT = [m[:3] for m in MONTH_LONG]

# ---- Label formats. Right click walks this list and saves the result, so
#      what the bar shows and what the settings store are always the same.
CLOCK_FORMATS = [
    "dddd HH:mm",
    "dddd h:mm AP",
    "HH:mm",
    "h:mm AP",
    "ddd d MMM HH:mm",
    "ddd d MMM h:mm AP",
    "d MMMM 'W'ww yyyy",
    "yyyy-MM-dd HH:mm",
]

VERTICAL_CLOCK_FORMATS = [
    "HH\n—\nmm",
    "h\n—\nmm\nAP",
    "dd\nMMM\n'W'ww\n''yy",
    "HH\nmm",
]

DEFAULT_FORMAT = "dddd HH:mm"
DEFAULT_FORMAT_ALT = "d MMMM 'W'ww yyyy"
DEFAULT_VERTICAL_FORMAT = "HH\n—\nmm"
DEFAULT_VERTICAL_FORMAT_ALT = "dd\nMMM\n'W'ww\n''yy"

DEFAULT_LIFE_EXPECTANCY = 90


def clock_formats(vertical):
    return list(VERTICAL_CLOCK_FORMATS if vertical else CLOCK_FORMATS)


def clock_format_ring(configured, configured_alt, presets):
    """Presets in a fixed order plus the alternate and current formats when
    they differ. The order must not depend on the current one: cycling saves
    the result, and a list that reshuffled itself would bounce between two."""
    ring = []
    for fmt in list(presets or []) + [configured_alt, configured]:
        fmt = "" if fmt is None else str(fmt)
        if fmt and fmt not in ring:
            ring.append(fmt)
    return ring or ["HH:mm"]


def next_clock_format(ring, current):
    """Next after `current`; an unknown format starts at the top."""
    if not ring:
        return ""
    current = "" if current is None else str(current)
    index = ring.index(current) if current in ring else -1
    return ring[(index + 1) % len(ring)]


# ---- Qt-style date formatter (Qt.formatDateTime).

_TOKEN = re.compile(r"''|'[^']*'|dddd|ddd|dd|d|MMMM|MMM|MM|M|yyyy|yy|HH|H|hh|h|mm|m|ss|s|AP|ap|A|a")


def format_qt(when, fmt):
    """Format `when` (datetime) with a Qt date format. Supports the tokens
    Omarchy uses, single-quoted literals and '' as a quote, plus 'ww' (ISO
    week, which Qt lacks and Omarchy substitutes beforehand)."""
    fmt = fmt.replace("ww", "'" + pad2(iso_week(when.year, when.month - 1, when.day)) + "'")
    ampm = bool(re.search(r"AP|ap|A|a", re.sub(r"'[^']*'", "", fmt)))
    out = []
    pos = 0
    for m in _TOKEN.finditer(fmt):
        out.append(fmt[pos:m.start()])
        out.append(_token(when, m.group(0), ampm))
        pos = m.end()
    out.append(fmt[pos:])
    return "".join(out)


def _token(when, tok, ampm):
    weekday = (when.weekday() + 1) % 7  # Python: Monday = 0
    hour12 = when.hour % 12 or 12
    if tok == "''":
        return "'"
    if tok.startswith("'"):
        return tok[1:-1]
    return {
        "dddd": DAY_LONG[weekday],
        "ddd": DAY_SHORT[weekday],
        "dd": pad2(when.day),
        "d": str(when.day),
        "MMMM": MONTH_LONG[when.month - 1],
        "MMM": MONTH_SHORT[when.month - 1],
        "MM": pad2(when.month),
        "M": str(when.month),
        "yyyy": str(when.year),
        "yy": pad2(when.year % 100),
        "HH": pad2(when.hour),
        "H": str(when.hour),
        # In Qt, h/hh are 12-hour when the format has AM/PM.
        "hh": pad2(hour12 if ampm else when.hour),
        "h": str(hour12 if ampm else when.hour),
        "mm": pad2(when.minute),
        "m": str(when.minute),
        "ss": pad2(when.second),
        "s": str(when.second),
        "AP": "AM" if when.hour < 12 else "PM",
        "A": "AM" if when.hour < 12 else "PM",
        "ap": "am" if when.hour < 12 else "pm",
        "a": "am" if when.hour < 12 else "pm",
    }[tok]


# ---- Dates. Months are 0-based (0 = January), as in Model.js.

def pad2(value):
    n = int(value)
    return ("0" if n < 10 else "") + str(n)


def date_key(year, month, day):
    return "%d-%s-%s" % (year, pad2(month + 1), pad2(day))


def key_for_date(d):
    return date_key(d.year, d.month - 1, d.day)


def coerce_week_start(value):
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return (round(value) % 7 + 7) % 7
    text = str(value).strip().lower()
    if not text:
        return None
    for i, name in enumerate(WEEKDAY_NAMES):
        if name == text or name[:3] == text:
            return i
    try:
        return (int(text) % 7 + 7) % 7
    except ValueError:
        return None


def normalized_week_start(value, fallback):
    configured = coerce_week_start(value)
    if configured is not None:
        return configured
    fb = coerce_week_start(fallback)
    return 1 if fb is None else fb


def week_start_setting_name(index):
    return WEEKDAY_NAMES[normalized_week_start(index, 1)]


def toggled_week_start(index):
    """Flip between the two common conventions: Monday <-> Sunday. Any other
    start goes to Monday on the first toggle."""
    return 0 if normalized_week_start(index, 1) == 1 else 1


def weekday_order(week_start):
    start = normalized_week_start(week_start, 1)
    return [(start + i) % 7 for i in range(7)]


def iso_week(year, month, day):
    return dt.date(year, month + 1, day).isocalendar()[1]


def day_of_year(year, month, day):
    return dt.date(year, month + 1, day).timetuple().tm_yday


def days_in_year(year):
    return day_of_year(year, 11, 31)


def year_progress(year, month, day):
    """Whole days done / days in the year: January 1 = 0%."""
    total = days_in_year(year)
    return max(0.0, min(1.0, (day_of_year(year, month, day) - 1) / total))


def year_progress_percent(year, month, day):
    return round(year_progress(year, month, day) * 100)


def _int_text(value):
    return "" if value is None else str(value).strip()


def parse_birth_year(value, current_year):
    """Four-digit year, not in the future, at most 120 years ago; 0 = unset."""
    text = _int_text(value)
    if not re.fullmatch(r"\d{4}", text):
        return 0
    year = int(text)
    if year > current_year or year < current_year - 120:
        return 0
    return year


def age_from_birth_year(birth_year, current_year):
    born = parse_birth_year(birth_year, current_year)
    return 0 if born <= 0 else current_year - born


def parse_age(value):
    text = _int_text(value)
    if not re.fullmatch(r"\d+", text):
        return 0
    years = int(text)
    return years if 0 < years <= 120 else 0


def parse_life_expectancy(value):
    text = _int_text(value)
    if not re.fullmatch(r"\d+", text):
        return DEFAULT_LIFE_EXPECTANCY
    years = int(text)
    return years if 0 < years <= 150 else DEFAULT_LIFE_EXPECTANCY


def life_progress(age, expectancy):
    years = parse_age(age)
    span = parse_life_expectancy(expectancy)
    if years <= 0 or span <= 0:
        return 0.0
    return max(0.0, min(1.0, years / span))


def life_progress_percent(age, expectancy):
    return round(life_progress(age, expectancy) * 100)


def month_grid(year, month, week_start, today_key):
    """Always 6 rows of 7 days, so the popup has the same height every month.
    Each row carries the ISO week number of its Thursday."""
    start = normalized_week_start(week_start, 1)
    first = dt.date(year, month + 1, 1)
    first_weekday = (first.weekday() + 1) % 7
    leading = (first_weekday - start + 7) % 7
    cursor = first - dt.timedelta(days=leading)
    weeks = []
    for _ in range(6):
        days = []
        thursday = None
        for _ in range(7):
            weekday = (cursor.weekday() + 1) % 7
            key = key_for_date(cursor)
            if weekday == 4:
                thursday = cursor
            days.append({
                "key": key,
                "year": cursor.year,
                "month": cursor.month - 1,
                "day": cursor.day,
                "weekday": weekday,
                "inMonth": cursor.month - 1 == month and cursor.year == year,
                "weekend": weekday in (0, 6),
                "today": key == today_key,
            })
            cursor += dt.timedelta(days=1)
        anchor = thursday or dt.date(days[0]["year"], days[0]["month"] + 1, days[0]["day"])
        weeks.append({"week": anchor.isocalendar()[1], "days": days})
    return weeks


def step_month(year, month, delta):
    total = year * 12 + month + delta
    return {"year": total // 12, "month": total % 12}
