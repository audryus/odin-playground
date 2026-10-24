"""Audio panel logic — port of Omarchy's audio Model.js
(/usr/share/omarchy/shell/plugins/panels/audio/Model.js), adapted to the
`pactl -f json` node shape ({"name", "description", "properties", ...}).
Pure, tested."""

import re


def output_volume_name(volume, muted):
    if muted:
        return "Muted"
    p = round(volume * 100)
    if p == 0:
        return "Silenced"
    for limit, name in ((100, "Concert hall"), (85, "Party mode"), (70, "Cranked up"),
                        (50, "Steady groove"), (30, "Easy listening"), (15, "Murmur")):
        if p >= limit:
            return name
    return "Whisper"


def output_icon(volume, muted, headphones, present=True):
    """The old Waybar pulseaudio glyph set Omarchy keeps (escaped: these
    BMP private-use glyphs are invisible in most editors)."""
    if not present:
        return "\ueee8"
    if headphones:
        return "\U000f02cb"
    if muted:
        return "\ueee8"
    if volume >= 0.67:
        return "\uf028"
    if volume >= 0.34:
        return "\uf027"
    if volume > 0:
        return "\uf026"
    return "\ueee8"


def input_icon(muted, present=True):
    return "󰍭" if (not present or muted) else "󰍬"


def parse_sink_availability(raw):
    out = {}
    for line in str(raw or "").split("\n"):
        parts = line.strip().split("\t")
        if len(parts) >= 2:
            out[parts[0]] = parts[1] != "0"
    return out


def friendly_device_label(text):
    label = str(text or "").strip()
    label = re.sub(r"^sof-soundwire\s+", "", label, flags=re.I)
    label = re.sub(r"^built-?in audio\s+", "", label, flags=re.I)
    label = re.sub(r"\s+Output$", "", label, flags=re.I)
    label = re.sub(r"\s+Input$", "", label, flags=re.I)
    return re.sub(r"\bMicrophones\b", "Microphone", label)


def props(node):
    return (node or {}).get("properties") or {}


def node_label(node):
    if not node:
        return "Unknown"
    p = props(node)
    nick = friendly_device_label(p.get("node.nick") or p.get("device.profile.description") or "")
    if nick:
        return nick
    return friendly_device_label(node.get("description") or p.get("node.description") or node.get("name") or "Unknown")


def _blob(node, keys):
    p = props(node)
    return " ".join([str(node.get("name", "")), str(node.get("description", ""))] +
                    [str(p.get(k, "")) for k in keys]).lower()


def is_headphones(node):
    if not node:
        return False
    b = _blob(node, ("node.nick", "device.icon_name", "device.product.name", "node.description"))
    return any(w in b for w in ("headphone", "headset", "earbud", "earphone", "airpod"))


def sink_glyph(node):
    if not node:
        return "󰓃"
    if is_headphones(node):
        return "󰋋"
    b = _blob(node, ("node.nick", "device.icon_name", "device.product.name"))
    if "bluetooth" in b:
        return "󰂯"
    if "hdmi" in b or "display" in b:
        return "󰍹"
    return "󰓃"


def source_glyph(node):
    if not node:
        return "󰍬"
    b = _blob(node, ("node.nick", "device.icon_name"))
    if "headset" in b:
        return "󰋋"
    if "bluetooth" in b:
        return "󰂯"
    if "webcam" in b or "camera" in b:
        return "󰄀"
    return "󰍬"


def friendly_stream_label(label):
    label = str(label or "").strip()
    return {"spotify": "Spotify"}.get(label.lower(), label)


def stream_label(node):
    p = props(node)
    return friendly_stream_label(p.get("application.name") or p.get("media.name")
                                 or p.get("node.name") or "") or "Stream"


def volume_of(node):
    """Average channel volume as 0..1 (pactl gives per-channel "NN%")."""
    vols = ((node or {}).get("volume") or {}).values()
    vals = []
    for v in vols:
        try:
            vals.append(int(str(v.get("value_percent", "0")).rstrip("%")) / 100)
        except ValueError:
            pass
    return sum(vals) / len(vals) if vals else 0.0
