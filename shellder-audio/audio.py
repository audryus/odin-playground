#!/usr/bin/env python3
"""shellder-audio — port of omarchy.audio.

Original: /usr/share/omarchy/shell/plugins/panels/audio/{Panel.qml,Model.js}.

  bar          volume glyph (Waybar's pulseaudio set, headphones glyph)
  left click   Audio panel: hero with the volume mood name and a master
               mute switch, OUTPUT slider + output devices, INPUT slider +
               input devices, SOURCES (per-app streams with mute and volume)
  right click  mute/unmute everything (output and input), like Omarchy
  scroll       output volume in 5% steps, with Omarchy's OSD

Omarchy reads PipeWire through quickshell; here it is pipewire-pulse through
`pactl -f json`, refreshed on `pactl subscribe` events (no polling). Default
output changes go through omarchy-audio-output-set-default (moves the
streams too) and volume goes to the sink omarchy-audio-output-sink names.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SHELLDER_KIT", ""), "python"))
from gi.repository import GLib  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import panel as P  # noqa: E402

import model as M  # noqa: E402

CSS = """
.au-value { font-size: %(caption)dpx; font-weight: bold; color: %(dim14)s; }
.au-glyph { font-size: %(title)dpx; min-width: 22px; }
.au-check { font-size: %(subtitle)dpx; }
.au-stream-value { font-size: %(body_small)dpx; color: %(dim14)s; }
"""


def section_header(title):
    Gtk = P.Gtk
    row = Gtk.Box(spacing=8)
    row.append(P.label(title, "sk-section", xalign=0, hexpand=True))
    value = P.label("", "au-value", xalign=1)
    row.append(value)
    return row, value


class AudioPanel(P.Panel):
    def __init__(self, plugin):
        super().__init__(plugin, "shellder-audio", width=380, css=CSS)

    def build(self, card):
        Gtk = P.Gtk
        card.set_spacing(14)
        self.master = P.switch(True, self.on_master)
        box, self.hero = P.hero("\uf028", "Audio", "", trailing=self.master)
        card.append(box)

        card.append(P.separator())
        out = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        head, self.out_value = section_header("OUTPUT")
        self.out_slider = P.slider(0.5, lambda v: self.plugin.set_volume("sink", v), 0, 1, 0.01)
        self.sinks_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for w in (head, self.out_slider, self.sinks_box):
            out.append(w)
        card.append(out)

        self.in_sep = P.separator()
        card.append(self.in_sep)
        self.in_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        head, self.in_value = section_header("INPUT")
        self.in_slider = P.slider(0.5, lambda v: self.plugin.set_volume("source", v), 0, 1, 0.01)
        self.sources_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for w in (head, self.in_slider, self.sources_box):
            self.in_box.append(w)
        card.append(self.in_box)

        self.streams_sep = P.separator()
        card.append(self.streams_sep)
        self.streams_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.append(self.streams_box)

    def on_master(self, on):
        self.plugin.set_all_muted(not on)

    def on_key(self, keyval, ch):
        K = P.Gdk
        if keyval in (K.KEY_Left, K.KEY_Right):
            self.plugin.step_volume(0.05 if keyval == K.KEY_Right else -0.05, osd=False)
            return True
        if ch in ("m", "M"):
            self.plugin.toggle_mute("sink")
            return True
        return False

    def device_rows(self, box, nodes, default, kind):
        P.clear(box)
        for n in nodes:
            glyph = M.sink_glyph(n) if kind == "sink" else M.source_glyph(n)
            is_default = n.get("name") == default
            box.append(P.row(P.label(glyph, "au-glyph"),
                             P.label(M.node_label(n), xalign=0, hexpand=True, ellipsize=3),
                             P.label("󰄬" if is_default else "", "au-check"),
                             selected=is_default,
                             on_click=lambda n=n: self.plugin.set_default(kind, n)))

    def refresh(self):
        if self.window is None:
            return
        pl = self.plugin
        sink, source = pl.volume_sink(), pl.default_node("source")
        vol, muted = M.volume_of(sink), bool(sink and sink.get("mute"))
        P.set_hero(self.hero, icon=pl.output_icon(), meta=M.output_volume_name(vol, muted))
        P.set_switch(self.master, pl.any_audible())
        self.master.set_tooltip_text("Mute" if pl.any_audible() else "Unmute")
        self.out_value.set_label("%d%%" % round(vol * 100))
        P.set_slider(self.out_slider, vol)
        self.device_rows(self.sinks_box, pl.available_sinks(), pl.defaults.get("sink"), "sink")

        has_in = bool(pl.sources) or source is not None
        for w in (self.in_sep, self.in_box):
            w.set_visible(has_in)
        if source is not None:
            self.in_value.set_label("%d%%" % round(M.volume_of(source) * 100))
            P.set_slider(self.in_slider, M.volume_of(source))
        self.in_slider.set_visible(source is not None)
        self.device_rows(self.sources_box, pl.sources, pl.defaults.get("source"), "source")

        streams = pl.streams
        self.streams_sep.set_visible(bool(streams))
        self.streams_box.set_visible(bool(streams))
        P.clear(self.streams_box)
        if streams:
            self.streams_box.append(P.section("SOURCES"))
            for s in streams:
                Gtk = P.Gtk
                svol = M.volume_of(s)
                mute = P.action_button("󰝟" if s.get("mute") else "󰕾",
                                       lambda s=s: pl.toggle_stream_mute(s), "Mute")
                head = Gtk.Box(spacing=8)
                head.append(mute)
                head.append(P.label(M.stream_label(s), xalign=0, hexpand=True, ellipsize=3))
                head.append(P.label("%d%%" % round(svol * 100), "au-stream-value"))
                slider = P.slider(svol, lambda v, s=s: pl.set_stream_volume(s, v), 0, 1, 0.01)
                col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
                col.append(head)
                col.append(slider)
                self.streams_box.append(col)


class Audio(Plugin):
    def on_start(self):
        self.sinks, self.sources, self.streams = [], [], []
        self.defaults = {}
        self.availability = {}
        self.volume_sink_name = ""
        self.panel = AudioPanel(self)
        self.pending = None
        self.reload()
        self.watch_lines(["pactl", "subscribe"], self.on_event, self.on_subscribe_exit)
        self.every(15, self.resolve_volume_sink, now=True)

    # ---- data -----------------------------------------------------------------

    def on_event(self, line):
        # A burst of events (moving a slider emits many) becomes one reload.
        if "sink" in line or "source" in line or "server" in line:
            if self.pending is None:
                self.pending = GLib.timeout_add(75, self._reload_pending)

    def on_subscribe_exit(self):
        self.later(2, lambda: self.watch_lines(["pactl", "subscribe"], self.on_event, self.on_subscribe_exit))

    def _reload_pending(self):
        self.pending = None
        self.reload()
        return False

    def reload(self):
        queries = {
            "sinks":   (["pactl", "-f", "json", "list", "sinks"], json.loads),
            "sources": (["pactl", "-f", "json", "list", "sources"], json.loads),
            "streams": (["pactl", "-f", "json", "list", "sink-inputs"], json.loads),
            "dsink":   (["pactl", "get-default-sink"], str.strip),
            "dsource": (["pactl", "get-default-source"], str.strip),
        }
        got = {}

        def collect(key, parse):
            def done(ok, out, err):
                try:
                    got[key] = parse(out) if ok else None
                except ValueError:
                    got[key] = None
                if len(got) == len(queries):
                    self.apply(got)
            return done
        for key, (argv, parse) in queries.items():
            self.run_cmd(argv, collect(key, parse))

    def apply(self, got):
        self.sinks = got.get("sinks") or []
        # Monitors of sinks are not input devices.
        self.sources = [s for s in (got.get("sources") or []) if not s.get("name", "").endswith(".monitor")]
        # Only real application streams (a DSP filter chain's own stream has
        # no application.name), as omarchy-audio-output-set-default does.
        self.streams = [s for s in (got.get("streams") or []) if M.props(s).get("application.name")]
        self.defaults = {"sink": got.get("dsink") or "", "source": got.get("dsource") or ""}
        self.render()
        if self.panel.opened:
            self.panel.refresh()

    def resolve_volume_sink(self):
        def done(ok, out, err):
            self.volume_sink_name = out.strip() if ok else ""
        self.run_cmd(["omarchy-audio-output-sink"], done)

        def avail(ok, out, err):
            if ok:
                self.availability = M.parse_sink_availability(out)
        self.run_cmd(["omarchy-audio-sink-availability"], avail)

    def default_node(self, kind):
        nodes = self.sinks if kind == "sink" else self.sources
        name = self.defaults.get(kind)
        return next((n for n in nodes if n.get("name") == name), None)

    def volume_sink(self):
        """The sink the volume controls act on (EasyEffects-aware), else default."""
        if self.volume_sink_name:
            node = next((n for n in self.sinks if n.get("name") == self.volume_sink_name), None)
            if node:
                return node
        return self.default_node("sink")

    def available_sinks(self):
        return [s for s in self.sinks if self.availability.get(s.get("name"), True)]

    def any_audible(self):
        sink, source = self.volume_sink(), self.default_node("source")
        return bool((sink and not sink.get("mute")) or (source and not source.get("mute")))

    def output_icon(self, volume=None):
        sink = self.volume_sink()
        if sink is None:
            return "\ueee8"
        v = M.volume_of(sink) if volume is None else volume
        return M.output_icon(v, bool(sink.get("mute")), M.is_headphones(self.default_node("sink") or sink))

    # ---- actions ----------------------------------------------------------------

    def set_volume(self, kind, value):
        node = self.volume_sink() if kind == "sink" else self.default_node("source")
        if node is None:
            return
        cmd = "set-sink-volume" if kind == "sink" else "set-source-volume"
        self.run_cmd(["pactl", cmd, node["name"], "%d%%" % round(max(0, min(1, value)) * 100)])

    def step_volume(self, delta, osd=True):
        sink = self.volume_sink()
        if sink is None:
            return
        v = max(0.0, min(1.0, M.volume_of(sink) + delta))
        self.set_volume("sink", v)
        if osd:
            self.run_cmd(["omarchy-shell", "-q", "shell", "summon", "omarchy.osd",
                          json.dumps({"icon": self.output_icon(v), "value": round(v * 100)})])

    def toggle_mute(self, kind):
        node = self.volume_sink() if kind == "sink" else self.default_node("source")
        if node is not None:
            cmd = "set-sink-mute" if kind == "sink" else "set-source-mute"
            self.run_cmd(["pactl", cmd, node["name"], "toggle"])

    def set_all_muted(self, mute):
        sink, source = self.volume_sink(), self.default_node("source")
        flag = "1" if mute else "0"
        if sink is not None:
            self.run_cmd(["pactl", "set-sink-mute", sink["name"], flag])
        if source is not None:
            self.run_cmd(["pactl", "set-source-mute", source["name"], flag])

    def set_default(self, kind, node):
        if kind == "sink":
            oid = M.props(node).get("object.id") or str(node.get("index"))
            self.run_cmd(["omarchy-audio-output-set-default", str(oid), node["name"]])
        else:
            self.run_cmd(["pactl", "set-default-source", node["name"]])

    def toggle_stream_mute(self, s):
        self.run_cmd(["pactl", "set-sink-input-mute", str(s["index"]), "toggle"])

    def set_stream_volume(self, s, v):
        self.run_cmd(["pactl", "set-sink-input-volume", str(s["index"]), "%d%%" % round(v * 100)])

    # ---- bar ----------------------------------------------------------------------

    def render(self):
        self.emit(icon=self.output_icon(), text="")

    def on_config(self, ev):
        self.panel.theme_changed()
        self.render()

    def on_click(self, ev):
        if ev.get("button") == "right":
            self.set_all_muted(self.any_audible())
        elif ev.get("button") == "left":
            self.panel.toggle(ev)

    def on_scroll(self, ev):
        self.step_volume(0.05 if ev.get("direction") == "up" else -0.05)


if __name__ == "__main__":
    Audio().run()
