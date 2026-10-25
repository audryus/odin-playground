"""Keyboard layout label logic — port of Omarchy's KeyboardLayoutModel.js
(/usr/share/omarchy/shell/plugins/bar/widgets/). Pure, tested."""

import re

# Hyprland lists more than keyboards: fcitx5's virtual one and ACPI buttons
# carry the seat's layout list but nobody types on them.
UNTYPED_KEYBOARDS = re.compile(r"^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)")


def layout_briefs(text):
    """`xkbcli list` YAML -> {description: brief}. A brief never carries past
    the block it was printed in."""
    briefs, brief = {}, ""
    for line in str(text or "").split("\n"):
        if re.match(r"^\s*- ", line):
            brief = ""
        m = re.match(r"^  (brief|description): (.*)$", line)
        if not m:
            continue
        if m.group(1) == "brief":
            brief = re.sub(r"^'|'$", "", m.group(2))
        elif brief:
            briefs[m.group(2)] = brief
            brief = ""
    return briefs


def short_label(description, briefs):
    """The language code ("en", script suffix dropped), else the first word of
    the description; at most three characters, upper case."""
    if not description:
        return ""
    brief = (briefs or {}).get(description)
    label = brief.split("-")[0] if isinstance(brief, str) and brief else description.split()[0]
    return label[:3].upper()


def event_keyboard_name(data):
    """activelayout>>KEYBOARD,LAYOUT -> KEYBOARD ("" for fcitx5's virtual one)."""
    name = str(data or "").split(",", 1)[0]
    return "" if name.startswith("hl-virtual-keyboard") else name


def is_typed_keyboard(name):
    return not UNTYPED_KEYBOARDS.match(str(name or ""))


def select_keyboard(typed, named_by_event):
    """The keyboard the last switch named, else the furthest-advanced one."""
    for k in typed or []:
        if k.get("name") == named_by_event:
            return k
    best = None
    for k in typed or []:
        if best is None or (k.get("active_layout_index") or 0) > (best.get("active_layout_index") or 0):
            best = k
    return best


def multiple_layouts(keyboard):
    """An older Hyprland without "layout" keeps the label shown."""
    layout = keyboard.get("layout")
    return layout is None or "," in str(layout)
