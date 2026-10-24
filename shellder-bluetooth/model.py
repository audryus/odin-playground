"""Bluetooth panel logic — port of Omarchy's bluetooth Model.js
(/usr/share/omarchy/shell/plugins/panels/bluetooth/Model.js), over BlueZ
Device1 property dicts. Pure, tested."""

import re

PHRASES = ["Untangling wires", "Streaming vikings", "Pairing mysteries", "Herding headsets",
           "Taming radios", "Summoning speakers", "Wrangling codecs", "Polishing packets"]


def device_label(d):
    return str((d or {}).get("Alias") or (d or {}).get("Name") or "").strip()


def is_uuid_like(value):
    t = str(value or "").strip()
    if not t:
        return False
    return bool(re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", t, re.I)
                or re.fullmatch(r"[0-9a-f]{32}", t, re.I) or re.fullmatch(r"0x[0-9a-f]{4,32}", t, re.I))


def is_address_like(value):
    return bool(re.fullmatch(r"([0-9a-f]{2}[:-]){5}[0-9a-f]{2}", str(value or "").strip(), re.I))


def has_human_name(d):
    label = device_label(d)
    return label != "" and not is_uuid_like(label) and not is_address_like(label)


def device_lists(devices):
    """Split into connected / known (paired, bonded or trusted) / discovered,
    each sorted by label; nameless devices are skipped, as in Omarchy."""
    connected, known, discovered = [], [], []
    for d in devices or []:
        if not d or not has_human_name(d):
            continue
        if d.get("Connected"):
            connected.append(d)
        elif d.get("Paired") or d.get("Bonded") or d.get("Trusted"):
            known.append(d)
        else:
            discovered.append(d)
    key = lambda d: device_label(d).lower()  # noqa: E731
    return {"connected": sorted(connected, key=key), "known": sorted(known, key=key),
            "discovered": sorted(discovered, key=key)}


def bar_icon(adapter, connected_count):
    if adapter is None:
        return ""
    if not adapter.get("Powered"):
        return "󰂲"
    return "󰂱" if connected_count > 0 else "󰂯"


def status_text(d, section, pending):
    """DeviceRow.statusText."""
    if pending == "forgetting":
        return "Forgetting…"
    if pending == "disconnecting":
        return "Disconnecting…"
    if d.get("Connected"):
        if d.get("Battery") is not None:
            return "%d%%" % d["Battery"]
        return "" if section == "connected" else "Connected"
    if pending == "connecting":
        return "Connecting…"
    return ""


def action_tooltip(d, section):
    if d.get("Connected"):
        return "Disconnect"
    return "Pair" if section == "discovered" else "Connect"
