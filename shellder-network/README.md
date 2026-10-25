# shellder-network

Port of `omarchy.network` (`/usr/share/omarchy/shell/plugins/panels/network/`)
to [Shellder](../shellder).

- Bar: `󰈀` ethernet, `󰤯`…`󰤨` Wi-Fi signal, `󰤮` disconnected — follows
  `nmcli monitor` events, no polling.
- Click: Network panel — hero with connection name and link speed, rotating
  phrases, QR share (Wi-Fi), speed test and Wi-Fi switch; ping, packet loss,
  receive/send rates, totals, IP and gateway (click to copy); Wi-Fi band
  selector (`omarchy-network-band`); DNS provider pills (`omarchy-dns`,
  *Custom* opens Omarchy's floating terminal); Wi-Fi networks (known first,
  then by signal) with connect, passphrase prompt, disconnect and forget.
- While open: details every 1.5 s (`omarchy-network-status --verbose`), band
  every 4 s, as in the original. QR and speed test summon Omarchy's own
  overlays through `omarchy-shell`. Keys: `r` refresh, `w` Wi-Fi on/off.

Wi-Fi goes through `nmcli` (Omarchy uses quickshell's NetworkManager
service). The Wi-Fi parts are untested on a wired-only machine.

```bash
make install
python3 -m unittest discover -s tests
```
