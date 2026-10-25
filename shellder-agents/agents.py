#!/usr/bin/env python3
"""shellder-agents — port of omarchy.agents (AI coding subscription usage).

Original: /usr/share/omarchy/shell/plugins/agents/{Panel.qml,Main.qml,README.md}.

  bar           󱚣, in the bar's "active" color when a limit is at 90%+ or a
                prepaid balance is under 10%; hidden when no agent has data
  left click    usage dashboard: hero (agent mark, name, plan), subscription
                chips when several are enabled, LIMITS with meters and reset
                countdowns, BALANCE for prepaid agents, TOKENS BY DAY (last
                week, today bold) and TOKENS BY MODEL
  right click   omarchy-agent --pick (launch an agent)
  middle click  next subscription

Display only, like the original: it reads the records omarchy-agent-usage-update
writes to ~/.local/state/omarchy/agents/usage/*.json and runs that command every
refreshIntervalSec (default 900) and on `r`/Enter. Settings (same keys as
omarchy.agents): refreshIntervalSec, providers.<id>.enabled. Cross-device
sync (syncMode/syncDir) is not ported.
"""

import datetime as dt
import glob
import json
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from shellder_kit import loop  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                     "omarchy", "agents", "usage")
ASSETS = "/usr/share/omarchy/shell/plugins/agents/assets"
GLYPH = "󱚣"

CSS = """
.ag-mark { font-size: %(display)dpx; }
.ag-help { font-size: %(caption)dpx; color: %(dim14)s; }
.ag-row-label { font-size: %(body)dpx; }
.ag-row-value { font-size: %(caption)dpx; }
.ag-row-value.urgent { color: %(urgent)s; }
.ag-reset { font-size: %(caption)dpx; color: %(dim14)s; }
.ag-model { font-size: %(body)dpx; min-width: 120px; }
.ag-day { font-size: %(body_small)dpx; min-width: 72px; }
.ag-day.today { font-weight: bold; }
.ag-tokens { font-size: %(body_small)dpx; min-width: 56px; }
.ag-tokens.today { font-weight: bold; }
.ag-empty { font-size: %(body)dpx; color: %(dim15)s; }
"""


def meter(fraction, alarming=False, height=6):
    """A thin track + fill bar (the panel's meters)."""
    Gtk = P.Gtk
    area = Gtk.DrawingArea(hexpand=True, content_height=height, valign=Gtk.Align.CENTER)

    def draw(_a, cr, w, h):
        th = meter.theme
        fg = th.urgent if alarming else th.fg
        cr.set_source_rgba(th.fg[0], th.fg[1], th.fg[2], 0.12)
        cr.rectangle(0, 0, w, h)
        cr.fill()
        cr.set_source_rgba(*fg)
        cr.rectangle(0, 0, max(0.0, min(1.0, fraction)) * w, h)
        cr.fill()
    area.set_draw_func(draw)
    return area


class AgentsPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-agents", width=380, css=CSS)
        self.timer = None

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        self.mark = Gtk.Image(pixel_size=32)
        self.mark_glyph = P.label(GLYPH, "ag-mark")
        mark_box = Gtk.Box()
        mark_box.append(self.mark)
        mark_box.append(self.mark_glyph)
        box, self.hero = P.hero("", "", "")
        self.hero["icon"].set_visible(False)
        box.prepend(mark_box)
        card.append(box)
        self.help = P.label("", "ag-help", xalign=0, wrap=True)
        card.append(self.help)
        self.chips = Gtk.Box(spacing=4, homogeneous=True)
        card.append(self.chips)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card.append(self.body)

    def on_open(self):
        self.timer = loop.timeout_add(30000, lambda: self.refresh() or True)

    def on_close(self):
        if self.timer:
            loop.source_remove(self.timer)
            self.timer = None

    def on_key(self, keyval, ch):
        pl = self.plugin
        if ch in ("r", "R") or keyval == P.Gdk.KEY_Return:
            pl.update_records()
            return True
        if ch in ("h", "l") or keyval in (P.Gdk.KEY_Left, P.Gdk.KEY_Right):
            pl.select(pl.index + (1 if ch == "l" or keyval == P.Gdk.KEY_Right else -1))
            return True
        return False

    def section(self, title, rows):
        Gtk = P.Gtk
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.append(P.section(title))
        for r in rows:
            box.append(r)
        return box

    def refresh(self):
        if self.window is None:
            return
        Gtk = P.Gtk
        meter.theme = self.plugin.theme
        pl = self.plugin
        p = pl.provider()
        now = dt.datetime.now(dt.timezone.utc)
        P.clear(self.chips)
        P.clear(self.body)
        if p is None:
            P.set_hero(self.hero, title="Agents", meta="")
            self.help.set_visible(False)
            self.chips.set_visible(False)
            self.body.append(P.label("No AI coding subscriptions found.\nAgents show up here once you've used them.",
                                     "ag-empty", xalign=0, wrap=True))
            return

        svg = os.path.join(ASSETS, "%s.svg" % p.get("id"))
        has_svg = os.path.exists(svg)
        self.mark.set_visible(has_svg)
        self.mark_glyph.set_visible(not has_svg)
        if has_svg:
            self.mark.set_from_file(svg)
        problem = p.get("usageStatusText", "") if not p.get("ready") else ""
        P.set_hero(self.hero, title=p.get("name") or p.get("id"), meta=problem or p.get("tierLabel", ""))
        self.help.set_label(p.get("authHelpText") or "")
        self.help.set_visible(bool(p.get("authHelpText")) and (not p.get("ready") or not p.get("limits")))

        providers = pl.providers()
        self.chips.set_visible(len(providers) > 1)
        for i, q in enumerate(providers):
            b = P.button(q.get("name") or q.get("id"), lambda i=i: pl.select(i))
            if i == pl.index:
                b.add_css_class("selected")
            self.chips.append(b)

        bal = M.balance_of(p)
        if bal:
            frac = bal["remaining"] / bal["funded"] if bal["funded"] > 0 else 1.0
            detail = "" if not bal["funded"] else "%s spent of %s funded%s" % (
                M.format_money(bal["spent"], bal["currency"]), M.format_money(bal["funded"], bal["currency"]),
                " · estimated" if bal["estimated"] else "")
            rows = [self.value_row("Remaining", M.format_money(bal["remaining"], bal["currency"]),
                                   bal["funded"] > 0 and frac <= 0.1)]
            if bal["funded"] > 0:
                rows.append(meter(frac, frac <= 0.1))
            if detail:
                rows.append(P.label(detail, "ag-reset", xalign=0))
            self.body.append(self.section("BALANCE", rows))

        windows = M.limit_windows(p, now)
        if windows:
            rows = []
            for w in windows:
                alarm = w["percent"] >= 0.9
                col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
                col.append(self.value_row(w["title"], "%d%%" % round(w["percent"] * 100), alarm))
                col.append(meter(w["percent"], alarm))
                if w["reset"]:
                    col.append(P.label("Resets in " + M.format_duration((w["reset"] - now).total_seconds()),
                                       "ag-reset", xalign=0))
                rows.append(col)
            self.body.append(self.section("LIMITS", rows))

        days = (p.get("recentDays") or [])[-7:]
        if days and p.get("hasLocalStats", True):
            peak = max((M.number(d.get("messageCount")) for d in days), default=0) or 1
            rows = []
            today = dt.date.today().isoformat()
            for d in days:
                is_today = str(d.get("date"))[:10] == today
                row = Gtk.Box(spacing=10)
                name = P.label("Today" if is_today else M.day_name(d.get("date")), "ag-day", xalign=0)
                tokens = P.label(M.format_tokens(d.get("messageCount")), "ag-tokens", xalign=1)
                if is_today:
                    name.add_css_class("today")
                    tokens.add_css_class("today")
                    tip = "%s · %s tokens" % (M.day_name(d.get("date")), M.format_tokens(d.get("messageCount")))
                    if p.get("hasPromptStats", True):
                        tip += " · %d prompts · %d sessions" % (M.number(p.get("todayPrompts")),
                                                                 M.number(p.get("todaySessions")))
                    row.set_tooltip_text(tip)
                row.append(name)
                row.append(meter(M.number(d.get("messageCount")) / peak, height=8))
                row.append(tokens)
                rows.append(row)
            self.body.append(self.section("TOKENS BY DAY", rows))

        models = M.model_rows(p)
        if models:
            peak = models[0]["total"] or 1
            rows = []
            for m in models:
                row = Gtk.Box(spacing=10)
                row.append(P.label(m["name"], "ag-model", xalign=0, ellipsize=3))
                row.append(meter(m["total"] / peak, height=8))
                row.append(P.label(M.format_tokens(m["total"]), "ag-tokens", xalign=1))
                row.set_tooltip_text("Input %s · Output %s · Cache read %s · Cache write %s" % (
                    M.format_tokens(m["inputTokens"]), M.format_tokens(m["outputTokens"]),
                    M.format_tokens(m["cacheReadInputTokens"]), M.format_tokens(m["cacheCreationInputTokens"])))
                rows.append(row)
            self.body.append(self.section("TOKENS BY MODEL", rows))

    def value_row(self, label, value, alarm):
        Gtk = P.Gtk
        row = Gtk.Box(spacing=8)
        row.append(P.label(label, "ag-row-label", xalign=0, hexpand=True))
        v = P.label(value, "ag-row-value", xalign=1)
        if alarm:
            v.add_css_class("urgent")
        row.append(v)
        return row


