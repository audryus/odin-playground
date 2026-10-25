# shellder-system-update

Port of Omarchy's `omarchy.system-update` bar widget
(`/usr/share/omarchy/shell/plugins/bar/widgets/SystemUpdate.qml`) for Shellder.

- **Bar**: U+F021 in a `statusSlot`, caption size, with the tooltip "Pending
  Omarchy Updates". Shown only while `omarchy-update-available` exits 0.
- **Click**: `omarchy-launch-floating-terminal-with-presentation omarchy-update`.

Checks on start and every 6 hours, as Omarchy does. Omarchy also refreshes when
`omarchy-update-status` sends its `refresh`/`clear` IPC after an update. Shellder has no
IPC, so instead the check re-runs 5 s after the pacman database (`/var/lib/pacman/local`)
changes, i.e. after any install, update or removal.

## Install

```sh
make install    # symlink into ~/.config/shellder/plugins/
```
