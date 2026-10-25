"""Network panel logic — port of Omarchy's network Model.js
(/usr/share/omarchy/shell/plugins/panels/network/Model.js). Pure, tested."""

import math

PHRASES = ["Wiring bits", "Handling packets", "Sorting frames", "Hauling bytes",
           "Routing crumbs", "Counting collisions", "Bending light"]
DNS_PROVIDERS = [("DHCP", "Use DNS from DHCP"), ("Cloudflare", "Set DNS to Cloudflare"),
                 ("Google", "Set DNS to Google"), ("Custom", "Set custom DNS servers")]
PING_WINDOW, PING_AVERAGE = 24, 5


def parse_network_status(raw):
    parts = (str(raw or "disconnected\t\t\t").rstrip("\r\n").split("\t") + ["", "", "", ""])[:4]
    try:
        signal = int(parts[2]) if parts[2] else -1
    except ValueError:
        signal = -1
    return {"kind": parts[0] or "disconnected", "label": parts[1], "signal": signal, "frequency": parts[3]}


def wifi_icon_for(strength):
    icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
    return icons[max(0, min(4, math.ceil(strength / 20) - 1))]


def connection_icon(kind, signal):
    if kind == "wifi":
        return wifi_icon_for(signal)
    if kind == "ethernet":
        return "󰈀"
    return "󰤮"


def format_header_speed(mbps):
    try:
        v = int(mbps)
    except (TypeError, ValueError):
        return ""
    if v <= 0:
        return ""
    if v >= 1000:
        return ("%d" % (v // 1000) if v % 1000 == 0 else "%.1f" % (v / 1000)) + "gbit"
    return "%dmbit" % v


def header_detail(info):
    return format_header_speed(info.get("speed", "")) if info.get("type") == "ethernet" else ""


def band_label(band):
    if band == "auto":
        return "Auto"
    return band + "ghz" if band else ""


def band_section_title(selected, current):
    if selected != "auto":
        return "WI-FI BAND"
    label = band_label(current)
    return "WI-FI BAND: " + label.upper() if label else "WI-FI BAND"


def parse_key_value(raw):
    out = {}
    for line in str(raw or "").split("\n"):
        idx = line.find("\t")
        if idx > 0:
            out[line[:idx]] = line[idx + 1:].strip()
    return out


def parse_band_status(raw):
    kv = parse_key_value(raw)
    return {"band": kv.get("band", ""), "selected": kv.get("selected") or "auto",
            "available": [t for t in kv.get("available", "").split(" ") if t]}


def throughput_state(prev, sample, now):
    iface = sample.get("iface", "")
    rx, tx = float(sample.get("rx_bytes") or 0), float(sample.get("tx_bytes") or 0)
    if iface != prev.get("iface", "") or not prev.get("time"):
        return {"iface": iface, "rx": rx, "tx": tx, "time": now, "down": 0.0, "up": 0.0}
    down, up = prev.get("down", 0.0), prev.get("up", 0.0)
    dt = now - prev["time"]
    if dt > 0:
        down = max(0.0, (rx - prev["rx"]) / dt)
        up = max(0.0, (tx - prev["tx"]) / dt)
    return {"iface": iface, "rx": rx, "tx": tx, "time": now, "down": down, "up": up}


def ping_sample(raw):
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) and v >= 0 else None


def average_ping(samples, limit=PING_AVERAGE):
    vals = [v for v in samples[-limit:] if v is not None]
    return sum(vals) / len(vals) if vals else -1


def packet_loss(samples):
    if not samples:
        return 0
    return round(sum(1 for v in samples if v is None) / len(samples) * 100)


def ping_state(prev, sample):
    """Rolling router/internet ping windows (pingLatencyState)."""
    iface = sample.get("iface", "")
    reset = iface == "" or iface != prev.get("iface", "")
    out = {"iface": iface}
    for key in ("router", "internet"):
        samples = [] if reset else list(prev.get(key, []))
        if sample.get(key + "_ping_ms") is None:
            samples = []
        else:
            samples.append(ping_sample(sample[key + "_ping_ms"]))
            samples = samples[-PING_WINDOW:]
        out[key] = samples
    return out


def format_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        n = 0.0
    if not math.isfinite(n) or n < 0:
        n = 0.0
    if n < 1024:
        return "%d B" % round(n)
    if n < 1024 ** 2:
        return "%.1f KB" % (n / 1024)
    if n < 1024 ** 3:
        return "%.1f MB" % (n / 1024 ** 2)
    return "%.2f GB" % (n / 1024 ** 3)


def format_rate(bps):
    return format_bytes(bps) + "/s"


def format_ping(ms, has_samples=True):
    if not has_samples:
        return "--"
    if ms is None or ms < 0:
        return "Timeout"
    return ("%.1f ms" if 0 < ms < 10 else "%.0f ms") % ms


def format_packet_loss(percent, has_samples=True):
    if not has_samples:
        return "--"
    return "%d%%" % percent if percent and percent > 0 else "0%"


def sort_wifi(rows):
    return sorted(rows, key=lambda r: (not r["connected"], not r["known"], -r["signal"]))


def wifi_section_title(rows, index):
    if index < 0 or index >= len(rows):
        return ""
    net = rows[index]
    if net["known"] and index == 0:
        return "KNOWN NETWORKS"
    if not net["known"] and (index == 0 or rows[index - 1]["known"]):
        return "OTHER NETWORKS"
    return ""


def requires_credentials(security):
    s = (security or "").strip()
    return s not in ("", "--", "OWE")


def nmcli_split(line):
    """Split one `nmcli -t` line on unescaped ':'."""
    out, cur, esc = [], [], False
    for ch in line:
        if esc:
            cur.append(ch)
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out
