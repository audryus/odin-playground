#!/usr/bin/env python3
"""shellder-indicators — port of omarchy.indicators to Shellder.

Original: /usr/share/omarchy/shell/plugins/bar/widgets/Indicators.qml and
plugins/bar/indicators/*.qml (BarIndicator.qml).

Indicators (same order, glyphs and actions as Omarchy):
  Dictation        voxtype recording/transcribing  -> omarchy-voxtype-config
  ScreenRecording  gpu-screen-recorder running     -> stop / recording menu
  Reminder         pending reminders               -> show / create
  NightLight       hyprsunset below 6000 K         -> omarchy-toggle-nightlight
  Dnd              notifications silenced          -> omarchy-toggle-notification-silencing
  StayAwake        idle disabled                   -> omarchy-toggle-idle

As in Omarchy, active indicators always show (newest first) and inactive ones
only while the pointer is over the item, at 45% opacity — or always, with
"alwaysShow": true. Settings (the plugin's entry in shell.json):
  "items": ["Dnd", "NightLight", ...]   which ones, in order
  "alwaysShow": true

The services Omarchy queries from inside quickshell are read from outside
here: Omarchy state files, the hyprsunset socket, /proc and omarchy-* scripts.
"""

import json
import os
import socket
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from shellder_kit import Plugin  # noqa: E402

DEFAULT_ITEMS = ["Dictation", "ScreenRecording", "Reminder", "NightLight", "Dnd", "StayAwake"]
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "omarchy")
INACTIVE_OPACITY = 0.45  # BarIndicator: dimmed


def hypr_dir():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), "hypr",
                        os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""))


class Indicator:
    """One indicator: state, glyphs, tooltip and click action."""
    active_text = inactive_text = ""
    active_tip = inactive_tip = ""

    def __init__(self, host):
        self.host = host
        self.active = False

    def text(self):
        return self.active_text if self.active else self.inactive_text

    def tooltip(self):
        return self.active_tip if self.active else self.inactive_tip

    def poll(self):
        """Refresh self.active; called periodically."""

    def click(self):
        pass


class Dictation(Indicator):
    inactive_text = "󰍬"
    inactive_tip = "Dictate"

    def __init__(self, host):
        super().__init__(host)
        self.state = "idle"
        host.watch_lines(["bash", "-c", "omarchy-voxtype-status"], self.update)

    def update(self, raw):
        try:
            data = json.loads(raw)
        except ValueError:
            return
        self.state = str(data.get("alt") or data.get("class") or "idle")
        self.active = self.state == "recording"
        self.active_text = {"recording": "󰍬", "transcribing": "󰔟"}.get(self.state, "")
        self.active_tip = self.state
        self.host.render()

    def click(self):
        self.host.run_detached(["omarchy-voxtype-config"])


class ScreenRecording(Indicator):
    active_text = inactive_text = "󰻂"
    active_tip, inactive_tip = "Stop recording", "Screen Recording"

    def poll(self):
        # pgrep -f ^gpu-screen-recorder without spawning a process.
        found = False
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open("/proc/%s/cmdline" % pid, "rb") as f:
                    if f.read(64).startswith(b"gpu-screen-recorder"):
                        found = True
                        break
            except OSError:
                continue
        self.active = found

    def click(self):
        if self.active:
            self.host.run_detached(["omarchy-capture-screenrecording", "--stop-recording"])
        else:
            self.host.run_detached(["omarchy-menu", "toggle", "trigger.capture.screenrecord"])
        self.host.later(1.0, self.host.refresh)


class Reminder(Indicator):
    active_text = inactive_text = "󰢌"
    slow = True  # runs a script: not every second

    def __init__(self, host):
        super().__init__(host)
        self.count = 0
        self.tip = ""

    def tooltip(self):
        return self.tip

    def poll(self):
        def done(ok, out, err):
            try:
                data = json.loads(out) if ok else {}
            except ValueError:
                data = {}
            self.count = int(data.get("count") or 0)
            self.tip = str(data.get("tooltip") or "")
            self.active = self.count > 0
            self.host.render()
        self.host.run_cmd(["omarchy-reminder", "show", "--json"], done)

    def click(self):
        self.host.run_detached(["omarchy-reminder", "show"] if self.count > 0 else ["omarchy-reminder", "-i"])
        self.host.later(1.0, self.poll)


