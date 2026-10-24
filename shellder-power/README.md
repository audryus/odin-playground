# shellder-power

Port of `omarchy.power` (`/usr/share/omarchy/shell/plugins/panels/power/`) to
[Shellder](../shellder): battery, power profile and system stats.

| Action      | What it does |
|-------------|--------------|
| —           | Battery icon (charging / discharging / full / charge-threshold glyphs from Omarchy's Model.js). **Hidden when there is no battery**, as in Omarchy |
| left click  | Power panel: hero with rotating status phrases and the percentage, charge bar, battery size, cycles, time left/to full, rate, and the power profile buttons |
| right click | Toggles `showPercentage` (`"NN% icon"` on the bar), saved in `shell.json` |

The panel refreshes every 5 s while open; `←`/`→` switch profiles. Data:
UPower over D-Bus (`DisplayDevice`, `OnBattery`; live through
`PropertiesChanged`) and the same scripts Omarchy uses —
`omarchy-battery-status --shell`, `omarchy-powerprofiles-list --active-state`,
`omarchy-powerprofiles-set <ac|battery> <profile>`, `omarchy-system-stats`.

Settings (`shell.json` entry): `{"id": "shellder.power", "showPercentage": true}`.

```bash
make install
python3 -m unittest discover -s tests   # Model.js port
```
