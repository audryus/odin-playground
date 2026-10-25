"""StatusNotifierItem host over D-Bus (Gio), with com.canonical.dbusmenu.

Works next to another shell: when org.kde.StatusNotifierWatcher is owned
(Omarchy's Quickshell owns it), this registers as a host and follows that
watcher's item list. When nobody owns it, this becomes the watcher; items
re-register with it on their own. The name is requested with queueing, so
it is taken over automatically when the other shell exits.
"""

import os

from gi.repository import Gio, GLib

import model as M

WATCHER = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
ITEM_IFACE = "org.kde.StatusNotifierItem"
MENU_IFACE = "com.canonical.dbusmenu"

WATCHER_XML = """
<node><interface name="org.kde.StatusNotifierWatcher">
  <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
  <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
  <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
  <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
  <property name="ProtocolVersion" type="i" access="read"/>
  <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
  <signal name="StatusNotifierHostRegistered"/>
</interface></node>
"""


def _unpack(v):
    return v.unpack() if isinstance(v, GLib.Variant) else v


class Item:
    """One StatusNotifierItem; `props` holds the SNI properties."""

    def __init__(self, host, service, bus_name, path):
        self.host = host
        self.service = service
        self.bus_name = bus_name
        self.path = path
        self.props = {}
        self.ready = False
        self._refresh_pending = False
        self.sub = host.bus.signal_subscribe(bus_name, ITEM_IFACE, None, path, None,
                                             Gio.DBusSignalFlags.NONE, self._on_signal)
        self.refresh()

    def close(self):
        self.host.bus.signal_unsubscribe(self.sub)

    # ---- properties -----------------------------------------------------------

    def _on_signal(self, *_):
        # NewIcon/NewTitle/NewStatus/NewToolTip...: re-read everything, once
        # per burst (apps send several in a row).
        if not self._refresh_pending:
            self._refresh_pending = True
            GLib.timeout_add(80, self._refresh_now)

    def _refresh_now(self):
        self._refresh_pending = False
        self.refresh()
        return False

    def refresh(self):
        self.host.bus.call(self.bus_name, self.path, "org.freedesktop.DBus.Properties", "GetAll",
                           GLib.Variant("(s)", (ITEM_IFACE,)), GLib.VariantType("(a{sv})"),
                           Gio.DBusCallFlags.NONE, 3000, None, self._got_props)

    def _got_props(self, bus, res):
        try:
            (props,) = bus.call_finish(res).unpack()
        except GLib.Error:
            if not self.ready:
                self.host.remove(self.service)
            return
        self.props = props
        self.ready = True
        self.host.changed()

    @property
    def data(self):
        """The fields the bar and Omarchy's model look at."""
        p = self.props
        tip = p.get("ToolTip") or ("", [], "", "")
        attention = p.get("Status") == "NeedsAttention"
        return {
            "service": self.service,
            "id": str(p.get("Id") or ""),
            "title": str(p.get("Title") or ""),
            "tooltipTitle": str(tip[2] if len(tip) > 2 else ""),
            "status": str(p.get("Status") or "Active"),
            "iconName": str((attention and p.get("AttentionIconName")) or p.get("IconName") or ""),
            "iconPixmap": (attention and p.get("AttentionIconPixmap")) or p.get("IconPixmap") or [],
            "iconThemePath": str(p.get("IconThemePath") or ""),
            "menu": str(p.get("Menu") or ""),
            "onlyMenu": bool(p.get("ItemIsMenu")),
        }

    # ---- actions ---------------------------------------------------------------

    def _call(self, method, args, sig):
        self.host.bus.call(self.bus_name, self.path, ITEM_IFACE, method, GLib.Variant(sig, args),
                           None, Gio.DBusCallFlags.NONE, 3000, None, lambda b, r: _finish(b, r))

    def activate(self, x, y):
        self._call("Activate", (x, y), "(ii)")

    def secondary_activate(self, x, y):
        self._call("SecondaryActivate", (x, y), "(ii)")

    def context_menu(self, x, y):
        self._call("ContextMenu", (x, y), "(ii)")

    def scroll(self, delta):
        self._call("Scroll", (delta, "vertical"), "(is)")

    # ---- dbusmenu ----------------------------------------------------------------

    def menu_layout(self, parent_id, callback):
        """AboutToShow(parent) then GetLayout(parent): callback(children) with
        children as [(id, props, children)], or None on failure."""
        menu = self.data["menu"]
        if not menu:
            callback(None)
            return

        def got(bus, res):
            try:
                _rev, (_id, _props, children) = bus.call_finish(res).unpack()
            except GLib.Error:
                callback(None)
                return
            callback([_node(c) for c in children])

        def shown(bus, res):
            _finish(bus, res)
            self.host.bus.call(self.bus_name, menu, MENU_IFACE, "GetLayout",
                               GLib.Variant("(iias)", (parent_id, -1, [])), None,
                               Gio.DBusCallFlags.NONE, 3000, None, got)
        self.host.bus.call(self.bus_name, menu, MENU_IFACE, "AboutToShow", GLib.Variant("(i)", (parent_id,)),
                           None, Gio.DBusCallFlags.NONE, 1000, None, shown)

    def menu_event(self, entry_id, event="clicked"):
        menu = self.data["menu"]
        if menu:
            self.host.bus.call(self.bus_name, menu, MENU_IFACE, "Event",
                               GLib.Variant("(isvu)", (entry_id, event, GLib.Variant("s", ""), 0)),
                               None, Gio.DBusCallFlags.NONE, 3000, None, lambda b, r: _finish(b, r))


def _node(v):
    mid, props, children = _unpack(v)
    return (mid, props, [_node(c) for c in children])


