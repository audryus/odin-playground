#!/usr/bin/env python3
"""shellder-audio — port of omarchy.audio.

Original: /usr/share/omarchy/shell/plugins/panels/audio/{Panel.qml,Model.js}.

  bar          volume glyph (Waybar's pulseaudio set, headphones glyph)
  left click   Audio panel: hero with the volume mood name and a master
               mute switch, OUTPUT slider + output devices, INPUT slider +
               input devices, SOURCES (per-app streams with mute and volume);
               described as nodes; the manifest's "panel" picks who draws
               it (Shellder, a GTK child process, or GTK in here)
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
from shellder_kit import loop  # noqa: E402

from shellder_kit import Plugin  # noqa: E402
from shellder_kit import nodes as N  # noqa: E402

import model as M  # noqa: E402

class AudioPanel(N.SkaldPanel):
    """The Audio panel as nodes, drawn as the manifest's "panel" says."""

    def __init__(self, plugin):
        super().__init__(plugin, width=380, spacing=14)
        self.nodes = {}  # node id -> the sink/source/stream it acts on

    def device_rows(self, nodes, default, kind):
        rows = []
        for n in nodes:
            glyph = M.sink_glyph(n) if kind == "sink" else M.source_glyph(n)
            is_default = n.get("name") == default
            nid = "%s:%s" % (kind, n.get("name"))
            self.nodes[nid] = (kind, n)
            rows.append(N.row(M.node_label(n), id=nid, icon=glyph,
                              trailing="\U000f012c" if is_default else "", selected=is_default))
        return N.group(rows, spacing=2)

    def items(self):
        pl = self.plugin
        self.nodes = {}
        sink, source = pl.volume_sink(), pl.default_node("source")
        vol, muted = M.volume_of(sink), bool(sink and sink.get("mute"))
        items = [
            N.hero(pl.output_icon(), "Audio", meta=M.output_volume_name(vol, muted),
                   switch=N.switch("master", pl.any_audible())),
            N.separator(),
            N.group([N.section("OUTPUT", "%d%%" % round(vol * 100)),
                     N.slider("volume:sink", vol, 0, 1, 0.01),
                     self.device_rows(pl.available_sinks(), pl.defaults.get("sink"), "sink")]),
        ]
        if pl.sources or source is not None:
            in_vol = M.volume_of(source) if source is not None else 0
            items += [N.separator(),
                      N.group([N.section("INPUT", "%d%%" % round(in_vol * 100) if source else ""),
                               N.slider("volume:source", in_vol, 0, 1, 0.01) if source else None,
                               self.device_rows(pl.sources, pl.defaults.get("source"), "source")])]
        if pl.streams:
            streams = [N.section("SOURCES")]
            for s in pl.streams:
                idx = str(s["index"])
                self.nodes["stream:" + idx] = ("stream", s)
                svol = M.volume_of(s)
                mute_icon = "\U000f075f" if s.get("mute") else "\U000f057e"
                streams.append(N.group([
                    N.row(M.stream_label(s), plain=True, value="%d%%" % round(svol * 100),
                          action=N.action("mute:" + idx, mute_icon)),
                    N.slider("stream:" + idx, svol, 0, 1, 0.01)], spacing=0))
            items += [N.separator(), N.group(streams)]
        return items

    def on_action(self, action, id, value):
        pl = self.plugin
        if id == "master" and action == "toggle":
            pl.set_all_muted(not value)
        elif id == "volume:sink" and action == "change":
            pl.set_volume("sink", value)
        elif id == "volume:source" and action == "change":
            pl.set_volume("source", value)
        elif id.startswith("mute:"):
            node = self.nodes.get("stream:" + id[5:])
            if node:
                pl.toggle_stream_mute(node[1])
        elif id in self.nodes:
            kind, node = self.nodes[id]
            if kind == "stream" and action == "change":
                pl.set_stream_volume(node, value)
            elif kind in ("sink", "source") and action == "click":
                pl.set_default(kind, node)


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
                self.pending = loop.timeout_add(75, self._reload_pending)

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
