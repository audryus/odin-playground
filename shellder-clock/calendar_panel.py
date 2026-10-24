"""Calendar popup — port of the Omarchy clock's Panel.qml, on top of
shellder_kit.panel.Panel (Omarchy's KeyboardPanel pattern).

A month grid with ISO week numbers, built to read rather than pick: today is
the only marked day and the only thing that moves is which month is on screen
(chevrons, scroll wheel, keys). Sizes and colors follow Panel.qml.
"""

import datetime as dt
import math
import subprocess

from shellder_kit import panel as P
from shellder_kit.theme import with_alpha

import model as M

# Panel.qml measurements (Style.space(n) at scale 1).
CELL_W, CELL_H, CELL_SPACING = 52, 34, 2
WEEK_COL_W, GUTTER_W = 32, 14
CONTENT_W = 560

CSS = """
.cal-hero-icon { font-size: 48px; }
.cal-hero-date { font-size: 52px; font-weight: bold; }
.cal-hero.link:hover .cal-hero-icon, .cal-hero.link:hover .cal-hero-date { color: %(accent)s; }
.cal-rail-label { font-size: %(body_small)dpx; color: %(dim15)s; letter-spacing: 1px; }
.cal-rail-value { font-size: %(body_small)dpx; }
button.cal-week-toggle { background: transparent; border: none; box-shadow: none; padding: 0;
  font-size: %(caption)dpx; font-weight: bold; color: %(dim19)s; letter-spacing: 1px;
  border-radius: %(r)dpx; min-height: 16px; font-family: "%(family)s"; }
button.cal-week-toggle:hover { background: %(hover)s; color: %(accent)s; }
.cal-weekday { font-size: %(caption)dpx; font-weight: bold; color: %(dim15)s; letter-spacing: 1px; }
.cal-week { font-size: %(caption)dpx; color: %(dim19)s; }
.cal-gutter { background: %(hairline10)s; min-width: 1px; }
.cal-day { font-size: %(body)dpx; border-radius: %(r)dpx; border: 1px solid transparent; }
.cal-day.weekend { color: %(dim145)s; }
.cal-day.out { color: %(dim22)s; }
.cal-day.today { border-color: %(accent)s; font-weight: bold; }
.cal-month { font-size: %(body)dpx; color: %(dim14)s; letter-spacing: 1px; }
"""


def locale_week_start():
    """The locale's first weekday (glibc), 0 = Sunday. Omarchy falls back to
    Qt.locale().firstDayOfWeek."""
    try:
        out = subprocess.run(["locale", "first_weekday"], capture_output=True, text=True,
                             timeout=1).stdout.strip()
        return (int(out) - 1) % 7
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1


class Rail:
    """Panel.qml's progress rail: label | bar | percent."""

    def __init__(self, panel):
        Gtk = P.Gtk
        self.panel = panel
        self.fraction = 0.0
        self.box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.label = P.label("", "cal-rail-label")
        self.value = P.label("", "cal-rail-value")
        self.track = Gtk.DrawingArea(hexpand=True, content_height=6, valign=Gtk.Align.CENTER)
        self.track.set_draw_func(self._draw)
        for w in (self.label, self.track, self.value):
            self.box.append(w)

    def set(self, label, fraction, percent):
        self.label.set_label(label)
        self.value.set_label("%d%%" % percent)
        self.fraction = fraction
        self.track.queue_draw()

    def _draw(self, area, cr, w, h):
        th = self.panel.plugin.theme
        r = h / 2 if th.radius > 0 else 0

        def bar(width, color):
            if width <= 0:
                return
            cr.set_source_rgba(*color)
            if r:
                cr.new_sub_path()
                cr.arc(width - r, r, r, -math.pi / 2, math.pi / 2)
                cr.arc(r, r, r, math.pi / 2, 3 * math.pi / 2)
                cr.close_path()
            else:
                cr.rectangle(0, 0, width, h)
            cr.fill()
        bar(w, with_alpha(th.fg, 0.12))
        bar(round(w * self.fraction), th.accent)


class CalendarPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-clock", width=CONTENT_W, css=CSS)
        self.editing_life = False
        self.today = dt.date.today()
        self.view_year, self.view_month = self.today.year, self.today.month - 1
        self.locale_start = 1

    # ---- state ------------------------------------------------------------

    @property
    def settings(self):
        return self.plugin.settings

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

    def tick(self):
        """Called every minute: rolls the day over without reopening."""
        today = dt.date.today()
        if today == self.today:
            return
        follow = self.viewing_current_month
        self.today = today
        if follow:
            self.go_to_today()
        elif self.window is not None:
            self.refresh()

    def on_open(self):
        pass

    def open(self, event):
        self.today = dt.date.today()
        self.view_year, self.view_month = self.today.year, self.today.month - 1
        super().open(event)

    def on_close(self):
        if self.editing_life:
            self.cancel_editing_life()

    # ---- build ------------------------------------------------------------

    def build(self, card):
        Gtk = P.Gtk
        self.locale_start = locale_week_start()
        card.append(self._build_hero())

        # Everything below the hero has the grid's width.
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, halign=Gtk.Align.CENTER)
        card.append(column)

        self.year_rail = Rail(self)
        self.year_rail.box.set_margin_top(6)
        P.on_click_gesture(self.year_rail.box, self.start_editing_life, presses=2)
        self.life_editor = self._build_life_editor()
        self.year_stack = Gtk.Stack()
        self.year_stack.add_named(self.year_rail.box, "rail")
        self.year_stack.add_named(self.life_editor, "edit")
        column.append(self.year_stack)

        self.life_rail = Rail(self)
        self.life_rail.box.set_tooltip_text("Memento Mori")
        P.on_click_gesture(self.life_rail.box, self.clear_life, presses=2)
        column.append(self.life_rail.box)

        column.append(self._build_grid())
        column.append(self._build_nav())

    def _build_hero(self):
        Gtk = P.Gtk
        hero = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=22, halign=Gtk.Align.CENTER)
        hero.add_css_class("cal-hero")
        hero.append(P.label("󰃭", "cal-hero-icon", valign=Gtk.Align.BASELINE))
        self.hero_date = P.label("", "cal-hero-date", valign=Gtk.Align.BASELINE)
        hero.append(self.hero_date)
        P.on_click_gesture(hero, self.go_to_today)
        self.hero = hero
        return hero

    def _build_life_editor(self):
        Gtk = P.Gtk
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10, halign=Gtk.Align.CENTER)
        row.set_margin_top(6)
        self.born_entry = Gtk.Entry(placeholder_text="year", width_chars=6, max_length=4)
        self.expectancy_entry = Gtk.Entry(placeholder_text="90", width_chars=4, max_length=3)
        for entry, other in ((self.born_entry, self.expectancy_entry),
                             (self.expectancy_entry, self.born_entry)):
            entry.add_css_class("sk-entry")
            entry.connect("activate", lambda *_: self.commit_life())
            keys = Gtk.EventControllerKey()
            keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            keys.connect("key-pressed", self._on_life_key, other)
            entry.add_controller(keys)
        row.append(P.label("BORN", "cal-rail-label"))
        row.append(self.born_entry)
        live_to = P.label("LIVE TO", "cal-rail-label")
        live_to.set_margin_start(6)
        row.append(live_to)
        row.append(self.expectancy_entry)
        return row

    def _build_grid(self):
        Gtk = P.Gtk
        grid = Gtk.Grid(column_spacing=CELL_SPACING, row_spacing=3)
        grid.set_margin_top(18)

        self.week_toggle = Gtk.Button(label="W")
        self.week_toggle.add_css_class("cal-week-toggle")
        self.week_toggle.set_size_request(WEEK_COL_W, 16)
        self.week_toggle.set_cursor_from_name("pointer")
        self.week_toggle.connect("clicked", lambda *_: self.toggle_week_start())
        grid.attach(self.week_toggle, 0, 0, 1, 1)

        spacer = Gtk.Box()
        spacer.set_size_request(GUTTER_W, 16)
        grid.attach(spacer, 1, 0, 1, 1)

        self.weekday_labels = []
        for col in range(7):
            lbl = P.label("", "cal-weekday")
            lbl.set_size_request(CELL_W, 16)
            grid.attach(lbl, 2 + col, 0, 1, 1)
            self.weekday_labels.append(lbl)

        # Hairline down the week-number gutter, only beside the day rows.
        line = Gtk.Box(halign=Gtk.Align.CENTER)
        line.add_css_class("cal-gutter")
        line.set_size_request(1, -1)
        grid.attach(line, 1, 1, 1, 6)

        self.week_labels, self.day_labels = [], []
        for row in range(6):
            wk = P.label("", "cal-week")
            wk.set_size_request(WEEK_COL_W, CELL_H)
            grid.attach(wk, 0, 1 + row, 1, 1)
            self.week_labels.append(wk)
            days = []
            for col in range(7):
                d = P.label("", "cal-day")
                d.set_size_request(CELL_W, CELL_H)
                grid.attach(d, 2 + col, 1 + row, 1, 1)
                days.append(d)
            self.day_labels.append(days)

        scroll = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.VERTICAL)
        scroll.connect("scroll", self._on_scroll)
        grid.add_controller(scroll)
        return grid

    def _build_nav(self):
        Gtk = P.Gtk
        nav = Gtk.CenterBox()
        self.month_label = P.label("", "cal-month")
        self.month_label.set_size_request(130, -1)
        nav.set_start_widget(P.action_button("󰅁", lambda: self.move_month(-1), "Previous month"))
        nav.set_center_widget(self.month_label)
        nav.set_end_widget(P.action_button("󰅂", lambda: self.move_month(1), "Next month"))
        return nav

    # ---- refresh -------------------------------------------------------------

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
        self.week_toggle.set_tooltip_text("Start weeks on " + M.DAY_LONG[M.toggled_week_start(start)])
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
        self.plugin.save_settings({"weekStartDay": M.week_start_setting_name(nxt)})
        self.refresh()

    # ---- memento mori ----------------------------------------------------------

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
        if self.window is not None:
            self.window.set_focus(None)

    def commit_life(self):
        born = M.parse_birth_year(self.born_entry.get_text(), self.today.year)
        span = M.parse_life_expectancy(self.expectancy_entry.get_text())
        if born != self.birth_year or span != self.life_expectancy:
            self.plugin.save_settings({"birthYear": born, "lifeExpectancy": span})
        self.cancel_editing_life()

    def clear_life(self):
        if self.birth_year > 0:
            self.plugin.save_settings({"birthYear": 0})
            self.refresh()

    # ---- input ------------------------------------------------------------------

    def _on_life_key(self, ctrl, keyval, keycode, state, other):
        Gdk = P.Gdk
        if keyval == Gdk.KEY_Escape:
            self.cancel_editing_life()
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab):
            other.grab_focus()
            other.select_region(0, -1)
            return True
        return False

    def on_key(self, keyval, ch):
        if self.editing_life:
            return False
        K = P.Gdk
        keys = {
            K.KEY_Left: lambda: self.move_month(-1), K.KEY_Right: lambda: self.move_month(1),
            K.KEY_Up: lambda: self.move_year(-1), K.KEY_Down: lambda: self.move_year(1),
            K.KEY_Return: self.go_to_today, K.KEY_KP_Enter: self.go_to_today,
            K.KEY_space: self.go_to_today,
        }
        chars = {
            "[": lambda: self.move_month(-1), "]": lambda: self.move_month(1),
            "{": lambda: self.move_year(-1), "}": lambda: self.move_year(1),
            "t": self.go_to_today, "T": self.go_to_today,
            "w": self.toggle_week_start, "W": self.toggle_week_start,
        }
        action = keys.get(keyval) or chars.get(ch)
        if action is None:
            return False
        action()
        return True

    def _on_scroll(self, ctrl, dx, dy):
        # Horizontal scroll (dy == 0) must not count as "next month".
        if dy == 0:
            return False
        self.move_month(1 if dy > 0 else -1)
        return True
