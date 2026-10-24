"""Display panel logic — port of Omarchy's monitor Model.js
(/usr/share/omarchy/shell/plugins/panels/monitor/Model.js). Pure, tested."""

import json
import math

SCALE_PRESETS = ["1", "1.25", "1.6", "2", "3", "4"]
TEXT_SIZE_STOPS = [9, 10, 11, 12, 14, 16, 20]


def clamp_brightness(value):
    try:
        n = float(value)
    except (TypeError, ValueError):
        return 1
    if not math.isfinite(n):
        return 1
    return max(1, min(100, round(n)))


def normalize_scale(scale):
    try:
        n = float(str(scale or ""))
    except ValueError:
        return ""
    if not math.isfinite(n):
        return ""
    v = round(n * 100) / 100
    return str(int(v)) if v == int(v) else repr(v)


def clean_scale(scale, width, height):
    """The scale Hyprland actually applies: the closest value at or above the
    request whose 1/120 units divide both mode dimensions."""
    try:
        requested, w, h = float(scale), float(width), float(height)
    except (TypeError, ValueError):
        return ""
    if requested <= 0 or w <= 0 or h <= 0:
        return ""
    divisor = math.gcd(round(w * 120), round(h * 120))
    units = round(requested * 120)
    if units > divisor:
        units = divisor
    while divisor % units != 0:
        units += 1
    return normalize_scale(units / 120)


def matching_scale_index(scales, current, width, height):
    try:
        cur = float(current)
    except (TypeError, ValueError):
        return -1
    best, best_dist = -1, float("inf")
    norm = normalize_scale(cur)
    for i, s in enumerate(scales or []):
        if clean_scale(s, width, height) != norm:
            continue
        dist = abs(float(s) - cur)
        if dist < best_dist:
            best, best_dist = i, dist
    return best


def available_scales(scales, width, height):
    """Presets that land on distinct effective scales for this mode."""
    try:
        if float(width) <= 0 or float(height) <= 0:
            return list(scales or [])
    except (TypeError, ValueError):
        return list(scales or [])
    by_effective = {}
    for i, s in enumerate(scales or []):
        eff = clean_scale(s, width, height)
        if not eff:
            continue
        dist = abs(float(s) - float(eff))
        cur = by_effective.get(eff)
        if cur is None or dist < cur[2]:
            by_effective[eff] = (str(s), i, dist)
    return [v for v, _, _ in sorted(by_effective.values(), key=lambda c: c[1])]


def brightness_name(percent):
    p = round(percent)
    for limit, name in ((95, "Sun blast"), (80, "Solar flare"), (65, "Golden hour"),
                        (45, "Even day"), (30, "Soft glow"), (20, "Lamp light"), (10, "Candlelit")):
        if p >= limit:
            return name
    return "Night owl"


def parse_displays(raw):
    try:
        displays = json.loads(raw) if raw else []
    except ValueError:
        displays = []
    if not isinstance(displays, list):
        displays = []
    return displays, sum(1 for d in displays if d and d.get("enabled"))


def parse_state(raw):
    """omarchy-monitor-state: brightness, internal, external, internal
    enabled, mirror, focused, scale, displays JSON — one per line."""
    lines = (str(raw or "").split("\n") + [""] * 8)[:8]
    brightness = lines[0].strip()
    available = brightness not in ("", "unavailable")
    displays, enabled = parse_displays(lines[7].strip() or "[]")
    try:
        percent = max(0, min(100, int(brightness))) if available else 0
    except ValueError:
        available, percent = False, 0
    return {
        "brightnessAvailable": available,
        "brightness": percent,
        "focused": lines[5].strip(),
        "scale": normalize_scale(lines[6].strip()),
        "displays": displays,
        "enabledCount": enabled,
    }


def nearest_text_stop(px):
    return min(range(len(TEXT_SIZE_STOPS)), key=lambda i: abs(TEXT_SIZE_STOPS[i] - px))
