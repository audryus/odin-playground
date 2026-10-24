"""The Omarchy theme (Shellder's "config" event) as values and GTK CSS.

The CSS classes mirror the Omarchy shell components
(/usr/share/omarchy/shell/Ui): PanelHero, PanelSectionHeader,
PanelSeparator, PanelActionButton, PanelSlider, ToggleSwitch and the panels'
list rows.
"""


def parse_hex(value, fallback=(0.8, 0.8, 0.8, 1.0)):
    v = str(value or "").lstrip("#")
    try:
        if len(v) in (6, 8):
            r, g, b = (int(v[i:i + 2], 16) / 255 for i in (0, 2, 4))
            a = int(v[6:8], 16) / 255 if len(v) == 8 else 1.0
            return (r, g, b, a)
    except ValueError:
        pass
    return fallback


def darker(c, factor):
    """Qt.darker: divide the brightness by the factor."""
    return (c[0] / factor, c[1] / factor, c[2] / factor, c[3])


def with_alpha(c, a):
    return (c[0], c[1], c[2], a)


def css(c):
    return "rgba(%d,%d,%d,%.3f)" % (round(c[0] * 255), round(c[1] * 255), round(c[2] * 255), c[3])


class Theme:
    def __init__(self, data):
        data = data or {}
        colors = data.get("colors", {})
        popup = data.get("popup", {})
        controls = data.get("controls", {})
        bar = data.get("bar", {})
        font = data.get("font", {})
        self.raw = data
        self.family = font.get("family") or "monospace"
        self.sizes = font.get("sizes", {})
        self.radius = int(data.get("radius", 0))

        self.foreground = parse_hex(colors.get("foreground"))
        self.background = parse_hex(colors.get("background"), (0.06, 0.07, 0.08, 1))
        self.accent = parse_hex(colors.get("accent"))
        self.urgent = parse_hex(colors.get("urgent"), (0.65, 0.33, 0.33, 1))
        self.muted = parse_hex(colors.get("muted"), darker(self.foreground, 1.6))

        self.fg = parse_hex(popup.get("text"), self.foreground)
        self.bg = parse_hex(popup.get("background"), self.background)
        self.border = parse_hex(popup.get("border"), self.accent)
        self.border_width = int(popup.get("borderWidth", 1))

        self.bar_text = parse_hex(bar.get("text"), self.foreground)
        self.bar_active = parse_hex(bar.get("active"), self.urgent)
        self.bar_tokens = {k: bar.get(k) for k in
                           ("sizeHorizontal", "sizeVertical", "iconSlot", "iconCanvas", "iconFont", "statusSlot")}

        fa = lambda k, a: parse_hex(controls.get(k), with_alpha(self.fg, a))
        self.normal_fill = fa("normal", 0.04)
        self.normal_border = fa("normalBorder", 0.4)
        self.hover_fill = fa("hover", 0.08)
        self.hover_border = fa("hoverBorder", 0.25)
        self.hover_color = parse_hex(controls.get("hoverColor"), self.fg)
        self.selected_fill = fa("selected", 0.18)
        self.selected_border = fa("selectedBorder", 1.0)
        self.selected_color = parse_hex(controls.get("selectedColor"), self.fg)
        self.pressed_fill = fa("pressed", 0.22)
        self.normal_border_width = int(controls.get("normalBorderWidth", 1))
        self.hover_border_width = int(controls.get("hoverBorderWidth", 1))
        self.selected_border_width = int(controls.get("selectedBorderWidth", 0))

    def size(self, name, default):
        return int(self.sizes.get(name, default))

    def bar_token(self, name, default):
        v = self.bar_tokens.get(name)
        return int(v) if v else default

    def stylesheet(self, extra=""):
        """Base panel CSS; `extra` is appended (same % dictionary)."""
        s = self.size
        fg = self.fg
        vals = {
            "bg": css(self.bg), "fg": css(fg), "accent": css(self.accent),
            "urgent": css(self.urgent), "border": css(self.border), "bw": self.border_width,
            "r": self.radius, "family": self.family.replace('"', ""),
            "hover": css(self.hover_fill), "hover_border": css(self.hover_border),
            "hbw": self.hover_border_width, "hover_color": css(self.hover_color),
            "normal": css(self.normal_fill), "normal_border": css(self.normal_border),
            "nbw": self.normal_border_width,
            "selected": css(self.selected_fill), "selected_border": css(self.selected_border),
            "sbw": self.selected_border_width, "selected_color": css(self.selected_color),
            "pressed": css(self.pressed_fill),
            "hairline": css(with_alpha(fg, 0.12)), "track": css(self.selected_fill),
            "hairline10": css(with_alpha(fg, 0.1)), "dim145": css(darker(fg, 1.45)),
            "dim12": css(darker(fg, 1.25)), "dim14": css(darker(fg, 1.4)),
            "dim15": css(darker(fg, 1.5)), "dim19": css(darker(fg, 1.9)),
            "dim20": css(darker(fg, 2.0)), "dim22": css(darker(fg, 2.2)),
            "caption": s("caption", 10), "body_small": s("bodySmall", 11),
            "body": s("body", 12), "subtitle": s("subtitle", 13), "title": s("title", 14),
            "heading": s("heading", 16), "display": s("display", 24),
            "display_large": s("displayLarge", 28), "icon": s("icon", 14),
            "icon_large": s("iconLarge", 18), "pad": 14,
        }
        base = """
window.sk-layer { background: transparent; }
.sk-panel {
  background: %(bg)s; color: %(fg)s; font-family: "%(family)s"; font-size: %(body)dpx;
  border: %(bw)dpx solid %(border)s; border-radius: %(r)dpx; padding: %(pad)dpx;
}
.sk-panel label { font-family: "%(family)s"; }
.sk-dim { color: %(dim14)s; }
.sk-dimmer { color: %(dim19)s; }
.sk-urgent { color: %(urgent)s; }
.sk-accent { color: %(accent)s; }
.sk-hero-icon { font-size: %(display)dpx; }
.sk-hero-title { font-size: %(title)dpx; font-weight: bold; }
.sk-hero-meta { font-size: %(caption)dpx; font-weight: bold; color: %(dim14)s; letter-spacing: 1.2px; }
.sk-pill { font-size: %(body)dpx; font-weight: bold; color: %(dim14)s; border: %(nbw)dpx solid %(normal_border)s;
  border-radius: %(r)dpx; padding: 1px 5px; }
.sk-section { font-size: %(caption)dpx; font-weight: bold; color: %(dim14)s; }
.sk-separator { background: %(hairline)s; min-height: 1px; }
.sk-caption { font-size: %(caption)dpx; }
.sk-small { font-size: %(body_small)dpx; }
.sk-title { font-size: %(title)dpx; }
.sk-heading { font-size: %(heading)dpx; }
.sk-display { font-size: %(display)dpx; }
.sk-display-large { font-size: %(display_large)dpx; }
.sk-bold { font-weight: bold; }

/* List rows (devices, networks...). */
.sk-row { border-radius: %(r)dpx; padding: 6px 8px; border: %(hbw)dpx solid transparent; }
.sk-row:hover { background: %(hover)s; border-color: %(hover_border)s; }
.sk-row.selected { background: %(selected)s; border-color: %(selected_border)s; }
.sk-row.selected label { color: %(selected_color)s; }

/* PanelActionButton / Button. */
button.sk-action { background: transparent; border: none; box-shadow: none; padding: 2px 6px;
  min-height: 22px; min-width: 22px; border-radius: %(r)dpx; color: %(fg)s;
  font-family: "%(family)s"; font-size: %(icon)dpx; }
button.sk-action:hover { background: %(hover)s; color: %(hover_color)s; }
button.sk-action:active { background: %(pressed)s; }
button.sk-action:disabled { color: %(dim20)s; }
button.sk-button { background: %(normal)s; border: %(nbw)dpx solid %(normal_border)s; box-shadow: none;
  border-radius: %(r)dpx; color: %(fg)s; padding: 4px 10px; font-family: "%(family)s"; font-size: %(body)dpx; }
button.sk-button:hover { background: %(hover)s; border-color: %(hover_border)s; }
button.sk-button.selected { background: %(selected)s; border-color: %(selected_border)s; color: %(selected_color)s; }

/* PanelSlider. */
scale.sk-slider { padding: 6px 0; }
scale.sk-slider trough { min-height: 4px; border-radius: 2px; background: %(track)s; border: none; margin: 0; }
scale.sk-slider highlight { background: %(fg)s; border-radius: 2px; border: none; min-height: 4px; margin: 0; }
scale.sk-slider slider { min-width: 14px; min-height: 14px; margin: -6px 0; border-radius: 50%%;
  background: %(fg)s; border: 2px solid %(bg)s; box-shadow: none; }
scale.sk-slider:hover slider { min-width: 16px; min-height: 16px; margin: -7px 0; }

/* ToggleSwitch. */
switch.sk-switch { background: %(normal)s; border: %(nbw)dpx solid %(normal_border)s; border-radius: %(r)dpx;
  min-width: 40px; min-height: 22px; }
switch.sk-switch:checked { background: %(selected)s; border-color: %(selected_border)s; }
switch.sk-switch slider { background: %(dim12)s; border-radius: %(r)dpx; min-width: 16px; min-height: 16px;
  margin: 2px; box-shadow: none; border: none; }
switch.sk-switch:checked slider { background: %(selected_color)s; }
switch.sk-switch image { color: transparent; }

entry.sk-entry { font-family: "%(family)s"; font-size: %(body)dpx; color: %(fg)s; background: %(normal)s;
  border: %(nbw)dpx solid %(normal_border)s; border-radius: %(r)dpx; min-height: 0; padding: 4px 8px; }
entry.sk-entry:focus-within { border-color: %(hover_border)s; }
tooltip { background: %(bg)s; color: %(fg)s; border: 1px solid %(fg)s; border-radius: %(r)dpx; }
tooltip label { font-family: "%(family)s"; font-size: %(body_small)dpx; }
"""
        return (base + extra) % vals
