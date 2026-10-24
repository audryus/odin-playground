"""Popup following Omarchy's KeyboardPanel (Ui/KeyboardPanel.qml), in
GTK4 + gtk4-layer-shell:

  - one layer covering the usable area of the clicked output (exclusive
    zone 0: the bar stays outside and clickable) with the card inside, next to
    the bar and centered on the item; a click outside the card closes it;
  - on the other outputs, a transparent keyboard-less layer that only closes;
  - keyboard EXCLUSIVE for 75 ms to take focus, then ON_DEMAND (permanent
    EXCLUSIVE makes Hyprland route all pointer input to the layer, so the
    closing clicks on the other outputs never arrive);
  - never closes on focus loss (focus changes on the way to the card).

Usage:

    from shellder_kit import panel as P

    class MyPanel(P.Panel):
        def build(self, card):      # build the content (once)
            card.append(P.section("Devices"))
        def refresh(self):          # update on every open / whenever needed
            ...

    self.panel = MyPanel(self, "shellder-audio", width=340)
    self.panel.toggle(click_event)
"""

import json
import subprocess
import sys

Gtk = Gdk = GLib = LayerShell = None
_css_provider = None
_css_theme = None


def import_gtk():
    """Load GTK4 + layer-shell. libgtk4-layer-shell must be loaded before
    libwayland-client, hence the CDLL before importing Gtk."""
    global Gtk, Gdk, GLib, LayerShell
    if Gtk is not None:
        return True
    try:
        from ctypes import CDLL
        CDLL("libgtk4-layer-shell.so")
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Gdk", "4.0")
        gi.require_version("Gtk4LayerShell", "1.0")
        from gi.repository import Gdk as _Gdk, GLib as _GLib, Gtk as _Gtk
        from gi.repository import Gtk4LayerShell as _LayerShell
    except (OSError, ImportError, ValueError) as e:
        print("shellder_kit: no GTK4/gtk4-layer-shell, popups disabled: %s" % e, file=sys.stderr)
        return False
    Gtk, Gdk, GLib, LayerShell = _Gtk, _Gdk, _GLib, _LayerShell
    Gtk.init()
    return True


def apply_css(theme, extra=""):
    """(Re)apply the theme CSS to the display (one provider per process)."""
    global _css_provider, _css_theme
    if not import_gtk():
        return
    if _css_provider is None:
        _css_provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), _css_provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)
    _css_provider.load_from_string(theme.stylesheet(extra))
    _css_theme = theme


def hypr_gap():
    """Popup distance from the bar: Hyprland's gaps_out, like Omarchy's
    Style.gapsOut."""
    try:
        out = subprocess.run(["hyprctl", "-j", "getoption", "general:gaps_out"],
                             capture_output=True, text=True, timeout=1).stdout
        return int(str(json.loads(out).get("custom", "")).split()[0])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return 8


# ---- widgets in Omarchy's style -------------------------------------------

def label(text="", *classes, xalign=None, **kw):
    lbl = Gtk.Label(label=text, **kw)
    if xalign is not None:
        lbl.set_xalign(xalign)
    for c in classes:
        lbl.add_css_class(c)
    return lbl


def section(text):
    """PanelSectionHeader."""
    return label(text, "sk-section", xalign=0)


def separator():
    """PanelSeparator."""
    sep = Gtk.Box()
    sep.add_css_class("sk-separator")
    sep.set_hexpand(True)
    return sep


def hero(icon, title="", meta="", detail="", trailing=None):
    """PanelHero: large icon, bold title, small-caps meta, detail pill and an
    optional trailing control. Returns (box, widgets)."""
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
    icon_lbl = label(icon, "sk-hero-icon", valign=Gtk.Align.CENTER)
    labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True,
                     valign=Gtk.Align.CENTER)
    title_row = Gtk.Box(spacing=8)
    title_lbl = label(title, "sk-hero-title", xalign=0, hexpand=True)
    title_lbl.set_ellipsize(3)  # END
    pill = label(detail, "sk-pill")
    pill.set_visible(bool(detail))
    title_row.append(title_lbl)
    title_row.append(pill)
    meta_lbl = label(meta.upper(), "sk-hero-meta", xalign=0)
    meta_lbl.set_ellipsize(3)
    meta_lbl.set_visible(bool(meta))
    labels.append(title_row)
    labels.append(meta_lbl)
    box.append(icon_lbl)
    box.append(labels)
    if trailing is not None:
        trailing.set_valign(Gtk.Align.CENTER)
        box.append(trailing)
    return box, {"icon": icon_lbl, "title": title_lbl, "meta": meta_lbl, "detail": pill}


