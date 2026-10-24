#!/usr/bin/env python3
"""shellder-bluetooth — port of omarchy.bluetooth.

Original: /usr/share/omarchy/shell/plugins/panels/bluetooth/{Panel.qml,Model.js}.

  bar          󰂯 on / 󰂱 connected / 󰂲 off
  left click   Bluetooth panel: hero with rotating phrases and a power
               switch; CONNECTED, PAIRED and AVAILABLE (while scanning)
               device rows — click connects/pairs/disconnects, the trash
               button forgets
  right click  turns Bluetooth on/off (omarchy-bluetooth-power)

BlueZ is read over D-Bus (org.bluez ObjectManager, live through
InterfacesAdded/Removed and PropertiesChanged). Discovery runs only while the
panel is open — retried every second like the original — and stops on close;
the session belongs to this process's bus connection, so it never leaks.
Actions use Omarchy's scripts: omarchy-bluetooth-device pair|connect|
disconnect|forget <address>.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from gi.repository import Gio, GLib  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

BLUEZ = "org.bluez"

CSS = """
.bt-glyph { font-size: %(title)dpx; min-width: 22px; }
.bt-status { font-size: %(body_small)dpx; color: %(dim15)s; }
.bt-status.live { color: %(fg)s; }
.bt-empty { font-size: %(body_small)dpx; color: %(dim15)s; }
"""


class BluetoothPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-bluetooth", width=380, css=CSS)
        self.phrase = 0
        self.timers = []

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        self.power = P.switch(False, self.plugin.set_power)
        box, self.hero = P.hero("󰂯", "Bluetooth", "", trailing=self.power)
        card.append(box)
        self.list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        card.append(self.list)
        self.empty = P.label("", "bt-empty", xalign=0, wrap=True)
        card.append(self.empty)

    def on_open(self):
        self.plugin.discovery(True)
        self.timers = [GLib.timeout_add(1000, self._retry_discovery),
                       GLib.timeout_add(2800, self._phrase_tick)]

    def on_close(self):
        for t in self.timers:
            GLib.source_remove(t)
        self.timers = []
        self.plugin.discovery(False)

    def _retry_discovery(self):
        # BlueZ rejects StartDiscovery while powering up, and discovery can
        # time out: keep nudging it while open.
        self.plugin.discovery(True)
        return True

    def _phrase_tick(self):
        self.phrase += 1
        self.refresh()
        return True

    def on_key(self, keyval, ch):
        if ch in ("b", "B"):
            self.plugin.set_power(not self.plugin.powered())
            return True
        return False

    def device_row(self, d, section):
        Gtk = P.Gtk
        pl = self.plugin
        pending = pl.pending.get(d.get("Address"), "")
        status = M.status_text(d, section, pending)
        st = P.label(status, "bt-status")
        if d.get("Connected") or pending:
            st.add_css_class("live")
        children = [P.label("󰂱" if d.get("Connected") else "󰂯", "bt-glyph"),
                    P.label(M.device_label(d) or "Device", xalign=0, hexpand=True, ellipsize=3), st]
        if section in ("connected", "known"):
            forget = P.action_button("󰆴", lambda d=d: pl.device_action(d, "forget"), "Forget")
            forget.set_opacity(0.0)
            children.append(forget)
        row = P.row(*children, selected=bool(d.get("Connected")),
                    tooltip=M.action_tooltip(d, section),
                    on_click=lambda d=d, s=section: pl.activate(d, s))
        if section in ("connected", "known"):
            # The forget button shows on hover, as in DeviceRow.
            motion = Gtk.EventControllerMotion()
            motion.connect("enter", lambda *_ , f=forget: f.set_opacity(1.0))
            motion.connect("leave", lambda *_ , f=forget: f.set_opacity(0.0))
            row.add_controller(motion)
        return row

    def refresh(self):
        if self.window is None:
            return
        pl = self.plugin
        adapter = pl.adapter_props()
        lists = M.device_lists(pl.devices.values())
        if adapter is None:
            meta = "No adapter"
        elif not adapter.get("Powered"):
            meta = "Turned Off"
        else:
            meta = M.PHRASES[self.phrase % len(M.PHRASES)]
        P.set_hero(self.hero, icon=M.bar_icon(adapter, len(lists["connected"])) or "󰂯", meta=meta)
        P.set_switch(self.power, pl.powered())
        self.power.set_tooltip_text("Turn Bluetooth off" if pl.powered() else "Turn Bluetooth on")
        self.power.set_sensitive(adapter is not None)

        P.clear(self.list)
        sections = [("connected", "CONNECTED"), ("known", "PAIRED")]
        if adapter and adapter.get("Discovering"):
            sections.append(("discovered", "AVAILABLE"))
        shown = 0
        for key, title in sections:
            devices = lists[key]
            if not devices:
                continue
            if shown:
                self.list.append(P.separator())
            self.list.append(P.section(title))
            for d in devices:
                self.list.append(self.device_row(d, key))
            shown += 1
        empty = shown == 0
        self.empty.set_visible(empty)
        self.empty.set_label("No Bluetooth adapter" if adapter is None else
                             "Turn Bluetooth on to scan" if not adapter.get("Powered") else
                             "Scanning for devices…")


class Bluetooth(Plugin):
    def on_start(self):
        self.devices = {}     # object path -> Device1 props (+ "Battery")
        self.adapter_path = None
        self.pending = {}     # address -> "connecting" | "disconnecting" | "forgetting"
        self.discovering_by_us = False
        self.panel = BluetoothPanel(self)
        self.manager = None
        try:
            self.manager = Gio.DBusObjectManagerClient.new_for_bus_sync(
                Gio.BusType.SYSTEM, Gio.DBusObjectManagerClientFlags.NONE, BLUEZ, "/", None, None, None)
            self.manager.connect("object-added", lambda *_: self.reload())
            self.manager.connect("object-removed", lambda *_: self.reload())
            self.manager.connect("interface-proxy-properties-changed", lambda *_: self.reload())
            self.manager.connect("interface-added", lambda *_: self.reload())
            self.manager.connect("interface-removed", lambda *_: self.reload())
        except GLib.Error as e:
            print("shellder-bluetooth: no BlueZ: %s" % e, file=sys.stderr)
        self.reload()

    # ---- BlueZ ----------------------------------------------------------------

    @staticmethod
    def props_of(proxy):
        out = {}
        for name in proxy.get_cached_property_names() or []:
            v = proxy.get_cached_property(name)
            if v is not None:
                out[name] = v.unpack()
        return out

    def reload(self):
        devices, adapter = {}, None
        if self.manager is not None:
            for obj in self.manager.get_objects():
                path = obj.get_object_path()
                a = obj.get_interface(BLUEZ + ".Adapter1")
                if a is not None and adapter is None:
                    adapter = path
                d = obj.get_interface(BLUEZ + ".Device1")
                if d is not None:
                    props = self.props_of(d)
                    bat = obj.get_interface(BLUEZ + ".Battery1")
                    if bat is not None:
                        pct = bat.get_cached_property("Percentage")
                        props["Battery"] = pct.unpack() if pct is not None else None
                    devices[path] = props
        self.devices, self.adapter_path = devices, adapter
        self.settle_pending()
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    def adapter_proxy(self):
        if self.manager is None or self.adapter_path is None:
            return None
        return self.manager.get_interface(self.adapter_path, BLUEZ + ".Adapter1")

    def adapter_props(self):
        proxy = self.adapter_proxy()
        return self.props_of(proxy) if proxy is not None else None

    def powered(self):
        a = self.adapter_props()
        return bool(a and a.get("Powered"))

    def discovery(self, on):
        proxy = self.adapter_proxy()
        if proxy is None:
            return
        a = self.props_of(proxy)
        if on and a.get("Powered") and not a.get("Discovering"):
            self.discovering_by_us = True
            proxy.call("StartDiscovery", None, Gio.DBusCallFlags.NONE, -1, None, None)
        elif not on and self.discovering_by_us:
            self.discovering_by_us = False
            proxy.call("StopDiscovery", None, Gio.DBusCallFlags.NONE, -1, None, None)

    def settle_pending(self):
        """Drop pending actions the device state already reflects."""
        by_addr = {d.get("Address"): d for d in self.devices.values()}
        for addr, action in list(self.pending.items()):
            d = by_addr.get(addr)
            if (action == "forgetting" and d is None) or \
               (action == "connecting" and d and d.get("Connected")) or \
               (action == "disconnecting" and d and not d.get("Connected")):
                del self.pending[addr]

    # ---- actions ------------------------------------------------------------------

    def set_power(self, on):
        self.run_cmd(["omarchy-bluetooth-power", "on" if on else "off"], lambda *_: self.reload())

    def device_action(self, d, action):
        addr = d.get("Address")
        if not addr:
            return
        self.pending[addr] = {"connect": "connecting", "pair": "connecting",
                              "disconnect": "disconnecting", "forget": "forgetting"}[action]
        # Give up on the spinner after 20 s, like pendingTimeout.
        self.later(20, lambda a=addr: self.pending.pop(a, None) and self.reload())
        self.run_cmd(["omarchy-bluetooth-device", action, addr], lambda *_: self.reload())
        if self.panel.opened:
            self.panel.refresh()

    def activate(self, d, section):
        if d.get("Connected"):
            self.device_action(d, "disconnect")
        elif d.get("Paired") or d.get("Bonded") or d.get("Trusted"):
            self.device_action(d, "connect")
        else:
            self.device_action(d, "pair")

    # ---- bar ------------------------------------------------------------------------

    def render(self):
        lists = M.device_lists(self.devices.values())
        icon = M.bar_icon(self.adapter_props(), len(lists["connected"]))
        self.emit(icon=icon, text="", visible=icon != "")

    def on_config(self, ev):
        self.panel.theme_changed()
        self.render()

    def on_click(self, ev):
        if ev.get("button") == "right":
            self.set_power(not self.powered())
        elif ev.get("button") == "left":
            self.panel.toggle(ev)


if __name__ == "__main__":
    Bluetooth().run()
