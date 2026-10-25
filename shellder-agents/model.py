"""AI agent usage logic — port of Omarchy's agents Main.qml / Panel.qml
helpers (/usr/share/omarchy/shell/plugins/agents/). Pure, tested."""

import datetime as dt
import re

DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


def number(v):
    try:
        n = float(v)
    except (TypeError, ValueError):
        return 0.0
    return n if n == n else 0.0


def has_data(p):
    """providerHasData: anything recorded, a limit window or a balance."""
    return any(number(p.get(k)) > 0 for k in ("totalPrompts", "totalSessions", "activeDays",
                                                 "todayPrompts", "todaySessions")) \
        or bool(p.get("limits")) or bool(balance_of(p))


def balance_of(p):
    raw = p.get("balance")
    if not isinstance(raw, dict):
        return None
    remaining, funded = number(raw.get("remaining")), number(raw.get("funded"))
    if remaining < 0 or raw.get("remaining") is None:
        return None
    return {"remaining": remaining, "funded": funded if funded > 0 else 0.0,
            "spent": max(0.0, number(raw.get("spent"))), "currency": str(raw.get("currency") or "USD"),
            "estimated": raw.get("estimated") is True}


def window_is_long(text):
    return any(w in text for w in ("week", "7-day", "seven", "month", "30-day"))


def window_span_seconds(label):
    text = str(label or "").lower()
    if "month" in text or "30-day" in text:
        return 30 * 86400
    if window_is_long(text):
        return 7 * 86400
    m = re.search(r"(\d+)\s*-?\s*h(?:our)?\b", text)
    if m:
        return int(m.group(1)) * 3600
    m = re.search(r"(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b", text)
    return int(m.group(1)) * 60 if m else 0


def window_title(label):
    text = str(label or "").lower()
    if "month" in text:
        return "Monthly"
    if window_is_long(text):
        return "Weekly"
    if "session" in text or window_span_seconds(label) > 0:
        return "Session"
    plain = re.sub(r"\s*\(.*\)\s*", "", str(label or "")).strip()
    return plain or "Limit"


def parse_time(value):
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def limit_windows(p, now):
    out = []
    for e in p.get("limits") or []:
        e = e or {}
        pct = number(e.get("percent")) if e.get("percent") is not None else -1
        if pct < 0:
            continue
        reset = parse_time(e.get("resetsAt"))
        expired = reset is not None and reset <= now
        out.append({"title": e.get("title") or window_title(e.get("label")),
                    "percent": 0.0 if expired else pct, "reset": None if expired else reset})
    return out


def headline(p, now):
    windows = limit_windows(p, now)
    return max(windows, key=lambda w: w["percent"]) if windows else None


def alarming(p, now):
    h = headline(p, now)
    b = balance_of(p)
    return bool(h and h["percent"] >= 0.9) or bool(b and b["funded"] > 0 and b["remaining"] / b["funded"] <= 0.1)


def format_duration(seconds):
    if not seconds or seconds <= 0:
        return "now"
    minutes = int(seconds // 60)
    hours, days = minutes // 60, minutes // 1440
    if days > 0:
        return "%dd %dh" % (days, hours % 24)
    if hours > 0:
        return "%dh %dm" % (hours, minutes % 60)
    return "%dm" % max(1, minutes)


def format_tokens(n):
    n = number(n)
    if n >= 1e9:
        return "%.1fB" % (n / 1e9)
    if n >= 1e6:
        return "%.1fM" % (n / 1e6)
    if n >= 1e3:
        return "%.1fK" % (n / 1e3)
    return "%d" % n


def currency_prefix(code):
    code = str(code or "USD").upper()
    return {"USD": "$", "EUR": "€", "GBP": "£"}.get(code, code + " ")


def format_money(value, currency):
    return currency_prefix(currency) + "%.2f" % number(value)


def friendly_model_name(model_id):
    if not model_id:
        return "Unknown"
    name = re.sub(r"-\d{8}$", "", re.sub(r"^claude-", "", str(model_id)))
    words, version = [], []
    for part in name.split("-"):
        if not part:
            continue
        if part[0].isdigit():
            version.append(part)
            continue
        if version:
            words.append(".".join(version))
            version = []
        words.append({"gpt": "GPT", "deepseek": "DeepSeek"}.get(part, part[:1].upper() + part[1:]))
    if version:
        words.append(".".join(version))
    return " ".join(words) or "Unknown"


def model_rows(p):
    rows = []
    for mid, b in (p.get("modelUsage") or {}).items():
        b = b or {}
        parts = {k: number(b.get(k)) for k in ("inputTokens", "outputTokens", "cacheReadInputTokens",
                                               "cacheCreationInputTokens")}
        rows.append({"name": friendly_model_name(mid), "total": sum(parts.values()), **parts})
    return sorted(rows, key=lambda r: -r["total"])


def day_name(date):
    try:
        return DAY_NAMES[dt.date.fromisoformat(str(date)[:10]).weekday()]
    except ValueError:
        return str(date)
