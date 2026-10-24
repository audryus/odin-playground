#!/usr/bin/env python3
"""shellder-workspace — workspaces do Hyprland por monitor na barra do Shellder.

Porte do omarchy.workspaces (/usr/share/omarchy/shell/plugins/bar/widgets/
Workspaces.qml), mas por monitor, como o skald-bar: cada barra mostra os
workspaces daquele monitor — os presos a ele por regra (workspace = N,
monitor:X) mais os que existem nele.

  workspace ativo do monitor   glifo 󱓻
  ocupado                      número, opacidade 1
  vazio                        número, opacidade 0.5
  clique                       vai para o workspace
  scroll                       anterior/próximo workspace daquele monitor

Só biblioteca padrão. Protocolo do Shellder: uma linha JSON por monitor no
stdout ({"monitor": ..., "segments": [...]}), eventos JSON no stdin.
"""

import json
import os
import selectors
import socket
import sys

FOCUSED_GLYPH = "\U000F14FB"  # o mesmo do Omarchy ("󱓻")
SEGMENT_WIDTH = 20            # Style.space(20) do Omarchy
MAX_ID = 10                   # o Omarchy mostra até o 10 (como "0")

# Eventos do socket2 que mudam o que a barra mostra.
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
    """Um comando no socket de request do Hyprland; devolve a resposta."""
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
    # Hyprland >= 0.56 com config em Lua só aceita dispatch como expressão Lua;
    # o formato antigo fica de reserva para versões anteriores.
    reply = request('dispatch hl.dsp.focus({ workspace = "%s" })' % ws_id)
    if not reply.startswith("ok"):
        reply = request("dispatch workspace %s" % ws_id)
    if not reply.startswith("ok"):
        print("shellder-workspace: não troquei para %s: %s" % (ws_id, reply.strip()), file=sys.stderr)


def label(ws_id, name):
    if name and name != str(ws_id):
        return name  # workspace com nome
    return "0" if ws_id == 10 else str(ws_id)


class Workspaces:
    def __init__(self):
        self.last = {}     # monitor -> linha emitida (para não repetir)
        self.ids = {}      # monitor -> [ids na ordem]
        self.active = {}   # monitor -> id ativo

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
        print("shellder-workspace: sem socket de eventos do Hyprland: %s" % e, file=sys.stderr)
        sys.exit(1)
    events.setblocking(False)
    os.set_blocking(0, False)

    sel = selectors.DefaultSelector()
    sel.register(events, selectors.EVENT_READ, "hypr")
    try:
        sel.register(0, selectors.EVENT_READ, "stdin")
    except (PermissionError, ValueError):
        pass  # stdin não é pipe (rodando à mão com < arquivo): só mostra

    ws.refresh()
    hypr_buf, stdin_buf = b"", b""
    while True:
        dirty = False
        for key, _ in sel.select():
            if key.data == "hypr":
                data = events.recv(65536)
                if not data:
                    sys.exit(1)  # Hyprland saiu; o Shellder reinicia o plugin
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
                    return  # o Shellder saiu
                stdin_buf += data
                *lines, stdin_buf = stdin_buf.split(b"\n")
                for line in lines:
                    try:
                        ws.handle(json.loads(line))
                    except ValueError:
                        pass
        # Uma rajada de eventos (abrir uma janela gera vários) vira um refresh só.
        if dirty:
            ws.refresh()


if __name__ == "__main__":
    main()
