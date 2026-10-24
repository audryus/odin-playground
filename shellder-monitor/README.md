# shellder-monitor

Port of `omarchy.monitor` (`/usr/share/omarchy/shell/plugins/panels/monitor/`)
to [Shellder](../shellder).

- Bar: `󰍹` (one output) / `󰍺` (several); scroll changes the focused output's
  brightness in 5% steps.
- Click: Display panel — brightness name + slider, text size slider
  (`omarchy-display-text-size`), scale pills valid for the focused mode
  (`omarchy-hyprland-monitor-scaling`), output list with enable/disable
  (`hl.monitor` via `hyprctl eval`). State from `omarchy-monitor-state`,
  refreshed every 5 s while open.

```bash
make install
python3 -m unittest discover -s tests
```
