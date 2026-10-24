# shellder-clock

Clock plugin for [Shellder](../shellder), a port of Omarchy's clock
(`/usr/share/omarchy/shell/plugins/panels/clock/`): date/time on the bar, a
calendar on click and a big clock on hover.

## On the bar

| Action        | What it does |
|---------------|--------------|
| —             | Shows the time in the configured format (default `dddd HH:mm`; on a vertical bar `HH`/`—`/`mm` stacked). Updates when the minute turns |
| hover         | A passive card with the time in big digits and live seconds (`"hover": "event"` in the manifest) |
| left click    | Opens/closes the calendar |
| right click   | Shellder's menu, declared in `manifest.json`: *Next format*, *Open calendar*, *Change timezone…*, *Copy date* |
| middle click  | `omarchy-menu-timezone` (timezone picker), as in Omarchy |

*Next format* walks the same list Omarchy's right click does, and saves it:

```
dddd HH:mm        dddd h:mm AP      HH:mm             h:mm AP
ddd d MMM HH:mm   ddd d MMM h:mm AP d MMMM 'W'ww yyyy yyyy-MM-dd HH:mm
```

Vertical: `HH\n—\nmm`, `h\n—\nmm\nAP`, `dd\nMMM\n'W'ww\n''yy`, `HH\nmm`.

## Calendar

- Today in the hero; clicking it goes back to the current month after
  browsing.
- Year progress. **Double click** the rail to enter a birth year and a life
  expectancy (Enter saves, Esc cancels, Tab switches) and get a second rail,
  *LIFE*. Double click it to hide it.
- Fixed 6-week grid with ISO week numbers. **W** flips the week start between
  Monday and Sunday (default: the locale's).
- Change month: on-screen chevrons, scroll on the grid, `←`/`→` or `[`/`]`;
  year: `↑`/`↓` or `{`/`}`; `t` or Enter goes back to today; `w` flips the
  week start; `Esc` or a click outside closes.

The popup follows Omarchy's KeyboardPanel design (through
`shellder_kit.panel.Panel`): one layer covering the output's usable area (the
bar stays outside) with the card inside; a click outside the card closes it,
and mouse and keyboard work inside. Look: the Omarchy theme from Shellder's
`config` event — font and size scale, `[popups]` colors, Hyprland's active
border color/width and rounding, control hover colors; distance from the bar
is Hyprland's `gaps_out`.

## Settings

They live in the plugin's entry in `bar.layout` of `~/.config/shellder/shell.json`,
with the same keys as `omarchy.clock` in `~/.config/omarchy/shell.json`:

```json
{
  "id": "shellder.clock",
  "format": "ddd d MMM HH:mm",
  "formatAlt": "d MMMM 'W'ww yyyy",
  "verticalFormat": "HH\n—\nmm",
  "verticalFormatAlt": "dd\nMMM\n'W'ww\n''yy",
  "weekStartDay": "monday",
  "birthYear": 1985,
  "lifeExpectancy": 90
}
```

All optional. *Next format*, **W** and *memento mori* write here (the plugin
sends `{"settings": ...}` and Shellder updates the file); editing the file by
hand applies immediately.

## Install

```bash
make install   # symlink into ~/.config/shellder/plugins/shellder-clock
make test      # model tests (dates, formats, grid)
```

Needs Python 3, PyGObject, GTK 4, gtk4-layer-shell and pycairo (all present
on Omarchy). Without GTK/layer-shell the label still works and the popups are
disabled. Uses the kit shipped with Shellder (`$SHELLDER_KIT`).

## Files

```
manifest.json      manifest (kinds: bar-widget, hover: event, right-click menu)
clock.py           entry point: label, formats, menu, hover clock
calendar_panel.py  calendar, port of Panel.qml on shellder_kit.panel.Panel
model.py           dates and formats, port of Model.js (no GTK, tested)
tests/             model.py tests
```

GTK is only loaded the first time a popup opens.