def set_hero(w, icon=None, title=None, meta=None, detail=None):
    if icon is not None:
        w["icon"].set_label(icon)
    if title is not None:
        w["title"].set_label(title)
    if meta is not None:
        w["meta"].set_label(meta.upper())
        w["meta"].set_visible(bool(meta))
    if detail is not None:
        w["detail"].set_label(detail)
        w["detail"].set_visible(bool(detail))


def action_button(icon, callback, tooltip=None):
    """PanelActionButton."""
    b = Gtk.Button(label=icon)
    b.add_css_class("flat")
    b.add_css_class("sk-action")
    b.set_cursor_from_name("pointer")
    if tooltip:
        b.set_tooltip_text(tooltip)
    b.connect("clicked", lambda *_: callback())
    return b


def button(text, callback, tooltip=None):
    b = Gtk.Button(label=text)
    b.add_css_class("sk-button")
    b.set_cursor_from_name("pointer")
    if tooltip:
        b.set_tooltip_text(tooltip)
    b.connect("clicked", lambda *_: callback())
    return b


def switch(active, callback):
    """ToggleSwitch. callback(bool) when the user toggles it."""
    sw = Gtk.Switch(active=bool(active), valign=Gtk.Align.CENTER)
    sw.add_css_class("sk-switch")
    sw.set_cursor_from_name("pointer")
    sw._sk_guard = False

    def changed(s, _pspec):
        if not s._sk_guard:
            callback(s.get_active())
    sw.connect("notify::active", changed)
    return sw


def set_switch(sw, active):
    """Change the switch without firing the callback."""
    if sw.get_active() == bool(active):
        return
    sw._sk_guard = True
    sw.set_active(bool(active))
    sw._sk_guard = False


def slider(value, on_change, minimum=0.0, maximum=1.0, step=0.05):
    """PanelSlider. on_change(value) while dragging."""
    sc = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, minimum, maximum, step)
    sc.add_css_class("sk-slider")
    sc.set_draw_value(False)
    sc.set_hexpand(True)
    sc.set_value(value)
    sc.set_cursor_from_name("pointer")
    sc._sk_guard = False

    def changed(s):
        if not s._sk_guard:
            on_change(s.get_value())
    sc.connect("value-changed", changed)
    return sc


def set_slider(sc, value):
    sc._sk_guard = True
    sc.set_value(value)
    sc._sk_guard = False


def row(*children, on_click=None, selected=False, spacing=10, tooltip=None):
    """List row with hover/selection (device, network...)."""
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)
    box.add_css_class("sk-row")
    if selected:
        box.add_css_class("selected")
    for c in children:
        box.append(c)
    if tooltip:
        box.set_tooltip_text(tooltip)
    if on_click is not None:
        box.set_cursor_from_name("pointer")
        on_click_gesture(box, on_click)
    return box


def on_click_gesture(widget, callback, button=1, presses=1):
    g = Gtk.GestureClick(button=button)

    def released(gesture, n, x, y):
        if n == presses:
            callback()
    g.connect("released", released)
    widget.add_controller(g)
    return g


def clear(box):
    child = box.get_first_child()
    while child is not None:
        nxt = child.get_next_sibling()
        box.remove(child)
        child = nxt


# ---- panel --------------------------------------------------------------------

