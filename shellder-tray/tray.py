#!/usr/bin/env python3
"""shellder-tray — port of omarchy.tray (StatusNotifierItem system tray).

Original: /usr/share/omarchy/shell/plugins/bar/widgets/{Tray.qml,TrayModel.js}.

  bar           pinned icons always; the rest sit in a drawer behind a chevron
                (\uf053) that slides open while the pointer is over it (600 ms,
                like Waybar's tray-expander); the drawer's space is reserved,
                so the bar never moves. Hidden while no item is reporting.
  icon          left: Activate (menu-only items open their menu), middle:
                SecondaryActivate, right: the item's menu, wheel: Scroll
  chevron       right click: "Tray icons" popup to pin / hide each item
  item menu     drawn by the shell like Omarchy's (dbusmenu), with check marks,
                icons and submenus drilled into in place ("‹ Title" goes back)

Settings in the shellder.tray entry (same keys as omarchy.tray): pinned,
hidden — lists of item ids. Icons follow the GTK icon theme; symbolic icons
take the bar text color.
"""

import glob
import hashlib
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from gi.repository import GLib  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402
import sni  # noqa: E402

CHEVRON = "\uf053"
ICON = 12   # Style.space(12): the icon inside its iconSlot
SCALE = 2   # pixels per logical px of the cached PNGs (sharp on HiDPI)
CACHE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "shellder-tray-%d" % os.getpid())

CSS = """
.tr-card.sk-panel { padding: 8px; border-color: %(fg45)s; }
.tr-title { font-size: %(body)dpx; font-weight: bold; }
.tr-help { font-size: %(caption)dpx; color: %(dim14)s; }
.tr-empty { font-size: %(body_small)dpx; color: %(dim15)s; font-style: italic; }
.tr-name { font-size: %(body_small)dpx; }
button.tr-small { font-size: %(body_small)dpx; padding: 3px 8px; min-height: 0; }
.tr-row { border-radius: %(r2)dpx; min-height: 30px; }
.tr-row:hover { background: %(hover)s; }
.tr-row.disabled { opacity: 0.45; }
.tr-row.disabled:hover { background: transparent; }
.tr-row label { font-size: %(body_small)dpx; }
.tr-check { min-width: 22px; }
.tr-line { min-height: 1px; background: %(border45)s; margin: 5px 10px; }
"""


