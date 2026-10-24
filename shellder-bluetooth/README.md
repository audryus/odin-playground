# shellder-bluetooth

Port of `omarchy.bluetooth` (`/usr/share/omarchy/shell/plugins/panels/bluetooth/`)
to [Shellder](../shellder).

| Action      | What it does |
|-------------|--------------|
| —           | `󰂯` on, `󰂱` a device connected, `󰂲` off; hidden without an adapter |
| left click  | Bluetooth panel: hero with rotating phrases and a power switch; CONNECTED, PAIRED and (while scanning) AVAILABLE rows. Click a row to connect / pair / disconnect; the trash button (on hover) forgets it |
| right click | Bluetooth on/off (`omarchy-bluetooth-power`) |

`b` in the panel toggles power. BlueZ is read over D-Bus (`org.bluez`
ObjectManager, live via InterfacesAdded/Removed and PropertiesChanged;
battery from `Battery1`). Discovery runs only while the panel is open,
retried every second as in the original, and stops when it closes. Actions
use `omarchy-bluetooth-device pair|connect|disconnect|forget <address>`.

```bash
make install
python3 -m unittest discover -s tests
```
