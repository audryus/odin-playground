"""Panels described as data and drawn by someone else. The manifest's
barWidget.panel picks who, with no change to the plugin:

  "skald"    Shellder itself: no GUI toolkit in the plugin at all
  "process"  a GTK child process born on open and gone on close
             (shellder_kit.panel_process): GTK costs memory only while open
  "plugin"   GTK in the plugin's own process (shellder_kit.gtk_nodes)

    from shellder_kit import nodes as N

    class AudioPanel(N.SkaldPanel):
        def items(self):                      # the whole content, as nodes
            return [N.hero("\\uf028", "Audio", meta="Steady groove",
                           switch=N.switch("master", True)),
                    N.separator(),
                    N.section("OUTPUT", "57%"),
                    N.slider("volume", 0.57, step=0.01)]
        def on_action(self, action, id, value):  # "click" / "change" / "toggle"
            ...

    self.panel = AudioPanel(self, width=380)
    self.panel.toggle(click_event)            # from on_click
    self.panel.refresh()                      # whenever the state changes

Node types: hero, section, separator, slider, row, label, group (same look
as the kit's GTK widgets). See Shellder's README for every field.
"""

import json
import os
import sys

from . import loop


def hero(icon, title, meta="", switch=None):
    n = {"type": "hero", "icon": icon, "title": title, "meta": meta}
    if switch is not None:
        n["switch"] = switch
    return n


def switch(id, on):
    return {"id": id, "on": bool(on)}


def section(text, value=""):
    return {"type": "section", "text": text, "value": value}


def separator():
    return {"type": "separator"}


def slider(id, value, minimum=0.0, maximum=1.0, step=0.0):
    return {"type": "slider", "id": id, "value": value, "min": minimum, "max": maximum, "step": step}


def row(text, id=None, icon="", trailing="", value="", selected=False, disabled=False,
        action=None, plain=False):
    """A list row (clickable when it has an id), or with plain=True a line of
    content without padding or hover. `action` is an icon button: action()."""
    n = {"type": "row", "text": text}
    for k, v in (("id", id), ("icon", icon), ("trailing", trailing), ("value", value),
                 ("selected", selected), ("disabled", disabled), ("action", action), ("plain", plain)):
        if v:
            n[k] = v
    return n


def action(id, icon):
    return {"id": id, "icon": icon}


def label(text, style=""):
    """style: "", "dim", "caption", "small", "title" or "bold"."""
    return {"type": "label", "text": text, "style": style}


def group(items, spacing=6):
    return {"type": "group", "items": [i for i in items if i], "spacing": spacing}