class IconCache:
    """SNI icon (theme name, file or pixmap) -> PNG in CACHE, named by its
    content (the bar caches images by path)."""

    def __init__(self, plugin):
        self.plugin = plugin
        self.paths = {}
        for old in glob.glob(os.path.join(os.path.dirname(CACHE), "shellder-tray-*")):
            pid = old.rsplit("-", 1)[-1]
            if pid.isdigit() and not os.path.exists("/proc/" + pid):
                shutil.rmtree(old, ignore_errors=True)
        os.makedirs(CACHE, exist_ok=True)

    def png(self, data, size):
        GdkPixbuf = P.GdkPixbuf
        px = size * SCALE
        name = data.get("iconName", "")
        pixbuf = None
        if name:
            pixbuf = self._from_name(name, data.get("iconThemePath", ""), px)
        if pixbuf is None:
            pm = M.best_pixmap(data.get("iconPixmap"), px)
            if pm:
                w, h, argb = pm
                rgba = M.argb_to_rgba(argb[:w * h * 4])
                pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(rgba), GdkPixbuf.Colorspace.RGB,
                                                         True, 8, w, h, w * 4)
        if pixbuf is None:
            return ""
        if pixbuf.get_width() != px or pixbuf.get_height() != px:
            w, h = pixbuf.get_width(), pixbuf.get_height()
            k = px / max(w, h)
            pixbuf = pixbuf.scale_simple(max(1, round(w * k)), max(1, round(h * k)),
                                         GdkPixbuf.InterpType.BILINEAR)
        if not pixbuf.get_has_alpha():
            pixbuf = pixbuf.add_alpha(False, 0, 0, 0)
        if M.is_symbolic(name):
            fg = self.plugin.theme.bar_text
            rgba = M.tint_rgba(pixbuf.get_pixels(), tuple(round(c * 255) for c in fg[:3]))
            pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(
                GLib.Bytes.new(rgba), GdkPixbuf.Colorspace.RGB, True, 8,
                pixbuf.get_width(), pixbuf.get_height(), pixbuf.get_rowstride())
        ok, buf = pixbuf.save_to_bufferv("png", [], [])
        if not ok:
            return ""
        path = os.path.join(CACHE, hashlib.sha1(buf).hexdigest()[:16] + ".png")
        if not os.path.exists(path):
            with open(path + ".tmp", "wb") as f:
                f.write(buf)
            os.replace(path + ".tmp", path)
        return path

    def _from_name(self, name, theme_path, px):
        GdkPixbuf, Gtk = P.GdkPixbuf, P.Gtk
        file = None
        if os.path.isabs(name) and os.path.exists(name):
            file = name
        else:
            theme = Gtk.IconTheme.get_for_display(P.Gdk.Display.get_default())
            if theme_path and theme_path not in theme.get_search_path():
                theme.add_search_path(theme_path)
            if theme_path:
                for ext in (".png", ".svg"):
                    for cand in glob.glob(os.path.join(theme_path, "**", name + ext), recursive=True):
                        file = cand
                        break
                    if file:
                        break
            if file is None and theme.has_icon(name):
                paintable = theme.lookup_icon(name, None, px, 1, Gtk.TextDirection.NONE, 0)
                f = paintable.get_file() if paintable else None
                file = f.get_path() if f else None
        if not file:
            return None
        try:
            return GdkPixbuf.Pixbuf.new_from_file_at_size(file, px, px)
        except GLib.Error:
            return None


class ManagePopup(P.Panel):
    """The chevron's right-click popup: "Tray icons", pin / hide per item."""

    def __init__(self, plugin):
        super().__init__(plugin, "shellder-tray-manage", width=300, css=plugin.css)

    def build(self, card):
        card.append(P.label("Tray icons", "tr-title", xalign=0))
        card.append(P.label("Pinned icons stay visible. Hidden icons never show.",
                            "tr-help", xalign=0, wrap=True, max_width_chars=40))
        self.rows = P.Gtk.Box(orientation=P.Gtk.Orientation.VERTICAL, spacing=8)
        card.append(self.rows)

    def refresh(self):
        if self.window is None:
            return
        Gtk = P.Gtk
        pl = self.plugin
        P.clear(self.rows)
        _, _, every = pl.buckets()
        if not every:
            self.rows.append(P.label("No tray items reporting.", "tr-empty", xalign=0))
        for data in every:
            iid = data.get("id", "")
            row = Gtk.Box(spacing=10, height_request=28)
            img = Gtk.Image(pixel_size=16)
            path = pl.icon_path(data)
            if path:
                img.set_from_file(path)
            row.append(img)
            row.append(P.label(M.display_name(data), "tr-name", xalign=0, hexpand=True, ellipsize=3))
            hide = P.button("\uf06e  " + ("Show" if iid in pl.hidden else "Hide"),
                            lambda iid=iid: pl.set_lists(*M.toggle_hide(iid, pl.pinned, pl.hidden)))
            pin = P.button("\uf08d  " + ("Unpin" if iid in pl.pinned else "Pin"),
                           lambda iid=iid: pl.set_lists(*M.toggle_pin(iid, pl.pinned, pl.hidden)))
            for b in (hide, pin):
                b.add_css_class("tr-small")
                b.set_valign(Gtk.Align.CENTER)
                row.append(b)
            self.rows.append(row)


