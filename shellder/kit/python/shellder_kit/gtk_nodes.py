"""Panel nodes (shellder_kit.nodes) drawn with GTK4, in the same look as
Shellder's own drawing. Used by the manifest's other two panel modes:

  "plugin"   in the plugin's process (GTK loaded there)
  "process"  in a short-lived child (shellder_kit.panel_process) that is
             born on open and exits on close, so the plugin stays GTK-free

An update with the same structure (node types, ids, optional parts) changes
the widgets in place, so a slider being dragged keeps its grab; anything
else rebuilds the card.
"""

from . import panel as P

CSS = """
.sk-subtitle { font-size: %(subtitle)dpx; }
.sk-row-icon { font-size: %(title)dpx; }
.sk-row.plain, .sk-row.plain:hover { padding: 0; background: transparent; border-color: transparent; }
.sk-row.disabled label { color: %(dim19)s; }
"""

CHANGE_INTERVAL = 40   # ms between slider "change"s while dragging, like Shellder
SETTLE = 400           # ms after a user change during which updates leave a slider alone

LABEL_STYLES = {
    "dim": ("sk-dim",), "caption": ("sk-caption", "sk-dim"), "small": ("sk-small",),
    "title": ("sk-title", "sk-bold"), "bold": ("sk-bold",),
}


def shape(node):
    """What must match for an in-place update."""
    if isinstance(node, list):
        return tuple(shape(n) for n in node if n)
    t = node.get("type")
    if t == "group":
        return (t, shape(node.get("items") or []))
    if t == "hero":
        sw = node.get("switch")
        return (t, bool(node.get("icon")), sw.get("id") if sw else None)
    if t == "slider":
        return (t, node.get("id"), node.get("min", 0), node.get("max", 1), node.get("step", 0))
    if t == "row":
        act = node.get("action")
        return (t, node.get("id"), bool(node.get("icon")), act.get("id") if act else None,
                bool(node.get("plain")))
    if t == "label":
        return (t, node.get("style", ""))
    return (t,)


def flatten(nodes, out):
    for n in nodes:
        if not n:
            continue
        out.append(n)
        if n.get("type") == "group":
            flatten(n.get("items") or [], out)
    return out


