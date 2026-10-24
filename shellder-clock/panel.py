"""Popup do calendário — porte do Panel.qml do clock do Omarchy para GTK4 +
gtk4-layer-shell.

Uma grade de mês com número da semana ISO, feita para ler, não para escolher:
o único dia marcado é hoje, e a única coisa que se move é o mês na tela
(setas, scroll, teclado). Medidas e cores seguem o Panel.qml; o tema vem do
evento "config" do Shellder.

O GTK só é carregado na primeira vez que o popup abre (import_gtk), para o
plugin ficar leve enquanto só mostra a hora na barra.
"""

import datetime as dt
import subprocess
import sys

import model as M

Gtk = Gdk = GLib = LayerShell = None

# Medidas do Panel.qml (Style.space(n) com escala 1).
CELL_W, CELL_H, CELL_SPACING = 52, 34, 2
WEEK_COL_W, GUTTER_W = 32, 14
CONTENT_W = 560
PANEL_PADDING = 18  # [spacing] panel-padding


def import_gtk():
    """Carrega GTK4 + layer-shell. A libgtk4-layer-shell precisa ser carregada
    antes da libwayland-client, por isso o CDLL vem antes do import do Gtk."""
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
        print("shellder-clock: sem GTK4/gtk4-layer-shell, calendário desligado: %s" % e,
              file=sys.stderr)
        return False
    Gtk, Gdk, GLib, LayerShell = _Gtk, _Gdk, _GLib, _LayerShell
    Gtk.init()
    return True


# ---- cores -----------------------------------------------------------------

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
    """Qt.darker: divide o brilho pelo fator."""
    return (c[0] / factor, c[1] / factor, c[2] / factor, c[3])


def with_alpha(c, a):
    return (c[0], c[1], c[2], a)


def css(c):
    return "rgba(%d,%d,%d,%.3f)" % (round(c[0] * 255), round(c[1] * 255), round(c[2] * 255), c[3])


def locale_week_start():
    """Primeiro dia da semana do locale (glibc), 0 = domingo. O Omarchy usa o
    Qt.locale().firstDayOfWeek como padrão."""
    try:
        out = subprocess.run(["locale", "first_weekday"], capture_output=True, text=True,
                             timeout=1).stdout.strip()
        return (int(out) - 1) % 7
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1


def hypr_gap():
    """Distância do popup até a barra: o gaps_out do Hyprland, como o
    Style.gapsOut do Omarchy."""
    try:
        out = subprocess.run(["hyprctl", "-j", "getoption", "general:gaps_out"],
                             capture_output=True, text=True, timeout=1).stdout
        import json
        custom = json.loads(out).get("custom", "")
        return int(str(custom).split()[0])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return 8