class SkaldPanel:
    """A panel described as nodes, drawn as the manifest's barWidget.panel
    says. One per plugin; closed on a click outside it or on another item
    (then on_close runs)."""

    def __init__(self, plugin, width=340, spacing=14):
        self.plugin = plugin
        self.width = width
        self.spacing = spacing
        self.opened = False
        self._sent = None
        self._mode = None   # the mode it was opened in
        self._gtk = None    # "plugin": the gtk_nodes.NodesPanel
        self._child = None  # "process": the plugin.Proc
        self._theme = None  # theme data the drawer last got
        plugin._popups.append(self)
        plugin._panel = self

    # ---- override ----------------------------------------------------------------

    def items(self):
        return []

    def on_action(self, action, id, value):
        """action: "click" (row/action id), "change" (slider, value float),
        "toggle" (switch, value bool)."""

    def on_open(self):
        pass

    def on_close(self):
        pass

    # ---- API -------------------------------------------------------------------------

    def toggle(self, event=None):
        if self.opened:
            self.close()
        else:
            self.open(event)

    def open(self, event=None):
        mode = self.plugin.panel_mode
        if mode not in ("skald", "process", "plugin"):
            mode = "skald"
        self._mode = mode
        self.opened = True
        self._sent = None
        spec = self._spec()
        if mode == "skald":
            self._sent = spec
            self.plugin._write({"panel": spec})
        elif mode == "process":
            if not self._spawn(event or {}, spec):
                self.opened = False
                return
        else:
            if not self._open_gtk(event or {}, spec):
                self.opened = False
                return
        self.on_open()

    def close(self):
        if not self.opened:
            return
        if self._mode == "skald":
            self.plugin._write({"panel": None})
        elif self._mode == "process":
            self._stop_child()
        elif self._gtk is not None:
            gtk, self._gtk = self._gtk, None
            gtk.close()  # its on_closed finds self._gtk gone: no second on_close
        self._closed()

    def refresh(self):
        """Send the content again (only if it changed)."""
        if not self.opened:
            return
        spec = self._spec()
        if spec == self._sent:
            return
        self._sent = spec
        if self._mode == "skald":
            self.plugin._write({"panel": spec})
        elif self._mode == "process":
            self._sync_theme()
            self._to_child({"spec": spec})
        elif self._gtk is not None:
            self._sync_theme()
            self._gtk.set_spec(spec)

    def theme_changed(self):
        if self.opened:
            self._sync_theme()

    def dismiss(self):
        """Another bar item was clicked. Shellder closes its own drawing; the
        other modes close here."""
        if self._mode == "skald":
            self._closed()
        else:
            self.close()

    # ---- internals -----------------------------------------------------------------

    def _spec(self):
        return {"width": self.width, "spacing": self.spacing, "items": [i for i in self.items() if i]}

    def _namespace(self):
        return "shellder-panel-" + self.plugin.name()

    def _closed(self):
        if self.opened:
            self.opened = False
            self._sent = None
            self.on_close()

    def _sync_theme(self):
        raw = self.plugin.theme.raw
        if raw == self._theme:
            return
        self._theme = raw
        if self._mode == "process":
            self._to_child({"theme": raw})
        elif self._gtk is not None:
            self._gtk.theme_changed()

    # "plugin": GTK in this process.

    def _open_gtk(self, event, spec):
        from . import gtk_nodes

        def closed():
            if self._gtk is not None:  # closed by GTK (Esc, a click outside)
                self._gtk = None
                self._closed()
        if self._gtk is None:
            self._gtk = gtk_nodes.NodesPanel(self.plugin, self._namespace(), self.on_action, closed)
            self.plugin._popups.remove(self._gtk)  # dismissed through this panel
        self._gtk.spec = spec
        self._theme = self.plugin.theme.raw
        self._sent = spec
        self._gtk.open(event)
        return self._gtk.opened

    # "process": GTK in a child that lives while the panel is open.

    def _spawn(self, event, spec):
        kit = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        env = dict(os.environ)
        env["PYTHONPATH"] = kit + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        holder = []

        def line(text):
            if holder and self._child is holder[0]:
                self._from_child(text)

        def exited():
            if holder and self._child is holder[0]:
                self._child = None  # exited (or crashed): the panel is gone
                self._closed()
        child = self.plugin.watch_lines([sys.executable, "-u", "-m", "shellder_kit.panel_process",
                                         self._namespace()], line, exited, stdin=True, env=env)
        if child is None:
            return False
        holder.append(child)
        self._child = child
        self._theme = self.plugin.theme.raw
        self._sent = spec
        self._to_child({"open": {"event": event, "theme": self._theme, "spec": spec}})
        return True

    def _from_child(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        action = msg.get("action")
        if action == "closed":
            self._child = None  # it exits by itself
            self._closed()
        elif action in ("click", "change", "toggle"):
            self.on_action(action, msg.get("id", ""), msg.get("value"))

    def _to_child(self, obj):
        if self._child is None:
            return
        data = (json.dumps(obj, ensure_ascii=False) + "\n").encode()
        try:
            self._child.popen.stdin.write(data)
            self._child.popen.stdin.flush()
        except OSError:
            pass  # exiting: its stdout EOF closes the panel

    def _stop_child(self):
        child, self._child = self._child, None
        if child is None:
            return
        try:
            child.popen.stdin.write(b'{"close": true}\n')
            child.popen.stdin.close()
        except OSError:
            pass
        # It exits at once; make sure a stuck one does not linger.
        loop.timeout_add(2000, lambda: child.force_exit() and False)

    # ---- events from Shellder --------------------------------------------------------

    def _event(self, ev):
        action = ev.get("action")
        if action == "closed":
            self._closed_by_shellder()
        elif action in ("click", "change", "toggle"):
            self.on_action(action, ev.get("id", ""), ev.get("value"))

    def _closed_by_shellder(self):
        if self._mode == "skald":
            self._closed()