class TrayMenu(P.Panel):
    """An item's dbusmenu, drawn like Omarchy's tray menu card."""

    SETTLE_MS = 250  # ignore row clicks right after a level change

    def __init__(self, plugin):
        super().__init__(plugin, "shellder-tray-menu", width=232, css=plugin.css)
        self.item = None
        self.stack = []       # [(entry id, title)] of the drilled-into submenus
        self.entries = []
        self.settle_until = 0.0

    def build(self, card):
        Gtk = P.Gtk
        card.add_css_class("tr-card")
        card.set_spacing(0)
        self.header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        back = Gtk.Box(spacing=0)
        back.add_css_class("tr-row")
        back.append(P.label("‹", "tr-check", xalign=0.5))
        self.back_title = P.label("", xalign=0, hexpand=True, ellipsize=3, margin_start=6, margin_end=10)
        back.append(self.back_title)
        P.on_click_gesture(back, self.leave)
        back.set_cursor_from_name("pointer")
        self.header.append(back)
        line = Gtk.Box()
        line.add_css_class("tr-line")
        self.header.append(line)
        card.append(self.header)
        self.scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                         propagate_natural_height=True, max_content_height=420)
        self.list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.scroll.set_child(self.list)
        card.append(self.scroll)

    def show_for(self, item, event):
        self.item = item
        self.stack = []
        self.entries = []
        self.event = event
        item.menu_layout(0, lambda rows: self._loaded(rows, event, first=True))

    def _loaded(self, rows, event, first=False):
        if rows is None:
            if first:  # no usable dbusmenu: let the app show its own
                self.item.context_menu(*self.plugin.screen_point(event))
            return
        self.entries = rows
        if first and not self.opened:
            self.open(event)
        else:
            self.refresh()
            self._place(self.event)
        self.scroll.get_vadjustment().set_value(0)

    def refresh(self):
        if self.window is None or self.item is None:
            return
        Gtk = P.Gtk
        self.header.set_visible(bool(self.stack))
        self.back_title.set_label(self.stack[-1][1] if self.stack else "")
        P.clear(self.list)
        title = self.item.data.get("title") or self.item.data.get("id")
        for r in M.menu_entries(self.entries, not self.stack, title):
            if r["separator"]:
                line = Gtk.Box()
                line.add_css_class("tr-line")
                self.list.append(line)
                continue
            row = Gtk.Box(spacing=0)
            row.add_css_class("tr-row")
            check = P.label("\uf00c" if r["toggle"] and r["checked"] else "", "tr-check", xalign=0.5)
            row.append(check)
            icon = self._entry_icon(r)
            if icon is not None:
                icon.set_margin_start(2)
                row.append(icon)
            row.append(P.label(r["text"], xalign=0, hexpand=True, ellipsize=3,
                               margin_start=6, margin_end=8))
            if r["hasChildren"]:
                row.append(P.label("›", margin_end=10))
            if r["enabled"]:
                row.set_cursor_from_name("pointer")
                P.on_click_gesture(row, lambda r=r: self.activate(r))
            else:
                row.add_css_class("disabled")
            self.list.append(row)

    def _entry_icon(self, r):
        Gtk, GdkPixbuf = P.Gtk, P.GdkPixbuf
        if r["iconData"]:
            loader = GdkPixbuf.PixbufLoader()
            try:
                loader.write(r["iconData"])
                loader.close()
                img = Gtk.Image.new_from_pixbuf(loader.get_pixbuf())
            except GLib.Error:
                return None
        elif r["icon"]:
            img = Gtk.Image.new_from_icon_name(r["icon"])
        else:
            return None
        img.set_pixel_size(16)
        return img

    def activate(self, r):
        if time.monotonic() < self.settle_until or self.item is None:
            return
        if r["hasChildren"]:
            self.stack.append((r["id"], r["text"]))
            self._settle()
            if r["children"]:
                self._loaded(r["children"], self.event)
            else:
                self.item.menu_layout(r["id"], lambda rows: self._loaded(rows or [], self.event))
            return
        self.item.menu_event(r["id"])
        self.close()

    def leave(self):
        if time.monotonic() < self.settle_until or not self.stack:
            return
        self.stack.pop()
        self._settle()
        parent = self.stack[-1][0] if self.stack else 0
        self.item.menu_layout(parent, lambda rows: self._loaded(rows or [], self.event))

    def _settle(self):
        self.settle_until = time.monotonic() + self.SETTLE_MS / 1000

    def on_close(self):
        self.item = None
        self.stack = []


