#!/usr/bin/env python3
"""shellder-workspace — Hyprland workspaces per output on the Shellder bar.

Port of omarchy.workspaces (/usr/share/omarchy/shell/plugins/bar/widgets/
Workspaces.qml), but per output like the skald-bar prototype: each bar shows
that output's workspaces — the ones bound to it by rule (workspace = N,
monitor:X) plus the ones currently on it.

  active workspace of the output   glyph 󱓻
  occupied                         number, opacity 1
  empty                            number, opacity 0.5
  click                            focus the workspace
  scroll                           previous/next workspace of that output

Standard library only. Shellder protocol: one JSON line per output on stdout
({"monitor": ..., "segments": [...]}), JSON events on stdin.
"""

import json
import os
import selectors
import socket
import sys

FOCUSED_GLYPH = "\U000F14FB"  # the same as Omarchy ("󱓻")
SEGMENT_WIDTH = 20            # Omarchy's Style.space(20)
MAX_ID = 10                   # Omarchy shows up to 10 (as "0")

# socket2 events that change what the bar shows.
REFRESH_EVENTS = {
    "workspace", "workspacev2", "focusedmon", "focusedmonv2",
    "createworkspace", "createworkspacev2", "destroyworkspace", "destroyworkspacev2",
    "moveworkspace", "moveworkspacev2", "renameworkspace",
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2",
    "configreloaded",
}


def socket_path(name):
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    return os.path.join(runtime, "hypr", sig, name)


def request(cmd):
    """One command on Hyprland's request socket; returns the reply."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(socket_path(".socket.sock"))
        s.sendall(cmd.encode())
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
    return b"".join(chunks).decode(errors="replace")


def query(cmd):
    try:
        return json.loads(request("j/" + cmd))
    except (OSError, ValueError):
        return []


def focus_workspace(ws_id):
    # Hyprland >= 0.56 with a Lua config only accepts dispatch as a Lua
    # expression; the old format is the fallback for earlier versions.
    reply = request('dispatch hl.dsp.focus({ workspace = "%s" })' % ws_id)
    if not reply.startswith("ok"):
        reply = request("dispatch workspace %s" % ws_id)
    if not reply.startswith("ok"):
        print("shellder-workspace: could not switch to %s: %s" % (ws_id, reply.strip()), file=sys.stderr)


def label(ws_id, name):
    if name and name != str(ws_id):
        return name  # named workspace
    return "0" if ws_id == 10 else str(ws_id)


class Workspaces:
    def __init__(self):
        self.last = {}     # monitor -> last emitted line (avoid repeats)
        self.ids = {}      # monitor -> [ids in order]
        self.active = {}   # monitor -> active id

    def refresh(self):
        monitors = query("monitors")
        workspaces = query("workspaces")
        rules = query("workspacerules")

        by_id = {w["id"]: w for w in workspaces}
        for m in monitors:
            name = m["name"]
            ids = set()
            for r in rules:
                ws = str(r.get("workspaceString", ""))
                if r.get("monitor") == name and ws.isdigit():
                    ids.add(int(ws))
            for w in workspaces:
                if w.get("monitor") == name and w["id"] > 0:
                    ids.add(w["id"])
            ids = sorted(i for i in ids if 0 < i <= MAX_ID or i in by_id)
            active = m.get("activeWorkspace", {}).get("id")
            self.ids[name], self.active[name] = ids, active

            segments = []
            for i in ids:
                w = by_id.get(i)
                occupied = w is not None and w.get("windows", 0) > 0
                focused = i == active
                segments.append({
                    "id": str(i),
                    "text": FOCUSED_GLYPH if focused else label(i, w and w.get("name")),
                    "opacity": 1 if occupied or focused else 0.5,
                    "width": SEGMENT_WIDTH,
                })
            self.emit(name, {"monitor": name, "segments": segments})

    def emit(self, monitor, update):
        line = json.dumps(update, ensure_ascii=False)
        if self.last.get(monitor) == line:
            return
        self.last[monitor] = line
        sys.stdout.write(line + "\n")
        sys.stdout.flush()

    def handle(self, ev):
        kind = ev.get("event")
        monitor = ev.get("monitor", "")
        if kind == "click" and ev.get("segment"):
            focus_workspace(ev["segment"])
        elif kind == "scroll":
            ids = self.ids.get(monitor, [])
            if not ids:
                return
            cur = self.active.get(monitor)
            i = ids.index(cur) if cur in ids else 0
            i = (i + (1 if ev.get("direction") == "down" else -1)) % len(ids)
            focus_workspace(ids[i])


def main():
    ws = Workspaces()
    events = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        events.connect(socket_path(".socket2.sock"))
    except OSError as e:
        print("shellder-workspace: no Hyprland event socket: %s" % e, file=sys.stderr)
        sys.exit(1)
    events.setblocking(False)
    os.set_blocking(0, False)

    sel = selectors.DefaultSelector()
    sel.register(events, selectors.EVENT_READ, "hypr")
    try:
        sel.register(0, selectors.EVENT_READ, "stdin")
    except (PermissionError, ValueError):
        pass  # stdin is not a pipe (run by hand with < file): display only

    ws.refresh()
    hypr_buf, stdin_buf = b"", b""
    while True:
        dirty = False
        for key, _ in sel.select():
            if key.data == "hypr":
                data = events.recv(65536)
                if not data:
                    sys.exit(1)  # Hyprland exited; Shellder restarts the plugin
                hypr_buf += data
                *lines, hypr_buf = hypr_buf.split(b"\n")
                for line in lines:
                    name = line.split(b">>", 1)[0].decode(errors="replace")
                    if name in REFRESH_EVENTS:
                        dirty = True
            else:
                try:
                    data = os.read(0, 65536)
                except BlockingIOError:
                    continue
                if not data:
                    return  # Shellder exited
                stdin_buf += data
                *lines, stdin_buf = stdin_buf.split(b"\n")
                for line in lines:
                    try:
                        ws.handle(json.loads(line))
                    except ValueError:
                        pass
        # A burst of events (opening a window emits several) becomes one refresh.
        if dirty:
            ws.refresh()


if __name__ == "__main__":
    main()
