#!/usr/bin/env python3
"""shellder-network panel — the Network panel of omarchy.network, as its own
process (manifest barWidget.panel: "process", entryPoints.panel).

Original: /usr/share/omarchy/shell/plugins/panels/network/{Panel.qml,Model.js}.

Shellder starts this program on a left click on the bar item and ends it on
the next click or when another popup opens; it exits when the panel closes
(Esc, a click outside). GTK is loaded only here, so it costs memory only
while the panel is on screen; network.py (the bar) has no toolkit.

  hero (connection name + speed, rotating phrases, QR share / speed test /
  Wi-Fi switch), ping, packet loss, rates, totals, IP and gateway (click
  copies), Wi-Fi band selector, DNS provider pills (omarchy-dns), and the
  Wi-Fi network list with connect / passphrase prompt / disconnect / forget

While open, details come from omarchy-network-status --verbose every 1.5 s
and the band from omarchy-network-band every 4 s, as in the original; Wi-Fi
goes through nmcli, refreshed on `nmcli monitor` events. QR sharing and the
speed test summon Omarchy's own overlays (omarchy-shell).
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from shellder_kit import loop  # noqa: E402

from shellder_kit import PanelApp  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

CSS = """
.net-label { font-size: %(body_small)dpx; opacity: 0.6; }
.net-value { font-size: %(body_small)dpx; }
.net-value.copy:hover { color: %(accent)s; }
button.net-pill { font-size: %(caption)dpx; padding: 4px 4px; }
.net-glyph { font-size: %(title)dpx; min-width: 22px; }
.net-meta { font-size: %(body_small)dpx; color: %(dim15)s; }
.net-error { font-size: %(body_small)dpx; color: %(urgent)s; }
"""


class NetworkPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-network", width=380, css=CSS)
        self.timers = []
        self.phrase = 0
        self.password_ssid = ""

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        actions = Gtk.Box(spacing=4)
        self.qr = P.action_button("󰐲", self.plugin.summon_qr, "Show QR code")
        self.speed = P.action_button("󰓅", self.plugin.summon_speedtest, "Run a speed test")
        self.wifi_switch = P.switch(True, lambda on: self.plugin.set_wifi(on))
        for w in (self.qr, self.speed, self.wifi_switch):
            actions.append(w)
        box, self.hero = P.hero("󰈀", "", "", trailing=actions)
        card.append(box)

        self.grid = Gtk.Grid(column_spacing=20, row_spacing=4, column_homogeneous=False)
        self.values = {}
        names = [("Ping", "Packet Loss"), ("Receiving", "Sending"), ("Downloaded", "Uploaded"),
                 ("IP Address", "Gateway")]
        for r, pair in enumerate(names):
            for c, name in enumerate(pair):
                lbl = P.label(name, "net-label", xalign=0, hexpand=True)
                val = P.label("--", "net-value", xalign=1)
                self.grid.attach(lbl, c * 2, r, 1, 1)
                self.grid.attach(val, c * 2 + 1, r, 1, 1)
                self.values[name] = val
        for key, tip in (("IP Address", "Copy IP"), ("Gateway", "Copy gateway")):
            v = self.values[key]
            v.add_css_class("copy")
            v.set_tooltip_text(tip)
            v.set_cursor_from_name("pointer")
            P.on_click_gesture(v, lambda v=v: self.plugin.copy(v.get_label()))
        card.append(self.grid)

        self.band_sep = P.separator()
        self.band_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        head = Gtk.Box(spacing=8)
        self.band_title = P.section("WI-FI BAND")
        self.band_title.set_hexpand(True)
        head.append(self.band_title)
        head.append(P.section("AUTOMATIC"))
        self.band_auto = P.switch(True, self.on_band_auto)
        head.append(self.band_auto)
        self.band_row = Gtk.Box(spacing=3, homogeneous=True)
        self.band_box.append(head)
        self.band_box.append(self.band_row)
        card.append(self.band_sep)
        card.append(self.band_box)

        card.append(P.separator())
        dns = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        dns.append(P.section("DNS PROVIDER"))
        self.dns_row = Gtk.Box(spacing=3, homogeneous=True)
        self.dns_buttons = {}
        for name, tip in M.DNS_PROVIDERS:
            b = P.button(name, lambda n=name: self.plugin.set_dns(n), tip)
            b.add_css_class("net-pill")
            self.dns_row.append(b)
            self.dns_buttons[name] = b
        dns.append(self.dns_row)
        card.append(dns)

        self.wifi_sep = P.separator()
        self.wifi_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        card.append(self.wifi_sep)
        card.append(self.wifi_box)

    def on_open(self):
        pl = self.plugin
        pl.poll_details()
        pl.poll_band()
        pl.poll_dns()
        pl.scan_wifi()
        self.timers = [loop.timeout_add(1500, lambda: pl.poll_details() or True),
                       loop.timeout_add(4000, lambda: pl.poll_band() or True),
                       loop.timeout_add(2800, self._phrase_tick)]

    def on_close(self):
        for t in self.timers:
            loop.source_remove(t)
        self.timers = []
        self.password_ssid = ""

    def _phrase_tick(self):
        self.phrase += 1
        self.update_hero()
        return True

    def on_key(self, keyval, ch):
        if ch in ("r", "R"):
            self.plugin.refresh_all()
            return True
        if ch in ("w", "W") and self.plugin.wifi_device:
            self.plugin.set_wifi(not self.plugin.wifi_enabled)
            return True
        return False

    def on_band_auto(self, on):
        pl = self.plugin
        pl.set_band("auto" if on else (pl.band["band"] or (pl.band["available"] or ["auto"])[0]))

    # ---- refresh -------------------------------------------------------------

    def update_hero(self):
        pl = self.plugin
        info, kind = pl.info, pl.status["kind"]
        if info.get("type") == "wifi":
            title = info.get("ssid") or "Wi-Fi"
        elif info.get("type") == "ethernet":
            title = "Ethernet"
        else:
            title = info.get("iface") or ("Disconnected" if kind == "disconnected" else "No connection")
        detail = M.header_detail(info)
        connected = info.get("type") == "ethernet" or (info.get("type") == "wifi" and kind == "wifi")
        meta = M.PHRASES[self.phrase % len(M.PHRASES)] if connected else (
            "Not connected" if kind == "disconnected" else "")
        P.set_hero(self.hero, icon=pl.icon(), title=title + (" (%s)" % detail if detail else ""), meta=meta)
        self.qr.set_visible(info.get("type") == "wifi" and kind == "wifi")
        self.speed.set_visible(bool(info.get("iface")))
        self.wifi_switch.set_visible(pl.wifi_device is not None)
        P.set_switch(self.wifi_switch, pl.wifi_enabled)
        self.wifi_switch.set_tooltip_text("Turn Wi-Fi off" if pl.wifi_enabled else "Turn Wi-Fi on")

    def refresh(self):
        if self.window is None:
            return
        pl = self.plugin
        self.update_hero()
        info = pl.info
        self.grid.set_visible(bool(info.get("iface")))
        internet = pl.ping.get("internet", [])
        has_ping = bool(internet)
        has_transfer = "rx_bytes" in info
        v = self.values
        v["Ping"].set_label(M.format_ping(M.average_ping(internet), has_ping))
        v["Packet Loss"].set_label(M.format_packet_loss(M.packet_loss(internet), has_ping))
        v["Receiving"].set_label(M.format_rate(pl.rates.get("down", 0)) if has_transfer else "--")
        v["Sending"].set_label(M.format_rate(pl.rates.get("up", 0)) if has_transfer else "--")
        v["Downloaded"].set_label(M.format_bytes(info.get("rx_bytes", 0)) if has_transfer else "--")
        v["Uploaded"].set_label(M.format_bytes(info.get("tx_bytes", 0)) if has_transfer else "--")
        v["IP Address"].set_label(info.get("ip") or "--")
        v["Gateway"].set_label(info.get("gateway") or "--")

        band = pl.band
        can_band = info.get("type") == "wifi" and len(band["available"]) > 1
        self.band_sep.set_visible(can_band)
        self.band_box.set_visible(can_band)
        if can_band:
            self.band_title.set_label(M.band_section_title(band["selected"], band["band"]))
            P.set_switch(self.band_auto, band["selected"] == "auto")
            self.band_row.set_visible(band["selected"] != "auto")
            P.clear(self.band_row)
            for b in band["available"]:
                btn = P.button(M.band_label(b), lambda b=b: pl.set_band(b), "Stay on " + M.band_label(b))
                btn.add_css_class("net-pill")
                if b == band["selected"]:
                    btn.add_css_class("selected")
                self.band_row.append(btn)

        for name, b in self.dns_buttons.items():
            (b.add_css_class if name == pl.dns else b.remove_css_class)("selected")

        self.refresh_wifi()

    def refresh_wifi(self):
        Gtk = P.Gtk
        pl = self.plugin
        show = pl.wifi_device is not None and pl.wifi_enabled
        self.wifi_sep.set_visible(show)
        self.wifi_box.set_visible(show)
        P.clear(self.wifi_box)
        if not show:
            return
        if pl.scanning:
            self.wifi_box.append(P.section("SCANNING WI-FI…"))
        rows = pl.wifi
        for i, net in enumerate(rows):
            title = M.wifi_section_title(rows, i)
            if title:
                self.wifi_box.append(P.section(title))
            action = pl.action.get(net["ssid"], "")
            meta = {"connect": "Connecting…", "disconnect": "Disconnecting…", "forget": "Forgetting…"}.get(action, "")
            children = [P.label(M.wifi_icon_for(net["signal"]), "net-glyph"),
                        P.label(net["ssid"], xalign=0, hexpand=True, ellipsize=3),
                        P.label(meta or ("󰌾" if M.requires_credentials(net["security"]) else ""), "net-meta")]
            if net["known"] and not net["connected"]:
                children.append(P.action_button("󰆴", lambda n=net: pl.forget(n), "Forget"))
            self.wifi_box.append(P.row(*children, selected=net["connected"],
                                       tooltip="Disconnect" if net["connected"] else "Connect",
                                       on_click=lambda n=net: self.activate(n)))
            if pl.failure.get(net["ssid"]):
                self.wifi_box.append(P.label(pl.failure[net["ssid"]], "net-error", xalign=0))
            if self.password_ssid == net["ssid"]:
                entry = Gtk.Entry(placeholder_text="Passphrase", visibility=False, hexpand=True)
                entry.add_css_class("sk-entry")
                entry.connect("activate", lambda e, n=net: self.submit_password(n, e.get_text()))
                box = Gtk.Box(spacing=6)
                box.append(entry)
                box.append(P.button("Join", lambda e=entry, n=net: self.submit_password(n, e.get_text())))
                self.wifi_box.append(box)
                loop.idle_add(lambda e=entry: e.grab_focus() and False)

    def activate(self, net):
        pl = self.plugin
        if net["connected"]:
            pl.disconnect(net)
        elif net["known"] or not M.requires_credentials(net["security"]):
            pl.connect(net, None)
        else:
            self.password_ssid = "" if self.password_ssid == net["ssid"] else net["ssid"]
            self.refresh_wifi()

    def submit_password(self, net, password):
        self.password_ssid = ""
        self.plugin.connect(net, password)


class NetworkPanelApp(PanelApp):
    def on_start(self):
        self.status = M.parse_network_status("")
        self.info = {}
        self.rates = {}
        self.ping = {}
        self.band = M.parse_band_status("")
        self.dns = ""
        self.wifi = []
        self.wifi_device = None
        self.wifi_enabled = True
        self.scanning = False
        self.action = {}
        self.failure = {}
        self.scanned = False
        self.panel = NetworkPanel(self)
        self.pending = None
        self.refresh_all()
        self.watch_lines(["nmcli", "monitor"], self.on_nm_event, self.on_monitor_exit)

    def on_nm_event(self, line):
        if self.pending is None:
            self.pending = loop.timeout_add(300, self._pending_refresh)

    def on_monitor_exit(self):
        self.later(3, lambda: self.watch_lines(["nmcli", "monitor"], self.on_nm_event, self.on_monitor_exit))

    def _pending_refresh(self):
        self.pending = None
        self.refresh_all()
        return False

    # ---- data -----------------------------------------------------------------

    def refresh_all(self):
        def status(ok, out, err):
            self.status = M.parse_network_status(out if ok else "")
            if self.panel.opened:
                self.panel.update_hero()
        self.run_cmd(["omarchy-network-status"], status)

        def devices(ok, out, err):
            self.wifi_device = None
            for line in (out or "").splitlines():
                f = M.nmcli_split(line)
                if len(f) >= 2 and f[1] == "wifi":
                    self.wifi_device = f[0]
            # The panel opens before the first answers arrive.
            if self.panel.opened and not self.scanned:
                self.scan_wifi()
            self.panel.refresh()
        self.run_cmd(["nmcli", "-t", "-f", "DEVICE,TYPE", "device"], devices)

        def radio(ok, out, err):
            self.wifi_enabled = out.strip() == "enabled"
            self.panel.refresh()
        self.run_cmd(["nmcli", "radio", "wifi"], radio)
        if self.panel.opened:
            self.load_wifi()

    def poll_details(self):
        def done(ok, out, err):
            if not ok:
                return
            info = M.parse_key_value(out)
            self.info = info
            self.rates = M.throughput_state(self.rates, info, time.monotonic())
            self.ping = M.ping_state(self.ping, info)
            self.panel.refresh()
        self.run_cmd(["omarchy-network-status", "--verbose"], done)

    def poll_band(self):
        def done(ok, out, err):
            self.band = M.parse_band_status(out if ok else "")
        self.run_cmd(["omarchy-network-band"], done)

    def poll_dns(self):
        def done(ok, out, err):
            self.dns = out.strip() or "DHCP"
            self.panel.refresh()
        self.run_cmd(["bash", "-c", "omarchy-dns </dev/null"], done)

    def scan_wifi(self):
        if self.wifi_device is None:
            return
        self.scanned = True
        self.scanning = True
        self.run_cmd(["nmcli", "device", "wifi", "rescan"],
                     lambda *_: self.later(1.5, self._scan_done))

    def _scan_done(self):
        self.scanning = False
        self.load_wifi()

    def load_wifi(self):
        if self.wifi_device is None:
            self.wifi = []
            return
        known = set()

        def connections(ok, out, err):
            for line in (out or "").splitlines():
                f = M.nmcli_split(line)
                if len(f) >= 2 and f[1] == "802-11-wireless":
                    known.add(f[0])

        def networks(ok, out, err):
            seen = {}
            for line in (out or "").splitlines():
                f = M.nmcli_split(line)
                if len(f) < 4 or not f[1]:
                    continue
                ssid = f[1]
                row = {"ssid": ssid, "connected": f[0] == "*", "known": ssid in known,
                       "signal": int(f[2] or 0), "security": f[3]}
                if ssid not in seen or row["connected"] or row["signal"] > seen[ssid]["signal"]:
                    seen[ssid] = row
            self.wifi = M.sort_wifi(list(seen.values()))
            for ssid in list(self.action):
                net = seen.get(ssid)
                a = self.action[ssid]
                if (a == "connect" and net and net["connected"]) or (a == "disconnect" and net and not net["connected"]) \
                        or (a == "forget" and net and not net["known"]):
                    del self.action[ssid]
            self.panel.refresh()
        self.run_cmd(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"],
                     lambda ok, out, err: (connections(ok, out, err), self.run_cmd(
                         ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"],
                         networks)))

    # ---- actions ----------------------------------------------------------------

    def icon(self):
        return M.connection_icon(self.status["kind"], self.status["signal"])

    def copy(self, value):
        if value and value != "--":
            self.run_cmd(["wl-copy", value])

    def set_dns(self, provider):
        if provider == "Custom":
            self.run_detached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-dns Custom"])
            self.panel.close()
            return
        self.run_cmd(["omarchy-dns", provider], lambda ok, *_: ok and setattr(self, "dns", provider))
        self.panel.close()

    def set_band(self, band):
        self.run_cmd(["omarchy-network-band", band], lambda *_: (self.poll_band(), self.panel.refresh()))

    def set_wifi(self, on):
        self.run_cmd(["nmcli", "radio", "wifi", "on" if on else "off"], lambda *_: self.refresh_all())

    def summon(self, target, payload):
        self.panel.close()
        self.run_cmd(["omarchy-shell", "-q", "shell", "summon", target, json.dumps(payload)])

    def summon_qr(self):
        payload = {"iface": self.info["iface"], "ssid": self.info.get("ssid", "")} \
            if self.info.get("type") == "wifi" and self.info.get("iface") else {}
        self.summon("omarchy.wifiqr", payload)

    def summon_speedtest(self):
        t = self.info.get("type")
        conn = (self.info.get("ssid") or "Wi-Fi") if t == "wifi" else ("Ethernet" if t == "ethernet" else "")
        self.summon("omarchy.speedtest", {"connection": conn} if conn else {})

    def connect(self, net, password):
        ssid = net["ssid"]
        self.action[ssid] = "connect"
        self.failure.pop(ssid, None)
        if net["known"]:
            argv = ["nmcli", "connection", "up", "id", ssid]
        else:
            argv = ["nmcli", "device", "wifi", "connect", ssid]
            if password:
                argv += ["password", password]

        def done(ok, out, err):
            self.action.pop(ssid, None)
            if not ok:
                msg = err.strip().splitlines()[-1] if err.strip() else "Failed to connect"
                self.failure[ssid] = "Wrong password" if "secrets" in msg.lower() or "password" in msg.lower() else msg
            self.refresh_all()
        self.run_cmd(argv, done)
        self.panel.refresh()

    def disconnect(self, net):
        self.action[net["ssid"]] = "disconnect"
        if self.wifi_device:
            self.run_cmd(["nmcli", "device", "disconnect", self.wifi_device], lambda *_: self.refresh_all())
        self.panel.refresh()

    def forget(self, net):
        self.action[net["ssid"]] = "forget"
        self.run_cmd(["nmcli", "connection", "delete", "id", net["ssid"]], lambda *_: self.refresh_all())
        self.panel.refresh()

    def on_config(self, ev):
        self.panel.theme_changed()


if __name__ == "__main__":
    NetworkPanelApp().run()
