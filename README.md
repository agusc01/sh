# sh

Lightweight POSIX `sh` commands for Alpine Linux, independent of Fish,
Bash, NetworkManager, `linux-tools`, `linux-setup`, and `linux-doctor`.

## First module: read-only Wi-Fi

`sh` does not install OS packages or change network services. The existing
`init-alpine/basics/wifi/install.sh` already installs `iw` and
`wpa_supplicant` (including `wpa_cli`).

```sh
git clone https://github.com/agusc01/sh "$HOME/.config/sh"
cd "$HOME/.config/sh"
sh install.sh
wifi_status
wifi_list
wifi_info "Your network name"
wifi_saved
wifi_scan
```

The installer creates `wifi`, `wifi_status`, `wifi_list`, `wifi_info`,
`wifi_saved`, and `wifi_scan` under `~/.local/bin`. It checks for name
collisions before installing and never overwrites unrelated commands.
Re-run the installer after updating the repository.

These commands are independent of dmenu and fzf. An interface is selected
automatically using `iw dev`, or set `WIFI_INTERFACE=wlan0`.

- `wifi_status`: interface, state, SSID, and active inspection method.
- `wifi_list`: unique SSIDs from wpa_supplicant cached scan results or `iw`.
- `wifi_info "SSID"`: strongest visible access point's signal, frequency,
  security flags and whether that SSID is connected.
- `wifi_saved`: saved network **names only**, not credentials.
- `wifi_scan`: request a new scan; wpa_supplicant cache updates asynchronously.

A reachable `wpa_cli` control socket is necessary for nonprivileged cached
scans and `wifi_saved`. Without one, scripts fall back to `iw` where possible.
`iw dev IFACE scan` often requires elevated permissions; the scripts try `iw dev IFACE scan dump` first. This installer
does not add privileged rules, modify `ctrl_interface`, or enable network
management. Alpine's [Wi-Fi guide](https://wiki.alpinelinux.org/wiki/Wi-Fi)
documents the optional control socket and its access permissions; granting
access also grants network control privileges, so do not do it casually.

All operations are read-only **except** `wifi_scan`, which triggers a Wi-Fi
scan without intentionally changing the connection. Connect, disconnect, and
power operations are reserved for a separate milestone after reviewing
credentials, permissions and DHCP.

Tests with mocked `iw` and `wpa_cli` (do not modify networking):

```sh
sh tests/wifi.sh
```
