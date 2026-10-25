# shellder-network

Port of `omarchy.network` (`/usr/share/omarchy/shell/plugins/panels/network/`)
to [Shellder](../shellder).

- Bar: `󰈀` ethernet, `󰤯`…`󰤨` Wi-Fi signal, `󰤮` disconnected — follows
  `nmcli monitor` events, no polling.
- Click: Network panel (`panel.py`, its own process: see below) — hero with connection name and link speed, rotating
  phrases, QR share (Wi-Fi), speed test and Wi-Fi switch; ping, packet loss,
  receive/send rates, totals, IP and gateway (click to copy); Wi-Fi band
  selector (`omarchy-network-band`); DNS provider pills (`omarchy-dns`,
  *Custom* opens Omarchy's floating terminal); Wi-Fi networks (known first,
  then by signal) with connect, passphrase prompt, disconnect and forget.
- While open: details every 1.5 s (`omarchy-network-status --verbose`), band
  every 4 s, as in the original. QR and speed test summon Omarchy's own
  overlays through `omarchy-shell`. Keys: `r` refresh, `w` Wi-Fi on/off.

Two processes: `network.py` keeps the bar icon and loads no GUI toolkit
(~6 MiB); `panel.py` is the panel (`entryPoints.panel`, `barWidget.panel:
"process"`), which Shellder starts on the click and ends when the panel is
dismissed, and which exits on `Esc` or a click outside — GTK's ~39 MiB exist
only while the panel is on screen. Before, the panel lived in the bar process
and kept it at ~36 MiB after the first open.

Wi-Fi goes through `nmcli` (Omarchy uses quickshell's NetworkManager
service). The Wi-Fi parts are untested on a wired-only machine.

```bash
make install
python3 -m unittest discover -s tests
```
