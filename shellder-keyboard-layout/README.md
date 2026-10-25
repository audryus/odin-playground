# shellder-keyboard-layout

Port of Omarchy's `omarchy.keyboard-layout` bar widget
(`/usr/share/omarchy/shell/plugins/bar/widgets/KeyboardLayout.qml`, `KeyboardLayoutModel.js`)
for Shellder.

- **Bar**: the active layout's language code (`EN`, `PT`, `EO`...), caption size, 6 px
  margins. The tooltip is the full name (`English (US)`). Hidden unless the keyboard
  has more than one layout, so a single-layout install shows nothing.
- **Click**: `hyprctl switchxkblayout <keyboard> next`, on the keyboard the label
  describes.

Which keyboard: Hyprland also lists fcitx5's virtual keyboard and the ACPI buttons as
keyboards, so those are skipped. Of the rest, the plugin reads the one the last
`activelayout` event named, or else the one furthest through its layout list. It
re-reads `hyprctl -j devices` on start, on `activelayout` / `configreloaded`, and every
10 s while the seat is ambiguous: no reading yet, several keyboards, or no keymap.
Codes come from `xkbcli list --load-exotic`; layouts it doesn't know fall back to the
first three letters of the name.

## Install / test

```sh
make install                          # symlink into ~/.config/shellder/plugins/
python3 -m unittest discover -s tests
```
