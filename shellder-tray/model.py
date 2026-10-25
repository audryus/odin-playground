"""System tray logic — port of Omarchy's Tray.qml / TrayModel.js
(/usr/share/omarchy/shell/plugins/bar/widgets/). Pure, tested."""

import re

ANIMATION_MS = 600  # Waybar's group/tray-expander transition-duration


def _text(value):
    return str(value or "").lower()


def item_named(item, name):
    return bool(item) and any(name in _text(item.get(k)) for k in ("id", "title", "tooltipTitle"))


def owned_by_omarchy(item):
    """LocalSend's item has no state and a no-op primary click (Omarchy hides
    it; it also picks a fresh id every launch, so hiding by hand won't stick)."""
    return item_named(item, "localsend")


def classify(item_id, pinned, hidden):
    if item_id in hidden:
        return "hidden"
    if item_id in pinned:
        return "pinned"
    return "drawer"


def buckets(items, pinned, hidden):
    """(pinned, drawer, all) in item order; Passive items never show."""
    out = {"pinned": [], "drawer": [], "all": []}
    for it in items:
        if it.get("status") == "Passive" or owned_by_omarchy(it):
            continue
        out["all"].append(it)
        cat = classify(it.get("id", ""), pinned, hidden)
        if cat != "hidden":
            out[cat].append(it)
    return out["pinned"], out["drawer"], out["all"]


def toggle_pin(item_id, pinned, hidden):
    p, h = list(pinned), list(hidden)
    if item_id in p:
        p.remove(item_id)
    else:
        p.append(item_id)
        if item_id in h:
            h.remove(item_id)
    return p, h


def toggle_hide(item_id, pinned, hidden):
    p, h = list(pinned), list(hidden)
    if item_id in h:
        h.remove(item_id)
    else:
        h.append(item_id)
        if item_id in p:
            p.remove(item_id)
    return p, h


def tooltip(item):
    return item.get("tooltipTitle") or item.get("title") or item.get("id") or ""


def display_name(item):
    for k in ("title", "tooltipTitle"):
        t = str(item.get(k) or "").strip()
        if t:
            return t
    iid = str(item.get("id") or "")
    return iid.rsplit("/", 1)[-1] if iid else "Unknown"


def is_symbolic(icon_name):
    return str(icon_name or "").split("?")[0].endswith("-symbolic")


def ease_out_cubic(t):
    t = max(0.0, min(1.0, t)) - 1
    return t * t * t + 1


def drawer_layout(drawer_count, extent, progress):
    """Omarchy reserves the whole drawer and slides the chevron left over it.
    Returns (lead, visible, trail): the passive space before the chevron, how
    many drawer items fit after it and the passive space after them. The sum
    is constant, so the bar never moves."""
    total = drawer_count * extent
    reveal = total * max(0.0, min(1.0, progress))
    visible = int((reveal + 0.5) // extent) if extent else 0
    visible = min(visible, drawer_count)
    return total - reveal, visible, max(0.0, reveal - visible * extent)


def parse_service(service, sender=""):
    """StatusNotifierWatcher registration -> (bus name, object path)."""
    s = str(service or "")
    if s.startswith("/"):
        return sender, s
    if "/" in s:
        name, path = s.split("/", 1)
        return name, "/" + path
    return s, "/StatusNotifierItem"


def best_pixmap(pixmaps, size):
    """Pick from SNI IconPixmap [(w, h, argb bytes)] the smallest one at
    least `size` wide, else the largest."""
    good = [p for p in pixmaps or [] if p[0] > 0 and p[1] > 0 and len(p[2]) >= p[0] * p[1] * 4]
    if not good:
        return None
    big = [p for p in good if p[0] >= size]
    return min(big, key=lambda p: p[0]) if big else max(good, key=lambda p: p[0])


def argb_to_rgba(data):
    """SNI pixmaps are ARGB32 in network byte order."""
    b = bytes(data)
    out = bytearray(len(b))
    out[0::4], out[1::4], out[2::4], out[3::4] = b[1::4], b[2::4], b[3::4], b[0::4]
    return bytes(out)


def tint_rgba(data, rgb):
    """Recolor every pixel to `rgb` (0..255), keeping its alpha: symbolic icons
    are meant to take the host's foreground."""
    b = bytearray(data)
    n = len(b) // 4
    b[0::4], b[1::4], b[2::4] = bytes([rgb[0]]) * n, bytes([rgb[1]]) * n, bytes([rgb[2]]) * n
    return bytes(b)


def menu_label(label):
    """dbusmenu labels mark the mnemonic with '_' ('__' is a literal '_')."""
    return str(label or "").replace("__", "\x00").replace("_", "").replace("\x00", "_")


def menu_entries(layout, at_root, item_title):
    """com.canonical.dbusmenu layout children -> rows to draw. At the root,
    Omarchy hides a first entry that only repeats the item title (with a
    submenu) and separators at the top."""
    rows = []
    for index, (mid, props, children) in enumerate(layout or []):
        if props.get("visible", True) is False:
            continue
        sep = props.get("type") == "separator"
        text = menu_label(props.get("label", ""))
        has_children = bool(children) or props.get("children-display") == "submenu"
        if at_root and index == 0 and has_children and text.lower() == str(item_title or "").lower():
            continue
        if at_root and sep and index <= 1:
            continue
        rows.append({"id": mid, "text": text, "separator": sep,
                     "enabled": props.get("enabled", True) is not False,
                     "toggle": props.get("toggle-type", "") or "",
                     "checked": props.get("toggle-state", 0) == 1,
                     "icon": props.get("icon-name", "") or "",
                     "iconData": bytes(props.get("icon-data") or b""),
                     "children": children, "hasChildren": has_children})
    return rows