class Agents(Plugin):
    def on_start(self):
        self.records = {}
        self.mtimes = {}
        self.index = 0
        self.selected_id = ""
        self.panel = AgentsPanel(self)
        self.update_timer = None
        self.load()
        self.every(2, self.watch)
        self.update_records()

    # ---- records ------------------------------------------------------------------

    def watch(self):
        current = {}
        for path in glob.glob(os.path.join(STATE, "*.json")):
            try:
                current[path] = os.stat(path).st_mtime
            except OSError:
                pass
        if current != self.mtimes:
            self.load()

    def load(self):
        records, mtimes = {}, {}
        for path in sorted(glob.glob(os.path.join(STATE, "*.json"))):
            try:
                mtimes[path] = os.stat(path).st_mtime
                with open(path) as f:
                    rec = json.load(f)
            except (OSError, ValueError):
                continue
            if isinstance(rec, dict) and rec.get("id"):
                records[str(rec["id"])] = rec
        self.records, self.mtimes = records, mtimes
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    def update_records(self):
        self.run_cmd(["omarchy-agent-usage-update"], lambda *_: self.load())
        if self.update_timer:
            loop.source_remove(self.update_timer)
        try:
            interval = max(60, int(self.setting("refreshIntervalSec", 900)))
        except (TypeError, ValueError):
            interval = 900
        self.update_timer = loop.timeout_add_seconds(interval, lambda: self.update_records() and False)

    def enabled(self, pid):
        providers = self.setting("providers", {}) or {}
        return (providers.get(pid) or {}).get("enabled") is not False

    def providers(self):
        return [r for pid, r in self.records.items() if self.enabled(pid) and M.has_data(r)]

    def provider(self):
        ps = self.providers()
        if not ps:
            return None
        for i, p in enumerate(ps):
            if p.get("id") == self.selected_id:
                self.index = i
                return p
        self.index = 0
        return ps[0]

    def select(self, i):
        ps = self.providers()
        if not ps:
            return
        self.index = i % len(ps)
        self.selected_id = ps[self.index].get("id", "")
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    # ---- bar ------------------------------------------------------------------------

    def render(self):
        p = self.provider()
        if p is None:
            self.emit(visible=False)
            return
        alarm = M.alarming(p, dt.datetime.now(dt.timezone.utc))
        self.emit(visible=True, icon=GLYPH, text="", color="active" if alarm else "")

    def on_config(self, ev):
        self.panel.theme_changed()
        self.render()

    def on_click(self, ev):
        button = ev.get("button")
        if button == "right":
            self.panel.close()
            self.run_detached(["omarchy-agent", "--pick"])
        elif button == "middle":
            self.select(self.index + 1)
        else:
            self.panel.toggle(ev)


if __name__ == "__main__":
    Agents().run()
