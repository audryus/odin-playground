"""Panels described as data and drawn by someone else — Shellder itself
(manifest barWidget.panel: "skald"), with no GUI toolkit in the plugin.

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
    """A panel Shellder draws. One per plugin; closed by Shellder on a click
    outside it or on another item (then on_close runs)."""

    def __init__(self, plugin, width=340, spacing=14):
        self.plugin = plugin
        self.width = width
        self.spacing = spacing
        self.opened = False
        self._sent = None
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
        self.opened = True
        self._sent = None
        self.refresh()
        self.on_open()

    def close(self):
        if not self.opened:
            return
        self.opened = False
        self._sent = None
        self.plugin._write({"panel": None})
        self.on_close()

    def refresh(self):
        """Send the content again (only if it changed)."""
        if not self.opened:
            return
        spec = {"width": self.width, "spacing": self.spacing, "items": [i for i in self.items() if i]}
        if spec != self._sent:
            self._sent = spec
            self.plugin._write({"panel": spec})

    def theme_changed(self):
        pass  # Shellder draws it with the current theme

    def dismiss(self):
        self._closed_by_shellder()

    # ---- events from Shellder --------------------------------------------------------

    def _event(self, ev):
        action = ev.get("action")
        if action == "closed":
            self._closed_by_shellder()
        elif action in ("click", "change", "toggle"):
            self.on_action(action, ev.get("id", ""), ev.get("value"))

    def _closed_by_shellder(self):
        if self.opened:
            self.opened = False
            self._sent = None
            self.on_close()
