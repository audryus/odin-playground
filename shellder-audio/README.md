# shellder-audio

Port of `omarchy.audio` (`/usr/share/omarchy/shell/plugins/panels/audio/`) to
[Shellder](../shellder).

| Action      | What it does |
|-------------|--------------|
| —           | Volume glyph (Omarchy's Waybar set; headphones glyph for headsets) |
| left click  | Audio panel: hero with the volume mood name ("Easy listening", "Party mode"…) and a master mute switch; OUTPUT slider + output devices; INPUT slider + input devices; SOURCES with per-app mute and volume |
| right click | Mute/unmute output and input together |
| scroll      | Output volume ±5%, with Omarchy's OSD (`omarchy-shell … omarchy.osd`) |

Keys in the panel: `←`/`→` volume, `m` mute, `Esc` close.

Omarchy reads PipeWire through quickshell; here it is pipewire-pulse through
`pactl -f json`, reloaded on `pactl subscribe` events (no polling). Default
output changes go through `omarchy-audio-output-set-default` (which also moves
running streams), volume targets the sink `omarchy-audio-output-sink` names,
and unavailable sinks are hidden with `omarchy-audio-sink-availability`.

```bash
make install
python3 -m unittest discover -s tests   # Model.js port
```
