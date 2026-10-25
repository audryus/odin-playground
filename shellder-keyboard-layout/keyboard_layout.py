#!/usr/bin/env python3
"""shellder-keyboard-layout — port of omarchy.keyboard-layout.

Original: /usr/share/omarchy/shell/plugins/bar/widgets/{KeyboardLayout.qml,
KeyboardLayoutModel.js}.

  bar       the active layout's language code ("EN", "POR"...), caption size;
            tooltip: the full layout name. Hidden unless the keyboard has
            more than one layout (the single-layout install shows nothing).
  click     hyprctl switchxkblayout <keyboard> next

Reads `hyprctl -j devices` on start, on Hyprland's activelayout/configreloaded
events and, while the seat is ambiguous (no reading yet, several keyboards, a
keyboard without keymap), every 10 s. Codes come from `xkbcli list`.
"""

import json
import os
import socket
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from gi.repository import GLib  # noqa: E402

from shellder_kit import Plugin  # noqa: E402

import model as M  # noqa: E402

STALL_S = 5


def socket2_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    return os.path.join(runtime, "hypr", sig, ".socket2.sock")


class KeyboardLayout(Plugin):
    def on_start(self):
        self.layout_full = ""
        self.keyboard = ""         # the one a click switches
        self.typed_keyboard = ""   # the one the last activelayout event named
        self.count = 0
        self.unresolved = False
        self.multiple = True
        self.briefs = {}
        self.query = None
        self.pending = False
        self.events = None
        self.run_cmd(["xkbcli", "list", "--load-exotic"], self._got_briefs)
        self.refresh()
        self.every(10, self._poll)
        self._connect()

    # ---- Hyprland events ----------------------------------------------------------

    def _connect(self):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(socket2_path())
        except OSError:
            self.later(2, self._connect)
            return
        self.events, self.buf = s, b""
        GLib.io_add_watch(s.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self._on_events)

    def _on_events(self, fd, cond):
        data = b""
        if cond & GLib.IO_IN:
            try:
                data = self.events.recv(65536)
            except OSError:
                data = b""
        if not data:
            self.events.close()
            self.events = None
            self.later(2, self._connect)
            return False
        *lines, self.buf = (self.buf + data).split(b"\n")
        for line in lines:
            name, _, payload = line.decode(errors="replace").partition(">>")
            # The event names the keyboard being typed on, whatever holds the
            # main flag; a reload may add a layout without any activelayout.
            if name == "activelayout":
                named = M.event_keyboard_name(payload)
                if named:
                    self.typed_keyboard = named
            if "activelayout" in name or name == "configreloaded":
                self.refresh()
        return True

    # ---- reading the seat ------------------------------------------------------------

    def _got_briefs(self, ok, out, err):
        self.briefs = M.layout_briefs(out)
        self.render()

    def _poll(self):
        if not self.keyboard or self.unresolved or self.count > 1:
            self.refresh()

    def refresh(self):
        # A query in flight may read the layout a switch replaced: re-run once
        # it lands rather than dropping the request.
        if self.query is not None:
            self.pending = True
            return
        self.pending = False
        self.query = self.run_cmd(["hyprctl", "-j", "devices"], self._got_devices)
        if self.query is not None:
            proc = self.query
            self.later(STALL_S, lambda: self._stalled(proc))

    def _stalled(self, proc):
        if self.query is proc:
            proc.force_exit()

    def _got_devices(self, ok, out, err):
        self.query = None
        try:
            listed = json.loads(out or "{}").get("keyboards")
        except ValueError:
            listed = None
        if isinstance(listed, list):
            self._read(listed)
        if self.pending:
            self.refresh()

    def _read(self, listed):
        typed = [k for k in listed if M.is_typed_keyboard(k.get("name"))]
        kb = M.select_keyboard(typed, self.typed_keyboard)
        if not kb or not kb.get("active_keymap"):
            # Unplugged, or no keymap yet: keep asking.
            self.unresolved = True
            if not typed:
                self.layout_full = self.keyboard = ""
            self.render()
            return
        self.unresolved = False
        self.count = len(typed)
        self.keyboard = str(kb.get("name") or "")
        self.multiple = M.multiple_layouts(kb)
        self.layout_full = str(kb["active_keymap"])
        self.render()

    # ---- bar --------------------------------------------------------------------------

    def render(self):
        label = M.short_label(self.layout_full, self.briefs)
        if not label or not self.multiple:
            self.emit(visible=False)
            return
        self.emit(visible=True, segments=[{"id": "layout", "text": label, "font": "caption",
                                           "margin": 6, "tooltip": self.layout_full}])

    def on_click(self, ev):
        if not self.keyboard:
            return
        # switchxkblayout is a hyprctl command, not a dispatcher. Only the
        # keyboard the label describes: switching the whole seat would also
        # advance the buttons the reading depends on.
        self.run_cmd(["hyprctl", "switchxkblayout", self.keyboard, "next"])
        self.later(0.6, self.refresh)


if __name__ == "__main__":
    KeyboardLayout().run()
