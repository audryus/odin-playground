"""Battery and power-profile logic — port of Omarchy's power Model.js
(/usr/share/omarchy/shell/plugins/panels/power/Model.js). Pure, tested."""

# UPower device states (org.freedesktop.UPower.Device.State).
CHARGING, DISCHARGING, EMPTY, FULLY_CHARGED, PENDING_CHARGE, PENDING_DISCHARGE = 1, 2, 3, 4, 5, 6

CHARGING_ICONS = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
DEFAULT_ICONS = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

CHARGING_PHRASES = ["Pumping power", "Injecting electrons", "Pouring juice", "Amassing watts",
                    "Hoarding joules", "Sucking volts", "Topping reserves", "Soaking amps",
                    "Inhaling kilowatts"]
ON_BATTERY_PHRASES = ["Slurping power", "Spending joules", "Draining watts", "Burning electrons",
                      "Sipping juice", "Spending coulombs", "Bleeding amps", "Guzzling volts",
                      "Munching reserves"]


def clamp_index(index, length):
    if length <= 0:
        return 0
    return max(0, min(length - 1, index))


def select_profile_index(index, delta, profiles):
    return clamp_index(index + delta, len(profiles or []))


def parse_key_value(raw):
    out = {}
    for line in str(raw or "").split("\n"):
        idx = line.find("\t")
        if idx > 0:
            out[line[:idx]] = line[idx + 1:].strip()
    return out


def parse_profiles(raw, previous_index=0):
    profiles, active = [], ""
    for line in str(raw or "").split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        profiles.append(parts[0])
        if len(parts) > 1 and parts[1] == "1":
            active = parts[0]
    return {"profiles": profiles, "activeProfile": active,
            "profileIndex": clamp_index(previous_index or 0, len(profiles))}


def profile_icon(name):
    return {"power-saver": "󰌪", "balanced": "󰊚", "performance": "󰓅"}.get(name, "󰂄")


def battery_fraction(device):
    """device: {"present", "percentage" (0..1), "state", "rate", "time_to_full"}."""
    if not device or not device.get("present"):
        return 0.0
    return max(0.0, min(1.0, device.get("percentage", 0.0)))


def charge_threshold_active(device, on_battery):
    d = device or {}
    if not (d.get("present") and not on_battery):
        return False
    fraction = battery_fraction(d)
    state = d.get("state")
    if state == DISCHARGING:
        return False
    if state == PENDING_CHARGE:
        return True
    if state == FULLY_CHARGED and fraction < 0.99:
        return True
    if state != CHARGING or fraction >= 0.99:
        return False
    return float(d.get("rate") or 0) <= 0.2 or float(d.get("time_to_full") or 0) >= 8 * 60 * 60


def battery_icon(device, on_battery):
    d = device or {}
    if not d.get("present"):
        return ""
    index = max(0, min(9, int(d.get("percentage", 0) * 10)))
    if charge_threshold_active(d, on_battery):
        return DEFAULT_ICONS[index]
    if d.get("state") == FULLY_CHARGED:
        return "󰂅"
    if not on_battery:
        return CHARGING_ICONS[index]
    return DEFAULT_ICONS[index]


def mode_label(device, on_battery):
    d = device or {}
    if not d.get("present"):
        return ""
    if charge_threshold_active(d, on_battery):
        return "Threshold"
    if on_battery:
        return "On battery"
    if d.get("percentage", 0) >= 1:
        return "Fully charged"
    return "Charging"