class Panel:
    PADDING = 14  # Style.spacing.popupPadding

    def __init__(self, plugin, namespace, width=None, css=""):
        self.plugin = plugin
        self.namespace = namespace
        self.width = width
        self.css = css
        self.window = None
        self.card = None
        self.catchers = {}
        self.opened = False
        self.gap = 8
        self.event = None

    # ---- override ---------------------------------------------------------

    def build(self, card):
        """Build the content into the card (vertical Gtk.Box). Once."""

    def refresh(self):
        """Update the content. Called on every open."""

    def on_key(self, keyval, char):
        """A key without default handling (Esc closes). True = consumed."""
        return False

    def on_open(self):
        pass

    def on_close(self):
        pass

    # ---- API ----------------------------------------------------------------

    def toggle(self, event):
        if self.opened:
            self.close()
        else:
            self.open(event)

    def open(self, event):
        if not import_gtk():
            return
        self.event = event
        if self.window is None:
            self._build()
        apply_css(self.plugin.theme, self.css)
        self.refresh()
        target = self._place(event)
        for connector, c in self.catchers.items():
            if connector != target:
                c.present()
        LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.EXCLUSIVE)
        self.window.present()
        self.opened = True
        GLib.timeout_add(75, self._prime_done)
        self.on_open()

    def close(self):
        if self.window is not None:
            self.window.set_visible(False)
        for c in self.catchers.values():
            c.set_visible(False)
        if self.opened:
            self.opened = False
            self.on_close()

    def theme_changed(self):
        if self.window is not None:
            apply_css(self.plugin.theme, self.css)

    # ---- internals ----------------------------------------------------------

    def _prime_done(self):
        if self.opened:
            LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.ON_DEMAND)
        return False

    def _layer(self, namespace, keyboard):
        w = Gtk.Window()
        w.add_css_class("sk-layer")
        LayerShell.init_for_window(w)
        LayerShell.set_namespace(w, namespace)
        LayerShell.set_layer(w, LayerShell.Layer.OVERLAY)
        for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM,
                     LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
            LayerShell.set_anchor(w, edge, True)
        LayerShell.set_keyboard_mode(w, keyboard)
        return w

    def _build(self):
        self.gap = hypr_gap()
        display = Gdk.Display.get_default()
        monitors = display.get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            c = self._layer(self.namespace + "-catcher", LayerShell.KeyboardMode.NONE)
            LayerShell.set_monitor(c, m)
            catch = Gtk.Box(hexpand=True, vexpand=True)
            on_click_gesture(catch, self.close)
            on_click_gesture(catch, self.close, button=3)
            c.set_child(catch)
            self.catchers[m.get_connector()] = c

        win = self._layer(self.namespace, LayerShell.KeyboardMode.ON_DEMAND)
        self.window = win
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        win.add_controller(keys)

        overlay = Gtk.Overlay()
        outside = Gtk.Box(hexpand=True, vexpand=True)
        on_click_gesture(outside, self.close)
        on_click_gesture(outside, self.close, button=3)
        overlay.set_child(outside)
        win.set_child(overlay)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.add_css_class("sk-panel")
        if self.width:
            card.set_size_request(self.width, -1)
        self.card = card
        overlay.add_overlay(card)
        self.build(card)

    def _on_key(self, ctrl, keyval, keycode, state):
        if keyval == Gdk.KEY_Escape:
            self.close()
            return True
        ch = chr(Gdk.keyval_to_unicode(keyval) or 0)
        return bool(self.on_key(keyval, ch))

    def _monitor(self, connector):
        monitors = Gdk.Display.get_default().get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            if m.get_connector() == connector:
                return m
        return None

    def _place(self, event):
        win, card = self.window, self.card
        bar = event.get("bar", {})
        item = event.get("item", {})
        position = bar.get("position", "bottom")
        connector = event.get("monitor", "")
        monitor = self._monitor(connector)
        if monitor is not None:
            LayerShell.set_monitor(win, monitor)
        # Reset margins before measuring: GTK4's measure includes margins.
        for m in ("start", "end", "top", "bottom"):
            getattr(card, "set_margin_" + m)(0)
        pw = card.measure(Gtk.Orientation.HORIZONTAL, -1)[1]
        ph = card.measure(Gtk.Orientation.VERTICAL, pw)[1]
        gap = self.gap

        def clamp(v, lo, hi):
            return max(lo, min(v, hi))

        A = Gtk.Align
        if position in ("bottom", "top"):
            center = item.get("x", 0) + item.get("width", 0) / 2
            card.set_halign(A.START)
            card.set_margin_start(clamp(round(center - pw / 2), gap,
                                        max(gap, bar.get("width", pw) - pw - gap)))
            if position == "bottom":
                card.set_valign(A.END)
                card.set_margin_bottom(gap)
            else:
                card.set_valign(A.START)
                card.set_margin_top(gap)
        else:
            center = item.get("y", 0) + item.get("height", 0) / 2
            card.set_valign(A.START)
            card.set_margin_top(clamp(round(center - ph / 2), gap,
                                      max(gap, bar.get("height", ph) - ph - gap)))
            if position == "left":
                card.set_halign(A.START)
                card.set_margin_start(gap)
            else:
                card.set_halign(A.END)
                card.set_margin_end(gap)
        return connector