class NodesPanel(P.Panel):
    """A P.Panel whose content is a node spec ({"width", "spacing", "items"}).
    on_action(action, id, value) as in nodes.SkaldPanel; on_closed() when it
    closes (Esc, a click outside, close())."""

    def __init__(self, host, namespace, on_action, on_closed):
        super().__init__(host, namespace, css=CSS)
        self.on_action = on_action
        self.on_closed = on_closed
        self.spec = {}
        self._shape = None
        self._updaters = []  # one per flattened node, in walk order

    # ---- P.Panel ------------------------------------------------------------

    def build(self, card):
        self._shape = None
        self._render()

    def on_close(self):
        self._shape = None
        self._updaters = []
        self.on_closed()

    # ---- content --------------------------------------------------------------

    def set_spec(self, spec):
        self.spec = spec or {}
        if self.card is not None:
            self._render()

    def _render(self):
        items = [i for i in self.spec.get("items") or [] if i]
        new_shape = shape(items)
        if new_shape == self._shape:
            for fn, node in zip(self._updaters, flatten(items, [])):
                fn(node)
            return
        card = self.card
        P.clear(card)
        card.set_spacing(int(self.spec.get("spacing", 14)))
        width = int(self.spec.get("width", 340))
        # The card's CSS padding and border are inside the size request.
        card.set_size_request(width, -1)
        self._updaters = []
        for n in items:
            card.append(self._node(n))
        self._shape = new_shape
        if self.opened and self.event is not None:
            self._place(self.event)

    def _node(self, n):
        t = n.get("type")
        builder = getattr(self, "_" + str(t), None)
        if builder is None:
            self._updaters.append(lambda node: None)
            return P.Gtk.Box()
        return builder(n)

    def _separator(self, n):
        self._updaters.append(lambda node: None)
        return P.separator()

    def _section(self, n):
        box = P.Gtk.Box(spacing=8)
        text = P.label(n.get("text", ""), "sk-section", xalign=0, hexpand=True)
        value = P.label(n.get("value", ""), "sk-section")
        box.append(text)
        box.append(value)

        def update(node):
            text.set_label(node.get("text", ""))
            value.set_label(node.get("value", ""))
        self._updaters.append(update)
        return box

    def _label(self, n):
        lbl = P.label(n.get("text", ""), *LABEL_STYLES.get(n.get("style", ""), ()), xalign=0)
        lbl.set_ellipsize(3)  # END
        self._updaters.append(lambda node: lbl.set_label(node.get("text", "")))
        return lbl

    def _group(self, n):
        box = P.Gtk.Box(orientation=P.Gtk.Orientation.VERTICAL, spacing=int(n.get("spacing", 6)))
        self._updaters.append(lambda node: None)
        for child in n.get("items") or []:
            if child:
                box.append(self._node(child))
        return box

    def _hero(self, n):
        sw_node = n.get("switch")
        sw = None
        if sw_node:
            sid = sw_node.get("id", "")
            sw = P.switch(sw_node.get("on"), lambda on: self.on_action("toggle", sid, on))
        box, w = P.hero(n.get("icon", ""), n.get("title", ""), n.get("meta", ""), trailing=sw)

        def update(node):
            P.set_hero(w, icon=node.get("icon", ""), title=node.get("title", ""),
                       meta=node.get("meta", ""))
            if sw is not None and node.get("switch"):
                P.set_switch(sw, node["switch"].get("on"))
        self._updaters.append(update)
        return box

    def _slider(self, n):
        sid = n.get("id", "")
        lo, hi = float(n.get("min", 0)), float(n.get("max", 1))
        step = float(n.get("step", 0)) or (hi - lo) / 1000
        state = {"pending": None, "timer": None, "sent": None, "at": 0}

        def flush():
            state["timer"] = None
            v = state["pending"]
            if v is not None and v != state["sent"]:
                state["sent"] = v
                self.on_action("change", sid, v)
            return False

        def changed(v):
            state["pending"] = v
            state["at"] = P.GLib.get_monotonic_time()
            if state["timer"] is None:
                flush()  # the first one right away, then at most every 40 ms
                state["timer"] = P.GLib.timeout_add(CHANGE_INTERVAL, flush)

        sc = P.slider(float(n.get("value", lo)), changed, lo, hi, step)

        def update(node):
            if P.GLib.get_monotonic_time() - state["at"] < SETTLE * 1000:
                return  # the user is moving it: keep their value
            P.set_slider(sc, float(node.get("value", lo)))
        self._updaters.append(update)
        return sc

    def _row(self, n):
        rid = n.get("id")
        plain = bool(n.get("plain"))
        cells = []
        act = n.get("action")
        act_btn = None
        if act:
            aid = act.get("id", "")
            act_btn = P.action_button(act.get("icon", ""), lambda: self.on_action("click", aid, None))
            cells.append(act_btn)
        icon = None
        if n.get("icon"):
            icon = P.label(n["icon"], "sk-row-icon", xalign=0.5)
            icon.set_size_request(22, -1)
            cells.append(icon)
        text = P.label(n.get("text", ""), xalign=0, hexpand=True)
        text.set_ellipsize(3)
        cells.append(text)
        value = P.label(n.get("value", ""), "sk-small", "sk-dim")
        trailing = P.label(n.get("trailing", ""), "sk-subtitle")
        cells += [value, trailing]
        state = {"disabled": bool(n.get("disabled"))}

        def click():
            if not state["disabled"]:
                self.on_action("click", rid, None)
        box = P.row(*cells, on_click=click if rid else None, selected=bool(n.get("selected")))
        if plain:
            box.add_css_class("plain")
            box.set_size_request(-1, 24)
        else:
            box.set_size_request(-1, 34)

        def update(node):
            if icon is not None:
                icon.set_label(node.get("icon", ""))
            if act_btn is not None:
                act_btn.set_label(node["action"].get("icon", ""))
            text.set_label(node.get("text", ""))
            for lbl, key in ((value, "value"), (trailing, "trailing")):
                lbl.set_label(node.get(key, ""))
                lbl.set_visible(bool(node.get(key)))
            for cls, on in (("selected", node.get("selected")), ("disabled", node.get("disabled"))):
                (box.add_css_class if on else box.remove_css_class)(cls)
            state["disabled"] = bool(node.get("disabled"))
        update(n)
        self._updaters.append(update)
        return box
