# shellder-weather

Port of `omarchy.weather` (`/usr/share/omarchy/shell/plugins/panels/weather/`)
to [Shellder](../shellder).

| Action       | What it does |
|--------------|--------------|
| —            | Current-condition glyph (hidden until there is data) |
| left click   | Weather panel: big glyph and temperature, location (click it to search a city; Esc cancels), feels / wind / humidity, 3-day forecast |
| right click  | Notification with `omarchy-weather-status`, as in Omarchy |
| middle click | Refresh |

Data as in the original: open-meteo for current conditions and the daily
forecast (and for the bar glyph), wttr.in for the auto-detected location and
as fallback; city search through open-meteo geocoding. The location is stored
in Omarchy's own `~/.local/state/omarchy/settings/weather.json` (through
`omarchy-weather-location`), so it is shared with the Omarchy bar.

Settings (`shell.json` entry, same keys as `omarchy.weather`):
`{"id": "shellder.weather", "unit": "metric", "refreshMinutes": 15}`.

Note: Omarchy's icon table double-escapes the fog glyphs (`"\\ue346"`), which
renders a literal `` there; this port uses the intended glyphs.

```bash
make install
python3 -m unittest discover -s tests
```