class Theme:
    """Tema do evento "config" do Shellder, com os papéis que o Panel.qml usa."""

    def __init__(self, data):
        data = data or {}
        colors = data.get("colors", {})
        popup = data.get("popup", {})
        controls = data.get("controls", {})
        font = data.get("font", {})
        self.family = font.get("family") or "monospace"
        self.sizes = font.get("sizes", {})
        self.radius = int(data.get("radius", 0))
        self.fg = parse_hex(popup.get("text") or colors.get("foreground"))
        self.bg = parse_hex(popup.get("background") or colors.get("background"), (0.1, 0.1, 0.1, 1))
        self.border = parse_hex(popup.get("border") or colors.get("accent"))
        self.border_width = int(popup.get("borderWidth", 1))
        self.accent = parse_hex(colors.get("accent"))
        self.hover = parse_hex(controls.get("hover"), with_alpha(self.fg, 0.08))

    def size(self, name, default):
        return int(self.sizes.get(name, default))

    def stylesheet(self):
        fg, accent, r = self.fg, self.accent, self.radius
        s = self.size
        return """
window.shellder-clock { background: transparent; }
.panel {
  background: %(bg)s; color: %(fg)s; font-family: "%(family)s";
  border: %(bw)dpx solid %(border)s; border-radius: %(r)dpx; padding: %(pad)dpx;
}
.panel label { font-family: "%(family)s"; }
.hero-icon { font-size: 48px; color: %(fg)s; }
.hero-date { font-size: 52px; font-weight: bold; color: %(fg)s; }
.hero.link:hover .hero-icon, .hero.link:hover .hero-date { color: %(accent)s; }
.rail-label { font-size: %(body_small)dpx; color: %(dim15)s; letter-spacing: 1px; }
.rail-value { font-size: %(body_small)dpx; color: %(fg)s; }
.week-toggle { font-size: %(caption)dpx; font-weight: bold; color: %(dim19)s;
  letter-spacing: 1px; border-radius: %(r)dpx; min-height: 16px; }
.week-toggle:hover { background: %(hover)s; color: %(accent)s; }
.weekday { font-size: %(caption)dpx; font-weight: bold; color: %(dim15)s; letter-spacing: 1px; }
.week-number { font-size: %(caption)dpx; color: %(dim19)s; }
.gutter-line { background: %(hairline)s; min-width: 1px; }
.day { font-size: %(body)dpx; color: %(fg)s; border-radius: %(r)dpx; border: 1px solid transparent; }
.day.weekend { color: %(dim145)s; }
.day.out { color: %(dim22)s; }
.day.today { border-color: %(accent)s; font-weight: bold; }
.month-label { font-size: %(body)dpx; color: %(dim14)s; letter-spacing: 1px; }
.nav { font-size: %(icon)dpx; color: %(fg)s; border-radius: %(r)dpx; padding: 2px 8px; }
.nav:hover { background: %(hover)s; color: %(accent)s; }
.life-entry { font-family: "%(family)s"; font-size: %(body)dpx; color: %(fg)s;
  background: %(hover)s; border: 1px solid %(dim19)s; border-radius: %(r)dpx;
  min-height: 0; padding: 2px 6px; }
""" % {
            "bg": css(self.bg), "fg": css(fg), "accent": css(accent),
            "border": css(self.border), "bw": self.border_width, "r": r,
            "pad": PANEL_PADDING, "family": self.family.replace('"', ""),
            "hover": css(self.hover), "hairline": css(with_alpha(fg, 0.1)),
            "dim14": css(darker(fg, 1.4)), "dim145": css(darker(fg, 1.45)),
            "dim15": css(darker(fg, 1.5)), "dim19": css(darker(fg, 1.9)),
            "dim22": css(darker(fg, 2.2)),
            "caption": s("caption", 10), "body_small": s("bodySmall", 11),
            "body": s("body", 12), "icon": s("icon", 14),
        }


def _label(text="", classes=(), **kw):
    lbl = Gtk.Label(label=text, **kw)
    for c in classes:
        lbl.add_css_class(c)
    return lbl


def _on_click(widget, callback, presses=1, button=1):
    g = Gtk.GestureClick(button=button)

    def released(gesture, n, x, y):
        if n == presses:
            callback()
    g.connect("released", released)
    widget.add_controller(g)
    return g


class Rail:
    """Trilho de progresso do Panel.qml: rótulo | barra | percentual."""

    def __init__(self, panel):
        self.panel = panel
        self.fraction = 0.0
        self.box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.label = _label(classes=["rail-label"])
        self.value = _label(classes=["rail-value"])
        self.track = Gtk.DrawingArea(hexpand=True, content_height=6, valign=Gtk.Align.CENTER)
        self.track.set_draw_func(self._draw)
        self.box.append(self.label)
        self.box.append(self.track)
        self.box.append(self.value)

    def set(self, label, fraction, percent):
        self.label.set_label(label)
        self.value.set_label("%d%%" % percent)
        self.fraction = fraction
        self.track.queue_draw()

    def _draw(self, area, cr, w, h):
        th = self.panel.theme
        r = h / 2 if th.radius > 0 else 0

        def rect(width, color):
            if width <= 0:
                return
            cr.set_source_rgba(*color)
            if r:
                import math
                cr.new_sub_path()
                cr.arc(width - r, r, r, -math.pi / 2, math.pi / 2)
                cr.arc(r, r, r, math.pi / 2, 3 * math.pi / 2)
                cr.close_path()
            else:
                cr.rectangle(0, 0, width, h)
            cr.fill()
        rect(w, with_alpha(th.fg, 0.12))
        rect(round(w * self.fraction), th.accent)


