"""Child process of a "process"-mode panel (manifest barWidget.panel):
started by nodes.SkaldPanel on open, it draws the nodes with GTK and exits
when the panel closes, so GTK's memory is only paid while the panel is open.

    python3 -m shellder_kit.panel_process NAMESPACE

stdin, one JSON object per line (from the plugin):
    {"open": {"event": <click event>, "theme": <config theme>, "spec": <panel>}}
    {"spec": <panel>}            new content
    {"theme": <config theme>}    theme changed
    {"close": true}              close and exit (EOF does the same)

stdout (to the plugin):
    {"action": "click" | "change" | "toggle", "id": ..., "value": ...}
    {"action": "closed"}         closed here (Esc, a click outside); then exits
"""

import json
import os
import sys

from . import panel as P
from .gtk_nodes import NodesPanel
from .theme import Theme


class Host:
    """What P.Panel needs from a plugin."""

    def __init__(self):
        self.theme = Theme(None)
        self._popups = []


class Child:
    def __init__(self, namespace):
        self.host = Host()
        self.panel = NodesPanel(self.host, namespace, self.send_action, self.closed)
        self.loop = P.GLib.MainLoop()
        self.buf = b""
        self.done = False

    def send(self, obj):
        try:
            sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            pass

    def send_action(self, action, id, value):
        self.send({"action": action, "id": id, "value": value})

    def closed(self):
        if not self.done:
            self.done = True
            self.send({"action": "closed"})
        self.loop.quit()

    def message(self, msg):
        if "open" in msg:
            o = msg["open"] or {}
            self.host.theme = Theme(o.get("theme"))
            self.panel.spec = o.get("spec") or {}
            self.panel.open(o.get("event") or {})
        if "theme" in msg:
            self.host.theme = Theme(msg["theme"])
            self.panel.theme_changed()
        if "spec" in msg:
            self.panel.set_spec(msg["spec"])
        if msg.get("close"):
            self.done = True  # asked by the plugin: no "closed" back
            self.panel.close()
            self.loop.quit()

    def on_stdin(self, fd, cond):
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            return True
        if not chunk:
            self.done = True
            self.panel.close()
            self.loop.quit()
            return False
        self.buf += chunk
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg, dict):
                self.message(msg)
        return True

    def run(self):
        os.set_blocking(0, False)
        P.GLib.io_add_watch(0, P.GLib.IO_IN | P.GLib.IO_HUP, self.on_stdin)
        self.loop.run()


def main():
    if not P.import_gtk():
        print(json.dumps({"action": "closed"}), flush=True)
        return 1
    namespace = sys.argv[1] if len(sys.argv) > 1 else "shellder-panel"
    Child(namespace).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