class Tray(Plugin):
    def on_start(self):
        self.css = CSS
        self.pinned, self.hidden = [], []
        self.read_lists()
        self.icons = {}         # service -> (icon key, png path)
        self.cache = None
        self.expanded = {}      # monitor -> pointer over the chevron/drawer
        self.progress = {}      # monitor -> drawer reveal 0..1
        self.anim = {}          # monitor -> (from, to, start time)
        self.anim_timer = None
        self.manage = ManagePopup(self)
        self.menu = TrayMenu(self)
        self.monitors = []
        self.host = sni.Host(self.render)

    # ---- settings ---------------------------------------------------------------

    def read_lists(self):
        lists = []
        for key in ("pinned", "hidden"):
            v = self.setting(key, [])
            lists.append([str(x) for x in v] if isinstance(v, list) else [])
        self.pinned, self.hidden = lists

    def set_lists(self, pinned, hidden):
        self.pinned, self.hidden = pinned, hidden
        self.save_settings({"pinned": pinned, "hidden": hidden})
        self.render()
        self.manage.refresh()

    def buckets(self):
        return M.buckets([it.data for it in self.host.ordered()], self.pinned, self.hidden)

    # ---- icons ----------------------------------------------------------------------

    def icon_path(self, data):
        if self.cache is None:
            if not P.import_gtk():
                return ""
            self.cache = IconCache(self)
        fg = tuple(round(c, 3) for c in self.theme.bar_text) if M.is_symbolic(data.get("iconName")) else ()
        pm = data.get("iconPixmap") or []
        key = (data.get("iconName"), data.get("iconThemePath"),
               tuple((w, h, hashlib.sha1(bytes(b)).digest()) for w, h, b in pm), fg)
        cached = self.icons.get(data["service"])
        if cached and cached[0] == key:
            return cached[1]
        path = self.cache.png(data, ICON)
        self.icons[data["service"]] = (key, path)
        return path

    # ---- bar ---------------------------------------------------------------------------

    def segment(self, data):
        seg = {"id": data["service"], "width": self.theme.bar_token("iconSlot", 22),
               "tooltip": M.tooltip(data)}
        path = self.icon_path(data)
        if path:
            seg.update(image=path, imageSize=ICON)
        else:
            seg.update(icon="\uf2d0", font="bodySmall")  # no icon at all: a window glyph
        return seg

    def render(self):
        pinned, drawer, every = self.buckets()
        for gone in set(self.icons) - {d["service"] for d in every}:
            self.icons.pop(gone, None)
        if not pinned and not drawer:
            self.emit(visible=False)
            if self.menu.opened and self.menu.item and self.menu.item.service not in self.host.items:
                self.menu.close()
            return
        extent = self.theme.bar_token("iconSlot", 22)
        drawer_segs = [self.segment(d) for d in drawer]
        pinned_segs = [self.segment(d) for d in pinned]
        # The base view (every output) plus one per output the pointer has
        # visited, each with its own drawer state.
        for mon in [None] + self.monitors:
            segs = []
            if every:
                lead, shown, trail = M.drawer_layout(len(drawer), extent, self.progress.get(mon, 0.0))
                if lead > 0.5:
                    segs.append({"id": "lead", "passive": True, "width": lead})
                segs.append({"id": "chevron", "icon": CHEVRON, "width": extent})
                segs.extend(drawer_segs[:shown])
                if trail > 0.5:
                    # Not passive: it is the partly revealed drawer, under the
                    # pointer while the chevron slides away from it.
                    segs.append({"id": "trail", "width": trail})
            segs.extend(pinned_segs)
            self.emit(monitor=mon, visible=True, segments=segs)
        if self.menu.opened and self.menu.item and self.menu.item.service not in self.host.items:
            self.menu.close()
        if self.manage.opened:
            self.manage.refresh()

    # ---- drawer animation ----------------------------------------------------------------

    def set_expanded(self, mon, value):
        if self.expanded.get(mon) == value:
            return
        self.expanded[mon] = value
        self.anim[mon] = (self.progress.get(mon, 0.0), 1.0 if value else 0.0, time.monotonic())
        if self.anim_timer is None:
            self.anim_timer = GLib.timeout_add(16, self.tick)

    def tick(self):
        now = time.monotonic()
        for mon, (start, target, t0) in list(self.anim.items()):
            t = (now - t0) * 1000 / M.ANIMATION_MS
            self.progress[mon] = start + (target - start) * M.ease_out_cubic(t)
            if t >= 1:
                self.progress[mon] = target
                del self.anim[mon]
        self.render()
        if not self.anim:
            self.anim_timer = None
            return False
        return True

    # ---- events -------------------------------------------------------------------------------

    def on_config(self, ev):
        self.read_lists()
        self.icons = {}  # bar text color may have changed (symbolic icons)
        self.manage.theme_changed()
        self.menu.theme_changed()
        self.render()

    def on_hover(self, ev):
        mon = ev.get("monitor")
        if mon not in self.monitors:
            self.monitors.append(mon)
        seg = ev.get("segment", "")
        drawer = {d["service"] for d in self.buckets()[1]}
        self.set_expanded(mon, bool(ev.get("hovered")) and (seg in ("chevron", "trail") or seg in drawer))

    def screen_point(self, ev):
        """The click point in global coordinates (SNI Activate/ContextMenu)."""
        item, bar = ev.get("item", {}), ev.get("bar", {})
        x = item.get("x", 0) + item.get("width", 0) // 2
        y = item.get("y", 0) + item.get("height", 0) // 2
        try:
            mons = json.loads(GLib.spawn_command_line_sync("hyprctl monitors -j")[1] or b"[]")
        except GLib.Error:
            mons = []
        for m in mons:
            if m.get("name") != ev.get("monitor"):
                continue
            scale = m.get("scale") or 1
            w, h = round(m["width"] / scale), round(m["height"] / scale)
            pos = bar.get("position", "bottom")
            ox = m["x"] + (w - bar.get("width", 0) if pos == "right" else 0)
            oy = m["y"] + (h - bar.get("height", 0) if pos == "bottom" else 0)
            return ox + x, oy + y
        return x, y

    def item_for(self, ev):
        return self.host.items.get(ev.get("segment", ""))

    def on_click(self, ev):
        button, seg = ev.get("button"), ev.get("segment", "")
        if seg == "chevron":
            if button == "right":
                self.menu.close()
                self.manage.toggle(ev)
            return
        item = self.item_for(ev)
        if item is None:
            return
        self.manage.close()
        data = item.data
        if button == "right" or (button == "left" and data["onlyMenu"]):
            if self.menu.opened and self.menu.item is item:
                self.menu.close()
            elif data["menu"]:
                self.menu.close()
                self.menu.show_for(item, ev)
            else:
                item.context_menu(*self.screen_point(ev))
        elif button == "middle":
            item.secondary_activate(*self.screen_point(ev))
        else:
            item.activate(*self.screen_point(ev))

    def on_scroll(self, ev):
        item = self.item_for(ev)
        if item is not None:
            item.scroll(120 if ev.get("direction") == "up" else -120)


if __name__ == "__main__":
    Tray().run()