class NightLight(Indicator):
    active_text = inactive_text = "󰔎"
    active_tip, inactive_tip = "Day Light", "Night Light"

    def poll(self):
        # Same rule as omarchy-toggle-nightlight --status (< 6000 K), asking
        # the hyprsunset socket directly; no socket means it is off.
        temp = None
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(0.3)
                s.connect(os.path.join(hypr_dir(), ".hyprsunset.sock"))
                s.sendall(b"temperature")
                digits = "".join(ch for ch in s.recv(64).decode(errors="replace") if ch.isdigit())
                temp = int(digits) if digits else None
        except OSError:
            pass
        self.active = temp is not None and temp < 6000

    def click(self):
        self.host.run_cmd(["omarchy-toggle-nightlight"], lambda *_: self.host.refresh())


class Dnd(Indicator):
    active_text = inactive_text = "󰂛"
    active_tip, inactive_tip = "Allow Notifications", "Silence Notifications"

    def poll(self):
        # Persisted by Omarchy's notification service.
        try:
            with open(os.path.join(STATE, "notifications.json")) as f:
                self.active = bool(json.load(f).get("dnd"))
        except (OSError, ValueError):
            self.active = False

    def click(self):
        self.host.run_cmd(["omarchy-toggle-notification-silencing"], lambda *_: self.host.refresh())


class StayAwake(Indicator):
    active_text = inactive_text = "󰅶"
    active_tip, inactive_tip = "Allow Idle Lock & Screensaver", "Stay Awake"

    def poll(self):
        self.active = os.path.exists(os.path.join(STATE, "indicators", "stay-awake"))

    def click(self):
        self.host.run_cmd(["omarchy-toggle-idle"], lambda *_: self.host.refresh())


KINDS = {c.__name__: c for c in (Dictation, ScreenRecording, Reminder, NightLight, Dnd, StayAwake)}


class Indicators(Plugin):
    def on_start(self):
        self.indicators = {}
        self.order = []          # configured ids, in order
        self.active_order = []   # active ones, newest first
        self.hovered = set()     # monitors with the pointer over the item
        self.monitors = []
        self.ticks = 0
        self.every(1, self.tick)

    def on_config(self, ev):
        items = self.setting("items") or self.setting("indicators") or DEFAULT_ITEMS
        ids = [i if isinstance(i, str) else (i or {}).get("id", "") for i in items]
        self.order = [i for i in ids if i in KINDS]
        for i in self.order:
            if i not in self.indicators:
                self.indicators[i] = KINDS[i](self)
        self.monitors = self.list_monitors()
        self.refresh()

    def list_monitors(self):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(os.path.join(hypr_dir(), ".socket.sock"))
                s.sendall(b"j/monitors")
                data = b""
                while chunk := s.recv(65536):
                    data += chunk
            return [m["name"] for m in json.loads(data)]
        except (OSError, ValueError):
            return []

    def tick(self):
        self.ticks += 1
        for i in self.order:
            ind = self.indicators[i]
            if getattr(ind, "slow", False) and self.ticks % 15:
                continue
            ind.poll()
        self.render()

    def refresh(self):
        for i in self.order:
            self.indicators[i].poll()
        self.render()

    def render(self):
        for i in self.order:
            ind = self.indicators[i]
            if ind.active and i not in self.active_order:
                # Newcomers go first so the ones already showing don't move
                # (Indicators.qml: setIndicatorActive).
                self.active_order.insert(0, i)
            elif not ind.active and i in self.active_order:
                self.active_order.remove(i)
        self.active_order = [i for i in self.active_order if i in self.order]
        always = self.setting("alwaysShow", False) is True
        for mon in self.monitors or [None]:
            reveal = always or mon in self.hovered
            self.emit(monitor=mon, segments=self.segments(reveal))

    def segments(self, reveal):
        slot = self.theme.bar_token("statusSlot", 21)
        segs = []

        def seg(i, ind, opacity):
            return {"id": i, "text": ind.text(), "tooltip": ind.tooltip(), "font": "caption",
                    "width": slot, "opacity": opacity}
        # Inactive area (left), revealed on hover; then the active block.
        if reveal:
            for i in self.order:
                ind = self.indicators[i]
                if not ind.active and ind.text():
                    segs.append(seg(i, ind, INACTIVE_OPACITY))
        for i in self.active_order:
            segs.append(seg(i, self.indicators[i], 1))
        if not segs:
            # Invisible hover target: Omarchy reveals on hover of the whole
            # center section, which Shellder does not report.
            segs.append({"id": "_reveal", "text": " ", "width": slot, "opacity": 0})
        return segs

    def on_hover(self, ev):
        mon = ev.get("monitor")
        if ev.get("hovered"):
            self.hovered.add(mon)
        else:
            self.hovered.discard(mon)
        if mon not in self.monitors:
            self.monitors.append(mon)
        self.render()

    def on_click(self, ev):
        ind = self.indicators.get(ev.get("segment", ""))
        if ind is not None and ev.get("button") == "left":
            ind.click()


if __name__ == "__main__":
    Indicators().run()
