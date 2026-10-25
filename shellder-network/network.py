#!/usr/bin/env python3
"""shellder-network — port of omarchy.network (the bar item).

Original: /usr/share/omarchy/shell/plugins/panels/network/{Panel.qml,Model.js}.

  bar     󰈀 ethernet, 󰤯..󰤨 Wi-Fi signal, 󰤮 disconnected
  click   the Network panel: panel.py, a separate program Shellder runs only
          while the panel is open (manifest barWidget.panel: "process")

This process only keeps the icon: it follows `nmcli monitor` (no polling)
and reads omarchy-network-status. No GUI toolkit is loaded here.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from shellder_kit import loop  # noqa: E402

from shellder_kit import Plugin  # noqa: E402

import model as M  # noqa: E402


class Network(Plugin):
    def on_start(self):
        self.status = M.parse_network_status("")
        self.pending = None
        self.refresh()
        self.watch_lines(["nmcli", "monitor"], self.on_nm_event, self.on_monitor_exit)

    def on_nm_event(self, line):
        if self.pending is None:
            self.pending = loop.timeout_add(300, self._pending_refresh)

    def on_monitor_exit(self):
        self.later(3, lambda: self.watch_lines(["nmcli", "monitor"], self.on_nm_event, self.on_monitor_exit))

    def _pending_refresh(self):
        self.pending = None
        self.refresh()
        return False

    def refresh(self):
        def status(ok, out, err):
            self.status = M.parse_network_status(out if ok else "")
            self.render()
        self.run_cmd(["omarchy-network-status"], status)

    def render(self):
        self.emit(icon=M.connection_icon(self.status["kind"], self.status["signal"]), text="")

    def on_config(self, ev):
        self.render()


if __name__ == "__main__":
    Network().run()
