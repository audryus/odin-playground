# shellder-indicators

Port of `omarchy.indicators` (`/usr/share/omarchy/shell/plugins/bar/widgets/Indicators.qml`
and `plugins/bar/indicators/*.qml`) to [Shellder](../shellder).

| Indicator         | Active when                         | Click |
|-------------------|-------------------------------------|-------|
| `Dictation`       | voxtype is recording/transcribing   | `omarchy-voxtype-config` |
| `ScreenRecording` | `gpu-screen-recorder` is running    | stop recording / open the recording menu |
| `Reminder`        | there are pending reminders         | show them / create one |
| `NightLight`      | hyprsunset is below 6000 K          | `omarchy-toggle-nightlight` |
| `Dnd`             | notifications are silenced          | `omarchy-toggle-notification-silencing` |
| `StayAwake`       | idle lock/screensaver is disabled   | `omarchy-toggle-idle` |

Active indicators always show, newest first; inactive ones appear only while
the pointer is over the item, at 45% opacity, as in Omarchy (`BarIndicator.qml`).
Each one sits in a `statusSlot`-wide slot with the `caption` font size.

Settings (the plugin's entry in `~/.config/shellder/shell.json`, same keys as
`omarchy.indicators`):

```json
{"id": "shellder.indicators", "items": ["Dnd", "NightLight", "StayAwake"], "alwaysShow": false}
```

Omarchy reads these states through quickshell services; here they come from
outside: `~/.local/state/omarchy/notifications.json` (dnd),
`~/.local/state/omarchy/indicators/stay-awake`, the hyprsunset socket, `/proc`
and the `omarchy-reminder` / `omarchy-voxtype-status` scripts. Polling is once
per second (reminders every 15 s) and spawns no process except for reminders.

Omarchy reveals inactive indicators when hovering the whole center section;
Shellder only reports hover over the item itself, so with nothing active the
item keeps one invisible slot as a hover target.

```bash
make install   # symlink into ~/.config/shellder/plugins/shellder-indicators
```

Uses the Python kit shipped with Shellder (`$SHELLDER_KIT`).