class CalendarPanel:
    def __init__(self, settings, save_settings):
        self.settings = settings
        self.save_settings = save_settings
        self.theme = Theme(None)
        self.window = None
        self.catchers = {}  # conector -> janela que fecha o popup nos outros monitores
        self.opened = False
        self.editing_life = False
        self.today = dt.date.today()
        self.view_year, self.view_month = self.today.year, self.today.month - 1
        self.gap = 8
        self.locale_start = 1
        self.provider = None

    # ---- estado --------------------------------------------------------

    @property
    def week_start(self):
        return M.normalized_week_start(self.settings.get("weekStartDay"), self.locale_start)

    @property
    def birth_year(self):
        return M.parse_birth_year(self.settings.get("birthYear", 0), self.today.year)

    @property
    def life_expectancy(self):
        return M.parse_life_expectancy(self.settings.get("lifeExpectancy", 0))

    @property
    def viewing_current_month(self):
        return self.view_year == self.today.year and self.view_month == self.today.month - 1

    def set_theme(self, data):
        self.theme = Theme(data)
        if self.provider is not None:
            self.provider.load_from_string(self.theme.stylesheet())
            self.refresh()

    def tick(self):
        """Chamado a cada minuto: vira o dia sem precisar reabrir."""
        today = dt.date.today()
        if today == self.today:
            return
        follow = self.viewing_current_month
        self.today = today
        if follow:
            self.go_to_today()
        elif self.window is not None:
            self.refresh()

    # ---- abrir / fechar --------------------------------------------------

    def toggle(self, event):
        if self.opened:
            self.close()
        else:
            self.open(event)

    def open(self, event):
        if not import_gtk():
            return
        if self.window is None:
            self._build()
        self.today = dt.date.today()
        self.go_to_today()
        target = self._place(event)
        for connector, c in self.catchers.items():
            if connector != target:
                c.present()
        # Foco de teclado como o KeyboardPanel do Omarchy: EXCLUSIVE só por um
        # instante para ganhar o foco ao abrir, depois ON_DEMAND. Exclusive o
        # tempo todo faria o Hyprland mandar todo o ponteiro para cá, inclusive
        # o dos outros monitores, e os cliques de fechar não chegariam lá.
        LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.EXCLUSIVE)
        self.window.present()
        self.opened = True
        GLib.timeout_add(75, self._prime_done)

    def _prime_done(self):
        if self.opened:
            LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.ON_DEMAND)
        return False

    def close(self):
        if self.editing_life:
            self.cancel_editing_life()
        if self.window is not None:
            self.window.set_visible(False)
        for c in self.catchers.values():
            c.set_visible(False)
        self.opened = False

    def _monitor(self, connector):
        monitors = Gdk.Display.get_default().get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            if m.get_connector() == connector:
                return m
        return None

    def _place(self, event):
        """Põe a janela no monitor do clique e o card encostado na barra,
        centrado no item. Devolve o conector do monitor."""
        win = self.window
        card = self.content
        bar = event.get("bar", {})
        item = event.get("item", {})
        position = bar.get("position", "bottom")
        connector = event.get("monitor", "")
        monitor = self._monitor(connector)
        if monitor is not None:
            LayerShell.set_monitor(win, monitor)

        # Zera as margens antes de medir: o measure do GTK4 inclui margens (as
        # da abertura anterior deslocariam o card), além de padding e borda.
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

    # ---- construção ------------------------------------------------------

    def _build(self):
        self.gap = hypr_gap()
        self.locale_start = locale_week_start()

        display = Gdk.Display.get_default()
        self.provider = Gtk.CssProvider()
        self.provider.load_from_string(self.theme.stylesheet())
        Gtk.StyleContext.add_provider_for_display(display, self.provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)

        # Mesmo desenho do KeyboardPanel do Omarchy: o popup é uma layer que
        # cobre a área útil do monitor (exclusive zone 0, então a barra fica de
        # fora e continua clicável) com o card dentro. Clique fora do card, na
        # própria layer, fecha. Nos outros monitores, uma layer transparente
        # sem teclado faz o mesmo.
        def fullscreen_layer(namespace, keyboard):
            w = Gtk.Window()
            w.add_css_class("shellder-clock")
            LayerShell.init_for_window(w)
            LayerShell.set_namespace(w, namespace)
            LayerShell.set_layer(w, LayerShell.Layer.OVERLAY)
            for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM,
                         LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
                LayerShell.set_anchor(w, edge, True)
            LayerShell.set_keyboard_mode(w, keyboard)
            return w

        monitors = display.get_monitors()
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            c = fullscreen_layer("shellder-clock-catcher", LayerShell.KeyboardMode.NONE)
            LayerShell.set_monitor(c, m)
            catch = Gtk.Box(hexpand=True, vexpand=True)
            _on_click(catch, self.close)
            c.set_child(catch)
            self.catchers[m.get_connector()] = c

        win = fullscreen_layer("shellder-clock", LayerShell.KeyboardMode.ON_DEMAND)
        self.window = win

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        win.add_controller(keys)

        overlay = Gtk.Overlay()
        outside = Gtk.Box(hexpand=True, vexpand=True)
        _on_click(outside, self.close)
        overlay.set_child(outside)
        win.set_child(overlay)

        frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        frame.add_css_class("panel")
        frame.set_size_request(CONTENT_W, -1)
        self.content = frame
        overlay.add_overlay(frame)

        frame.append(self._build_hero())

        # Tudo abaixo do herói tem a largura da grade.
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, halign=Gtk.Align.CENTER)
        frame.append(column)

        self.year_rail = Rail(self)
        self.year_rail.box.set_margin_top(6)
        _on_click(self.year_rail.box, self.start_editing_life, presses=2)
        self.life_editor = self._build_life_editor()
        self.year_stack = Gtk.Stack()
        self.year_stack.add_named(self.year_rail.box, "rail")
        self.year_stack.add_named(self.life_editor, "edit")
        column.append(self.year_stack)

        self.life_rail = Rail(self)
        self.life_rail.box.set_tooltip_text("Memento Mori")
        _on_click(self.life_rail.box, self.clear_life, presses=2)
        column.append(self.life_rail.box)

        column.append(self._build_grid())
        column.append(self._build_nav())

    def _build_hero(self):
        hero = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=22, halign=Gtk.Align.CENTER)
        hero.add_css_class("hero")
        hero.append(_label("󰃭", ["hero-icon"], valign=Gtk.Align.BASELINE))
        self.hero_date = _label("", ["hero-date"], valign=Gtk.Align.BASELINE)
        hero.append(self.hero_date)
        _on_click(hero, self.go_to_today)
        self.hero = hero
        return hero

    def _build_life_editor(self):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10, halign=Gtk.Align.CENTER)
        row.set_margin_top(6)
        self.born_entry = Gtk.Entry(placeholder_text="year", width_chars=6, max_length=4)
        self.expectancy_entry = Gtk.Entry(placeholder_text="90", width_chars=4, max_length=3)
        for entry, other in ((self.born_entry, self.expectancy_entry),
                             (self.expectancy_entry, self.born_entry)):
            entry.add_css_class("life-entry")
            entry.connect("activate", lambda *_: self.commit_life())
            keys = Gtk.EventControllerKey()
            keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            keys.connect("key-pressed", self._on_life_key, other)
            entry.add_controller(keys)
        row.append(_label("BORN", ["rail-label"]))
        row.append(self.born_entry)
        lbl = _label("LIVE TO", ["rail-label"])
        lbl.set_margin_start(6)
        row.append(lbl)
        row.append(self.expectancy_entry)
        return row

    def _build_grid(self):
        grid = Gtk.Grid(column_spacing=CELL_SPACING, row_spacing=3)
        grid.set_margin_top(18)

        self.week_toggle = Gtk.Button(label="W")
        self.week_toggle.add_css_class("flat")
        self.week_toggle.add_css_class("week-toggle")
        self.week_toggle.set_size_request(WEEK_COL_W, 16)
        self.week_toggle.set_cursor_from_name("pointer")
        self.week_toggle.connect("clicked", lambda *_: self.toggle_week_start())
        grid.attach(self.week_toggle, 0, 0, 1, 1)

        spacer = Gtk.Box()
        spacer.set_size_request(GUTTER_W, 16)
        grid.attach(spacer, 1, 0, 1, 1)

        self.weekday_labels = []
        for col in range(7):
            lbl = _label("", ["weekday"])
            lbl.set_size_request(CELL_W, 16)
            grid.attach(lbl, 2 + col, 0, 1, 1)
            self.weekday_labels.append(lbl)

        # Divisória fina descendo pela coluna das semanas, só ao lado dos dias.
        line = Gtk.Box(halign=Gtk.Align.CENTER)
        line.add_css_class("gutter-line")
        line.set_size_request(1, -1)
        grid.attach(line, 1, 1, 1, 6)

        self.week_labels = []
        self.day_labels = []
        for row in range(6):
            wk = _label("", ["week-number"])
            wk.set_size_request(WEEK_COL_W, CELL_H)
            grid.attach(wk, 0, 1 + row, 1, 1)
            self.week_labels.append(wk)
            days = []
            for col in range(7):
                d = _label("", ["day"])
                d.set_size_request(CELL_W, CELL_H)
                grid.attach(d, 2 + col, 1 + row, 1, 1)
                days.append(d)
            self.day_labels.append(days)

        scroll = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.VERTICAL)
        scroll.connect("scroll", self._on_scroll)
        grid.add_controller(scroll)
        return grid

    def _build_nav(self):
        nav = Gtk.CenterBox()
        self.month_label = _label("", ["month-label"])
        self.month_label.set_size_request(130, -1)
        prev = Gtk.Button(label="󰅁", tooltip_text="Previous month")
        nxt = Gtk.Button(label="󰅂", tooltip_text="Next month")
        for b, delta in ((prev, -1), (nxt, 1)):
            b.add_css_class("flat")
            b.add_css_class("nav")
            b.set_cursor_from_name("pointer")
            b.connect("clicked", lambda _b, d=delta: self.move_month(d))
        nav.set_start_widget(prev)
        nav.set_center_widget(self.month_label)
        nav.set_end_widget(nxt)
        return nav

    # ---- atualização -----------------------------------------------------

    def refresh(self):
        if self.window is None:
            return
        today = self.today
        self.hero_date.set_label(M.format_qt(dt.datetime(today.year, today.month, today.day), "MMMM d"))
        if self.viewing_current_month:
            self.hero.remove_css_class("link")
            self.hero.set_tooltip_text(None)
            self.hero.set_cursor_from_name(None)
        else:
            self.hero.add_css_class("link")
            self.hero.set_tooltip_text("Back to today")
            self.hero.set_cursor_from_name("pointer")

        y, m, d = today.year, today.month - 1, today.day
        self.year_rail.set(str(y), M.year_progress(y, m, d), M.year_progress_percent(y, m, d))
        self.year_stack.set_visible_child_name("edit" if self.editing_life else "rail")

        born = self.birth_year
        self.life_rail.box.set_visible(born > 0)
        if born > 0:
            age = M.age_from_birth_year(born, y)
            self.life_rail.set("LIFE", M.life_progress(age, self.life_expectancy),
                               M.life_progress_percent(age, self.life_expectancy))

        start = self.week_start
        next_start = M.DAY_LONG[M.toggled_week_start(start)]
        self.week_toggle.set_tooltip_text("Start weeks on " + next_start)
        for lbl, weekday in zip(self.weekday_labels, M.weekday_order(start)):
            lbl.set_label(M.DAY_SHORT[weekday].upper())

        weeks = M.month_grid(self.view_year, self.view_month, start, M.key_for_date(today))
        for row, week in enumerate(weeks):
            self.week_labels[row].set_label(str(week["week"]))
            for col, day in enumerate(week["days"]):
                lbl = self.day_labels[row][col]
                lbl.set_label(str(day["day"]))
                for cls, on in (("out", not day["inMonth"]),
                                ("weekend", day["inMonth"] and day["weekend"]),
                                ("today", day["today"])):
                    (lbl.add_css_class if on else lbl.remove_css_class)(cls)

        view = dt.datetime(self.view_year, self.view_month + 1, 1, 12)
        self.month_label.set_label(M.format_qt(view, "MMMM yyyy").upper())

    def go_to_today(self):
        self.view_year, self.view_month = self.today.year, self.today.month - 1
        self.refresh()

    def move_month(self, delta):
        nxt = M.step_month(self.view_year, self.view_month, delta)
        self.view_year, self.view_month = nxt["year"], nxt["month"]
        self.refresh()

    def move_year(self, delta):
        self.move_month(delta * 12)

    def toggle_week_start(self):
        nxt = M.toggled_week_start(self.week_start)
        self.save_settings({"weekStartDay": M.week_start_setting_name(nxt)})
        self.refresh()

    # ---- memento mori ----------------------------------------------------

    def start_editing_life(self):
        if self.editing_life:
            return
        self.editing_life = True
        self.born_entry.set_text(str(self.birth_year) if self.birth_year > 0 else "")
        self.expectancy_entry.set_text(str(self.life_expectancy))
        self.refresh()
        self.born_entry.grab_focus()
        self.born_entry.select_region(0, -1)

    def cancel_editing_life(self):
        self.editing_life = False
        self.refresh()
        self.window.set_focus(None)

    def commit_life(self):
        born = M.parse_birth_year(self.born_entry.get_text(), self.today.year)
        span = M.parse_life_expectancy(self.expectancy_entry.get_text())
        if born != self.birth_year or span != self.life_expectancy:
            self.save_settings({"birthYear": born, "lifeExpectancy": span})
        self.cancel_editing_life()

    def clear_life(self):
        if self.birth_year > 0:
            self.save_settings({"birthYear": 0})
            self.refresh()

    # ---- entrada ---------------------------------------------------------

    def _on_life_key(self, ctrl, keyval, keycode, state, other):
        if keyval == Gdk.KEY_Escape:
            self.cancel_editing_life()
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab):
            other.grab_focus()
            other.select_region(0, -1)
            return True
        return False

    def _on_key(self, ctrl, keyval, keycode, state):
        if self.editing_life:
            return False
        K = Gdk
        if keyval == K.KEY_Escape:
            self.close()
        elif keyval == K.KEY_Left:
            self.move_month(-1)
        elif keyval == K.KEY_Right:
            self.move_month(1)
        elif keyval == K.KEY_Up:
            self.move_year(-1)
        elif keyval == K.KEY_Down:
            self.move_year(1)
        elif keyval in (K.KEY_Return, K.KEY_KP_Enter, K.KEY_space):
            self.go_to_today()
        else:
            ch = chr(K.keyval_to_unicode(keyval) or 0)
            action = {
                "[": lambda: self.move_month(-1), "]": lambda: self.move_month(1),
                "{": lambda: self.move_year(-1), "}": lambda: self.move_year(1),
                "t": self.go_to_today, "T": self.go_to_today,
                "w": self.toggle_week_start, "W": self.toggle_week_start,
            }.get(ch)
            if action is None:
                return False
            action()
        return True

    def _on_scroll(self, ctrl, dx, dy):
        # Scroll horizontal (dy == 0) não conta como "próximo mês".
        if dy == 0:
            return False
        self.move_month(1 if dy > 0 else -1)
        return True
