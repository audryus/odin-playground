# shellder-tray

Port of Omarchy's `omarchy.tray` bar widget
(`/usr/share/omarchy/shell/plugins/bar/widgets/Tray.qml`, `TrayModel.js`) for Shellder:
the StatusNotifierItem system tray.

- **Bar**: pinned icons are always shown. The others sit in a drawer behind a chevron
  (U+F053) that slides open while the pointer is over the chevron or the drawer (600 ms
  ease-out, like Waybar's tray-expander). The drawer's space is reserved, so nothing
  else on the bar moves. Hidden while no item is reporting. Passive items never show;
  LocalSend's item is skipped, as in Omarchy.
- **Icons**: left click → `Activate` (items that are only a menu open it), middle →
  `SecondaryActivate`, right → the item's menu, wheel → `Scroll`. Tooltip: the item's
  tooltip title, title or id.
- **Item menu**: the app's `com.canonical.dbusmenu`, drawn by the plugin like Omarchy's
  card: check marks, icons, disabled rows, separators, and submenus opened in place with a
  `‹ Title` row to go back (clicks are ignored for 250 ms after a level change). Items
  without a dbusmenu get `ContextMenu` and show their own.
- **Chevron, right click**: "Tray icons", with Pin/Unpin and Hide/Show for each item.

## Settings (`shell.json`, same keys as omarchy.tray)

```json
{ "id": "shellder.tray", "pinned": ["steam"], "hidden": ["nm-applet"] }
```

Lists of item ids; the popup above writes them.

## D-Bus

The plugin works alongside another shell: when `org.kde.StatusNotifierWatcher` is owned
(Omarchy's Quickshell owns it), it registers as a host and follows that watcher's items.
Otherwise it becomes the watcher itself. It queues for the name, so it takes over when
the other shell exits, and the apps re-register on their own.

Icons come from the GTK icon theme (plus the item's `IconThemePath`) or the item's
pixmaps. They are cached as PNGs in `$XDG_RUNTIME_DIR/shellder-tray-<pid>/` and passed
to the bar as image segments. Symbolic icons take the bar text color.

Not ported: Omarchy also hides Dropbox when its `omarchy.dropbox` widget is in the
layout. Shellder has no dropbox widget, so that rule is not needed.

## Install / test

```sh
make install                          # symlink into ~/.config/shellder/plugins/
python3 -m unittest discover -s tests
```