def _finish(bus, res):
    try:
        bus.call_finish(res)
    except GLib.Error:
        pass


class Host:
    """Keeps `items` ({service: Item}) in step with the watcher (external or
    our own) and calls on_change() when anything shown may have changed."""

    def __init__(self, on_change):
        self.on_change = on_change
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.items = {}
        self.order = []
        self.own_watcher = False
        self.export_id = 0
        self.watch_subs = []
        self.name_watches = {}
        self._changed_pending = False
        self.host_name = "org.kde.StatusNotifierHost-%d-shellder" % os.getpid()
        Gio.bus_own_name_on_connection(self.bus, self.host_name, Gio.BusNameOwnerFlags.NONE, None, None)
        Gio.bus_watch_name_on_connection(self.bus, WATCHER, Gio.BusNameWatcherFlags.NONE,
                                         self._watcher_appeared, self._watcher_vanished)
        # Queue for the watcher name: taken when nobody (or no longer anybody) has it.
        Gio.bus_own_name_on_connection(self.bus, WATCHER, Gio.BusNameOwnerFlags.NONE,
                                       self._acquired, self._lost)

    def changed(self):
        if not self._changed_pending:
            self._changed_pending = True
            GLib.idle_add(self._emit_changed)

    def _emit_changed(self):
        self._changed_pending = False
        self.on_change()
        return False

    def ordered(self):
        return [self.items[s] for s in self.order if s in self.items and self.items[s].ready]

    def add(self, service, sender=""):
        bus_name, path = M.parse_service(service, sender)
        key = "%s%s" % (bus_name, path)
        if not bus_name or key in self.items:
            return
        self.items[key] = Item(self, key, bus_name, path)
        self.order.append(key)
        if self.own_watcher:
            self.bus.emit_signal(None, WATCHER_PATH, WATCHER, "StatusNotifierItemRegistered",
                                 GLib.Variant("(s)", (key,)))
        if bus_name not in self.name_watches:
            self.name_watches[bus_name] = Gio.bus_watch_name_on_connection(
                self.bus, bus_name, Gio.BusNameWatcherFlags.NONE, None,
                lambda _c, name: self._name_gone(name))

    def remove(self, key):
        item = self.items.pop(key, None)
        if key in self.order:
            self.order.remove(key)
        if item is None:
            return
        item.close()
        if self.own_watcher:
            self.bus.emit_signal(None, WATCHER_PATH, WATCHER, "StatusNotifierItemUnregistered",
                                 GLib.Variant("(s)", (key,)))
        self.changed()

    def _name_gone(self, name):
        for key in [k for k, it in self.items.items() if it.bus_name == name]:
            self.remove(key)
        watch = self.name_watches.pop(name, None)
        if watch:
            Gio.bus_unwatch_name(watch)

    def clear(self):
        for key in list(self.items):
            self.remove(key)

    # ---- an external watcher --------------------------------------------------------

    def _watcher_appeared(self, conn, name, owner):
        if self.own_watcher:
            return
        for sig, fn in (("StatusNotifierItemRegistered", self.add),
                        ("StatusNotifierItemUnregistered", self._unregistered)):
            self.watch_subs.append(conn.signal_subscribe(
                owner, WATCHER, sig, WATCHER_PATH, None, Gio.DBusSignalFlags.NONE,
                lambda _c, _s, _p, _i, _n, params, fn=fn: fn(params.unpack()[0])))
        conn.call(WATCHER, WATCHER_PATH, WATCHER, "RegisterStatusNotifierHost",
                  GLib.Variant("(s)", (self.host_name,)), None, Gio.DBusCallFlags.NONE, 3000, None,
                  lambda b, r: _finish(b, r))
        conn.call(WATCHER, WATCHER_PATH, "org.freedesktop.DBus.Properties", "Get",
                  GLib.Variant("(ss)", (WATCHER, "RegisteredStatusNotifierItems")),
                  GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 3000, None, self._got_registered)

    def _got_registered(self, bus, res):
        try:
            (services,) = bus.call_finish(res).unpack()
        except GLib.Error:
            return
        for s in services:
            self.add(s)

    def _unregistered(self, service):
        bus_name, path = M.parse_service(service)
        self.remove("%s%s" % (bus_name, path))

    def _watcher_vanished(self, conn, name):
        if self.own_watcher:
            return
        for sub in self.watch_subs:
            conn.signal_unsubscribe(sub)
        self.watch_subs = []
        self.clear()

    # ---- being the watcher -------------------------------------------------------------

    def _acquired(self, conn, name):
        self.own_watcher = True
        for sub in self.watch_subs:
            conn.signal_unsubscribe(sub)
        self.watch_subs = []
        self.clear()
        info = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML).interfaces[0]
        self.export_id = conn.register_object(WATCHER_PATH, info, self._method, self._get_property, None)
        conn.emit_signal(None, WATCHER_PATH, WATCHER, "StatusNotifierHostRegistered", None)

    def _lost(self, conn, name):
        if self.own_watcher and self.export_id:
            conn.unregister_object(self.export_id)
            self.export_id = 0
            self.clear()
        self.own_watcher = False

    def _method(self, conn, sender, path, iface, method, params, invocation):
        if method == "RegisterStatusNotifierItem":
            self.add(params.unpack()[0], sender)
        invocation.return_value(None)

    def _get_property(self, conn, sender, path, iface, prop):
        if prop == "RegisteredStatusNotifierItems":
            return GLib.Variant("as", list(self.order))
        if prop == "IsStatusNotifierHostRegistered":
            return GLib.Variant("b", True)
        if prop == "ProtocolVersion":
            return GLib.Variant("i", 0)
        return None
