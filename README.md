# sh

Lightweight POSIX `sh` commands for Alpine Linux, independent of Fish,
Bash, NetworkManager, `linux-tools`, `linux-setup`, and `linux-doctor`.

## Wi-Fi inspection and saved-profile management

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
`wifi_saved`, `wifi_scan`, `wifi_connect_saved`, `wifi_disconnect`,
and `wifi_forget_saved` under `~/.local/bin`. It checks for name
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

Inspection commands are read-only **except** `wifi_scan`, which requests a
scan without intentionally changing the connection.

### Saved-profile actions (explicit network changes)

These commands act only on already-saved wpa_supplicant network profiles. They
never request passwords, edit configuration files directly, invoke `doas`, or
restart network services. They need a working, appropriately permissioned
wpa_supplicant control socket. Access to that socket grants powerful network
control; never loosen its filesystem permissions just to run these commands.

```sh
wifi_saved
wifi_connect_saved 'Home:5G'
wifi_status   # association is asynchronous
wifi_disconnect --confirm
wifi_forget_saved 'Old network' --confirm
```

- `wifi_connect_saved SSID` issues `select_network <ID>` for exactly one
  matching saved profile. This **temporarily disables other configured
  profiles** in wpa_supplicant. It reports that the connection was **requested**,
  not that authentication or IP configuration succeeded.
- `wifi_disconnect --confirm` explicitly drops the association and pauses
  automatic reconnection until a later network control action.
- `wifi_forget_saved SSID --confirm` removes the profile from the live daemon,
  then tries `save_config`. Persistence requires `update_config=1` and
  write permissions; if saving fails, the command returns an error and warns
  that the profile may reappear after restarting wpa_supplicant.
- If multiple saved profiles have the same SSID, selection and removal fail
  rather than guessing which numeric profile to change.
- DHCP, routes, and DNS remain managed by Alpine's existing networking setup.
  wpa_supplicant association alone does not guarantee an IP address. Depending
  on Alpine configuration, you may need its existing `wpa_cli` action hook or
  networking service to trigger DHCP on network changes.

Creating **new** Wi-Fi profiles, handling WPA2/WPA3 passphrases, and masked
password prompts are deliberately outside this initial write-enabled step.
Do not type a new network password into a normal dmenu input field; it is not
masked. This milestone makes saved networks manageable without exposing secrets.


Tests with mocked `iw` and `wpa_cli` (do not modify networking):

```sh
sh tests/wifi.sh
```


### Join a new WPA2-Personal network (preview milestone)

`wifi_join_new SSID` expects a passphrase **on standard input**, never
as a command-line argument. Supported networks must be visible in the
current wpa_supplicant scan cache and explicitly advertise WPA2-PSK.
Open, WPA3-only (SAE-only), WEP and enterprise networks are rejected.
WPA2/WPA3 transition hotspots (for example `[WPA2-PSK+SAE-CCMP]`) are
supported through their advertised WPA2-PSK method; we explicitly set
`key_mgmt WPA-PSK` to avoid accidentally using the SAE method.

Use the **masked** `dmenu_wifi` prompt (suckless `-P`) or the no-echo
`fzf_wifi` terminal prompt. Do not enter a Wi-Fi password in a normal
terminal command, a command-line argument, a shell history entry, or an
unmasked dmenu prompt. The backend rejects direct terminal stdin to prevent
accidental echoing.

The password flows over stdin to the backend, which sends a quoted
passphrase directly to interactive `wpa_cli` via stdin (never as a
command-line argument). This avoids a compatibility problem: some recent
`wpa_passphrase` builds require a TTY on stdin and reject secure pipes.
No temporary password files are used. The resulting `wpa_supplicant`
configuration **can contain the original passphrase in plaintext**
when `save_config` runs; keep that system file accessible only to root
or other deliberately authorized administrators.

In this first secure-input milestone passwords must be 8–63 printable
ASCII bytes. Double quotes and backslashes are rejected until escaping
can be audited and tested for the interactive `wpa_cli` parser. Error
messages distinguish invalid password length from a rejected
`wpa_supplicant` configuration command.

Joining a new network can interrupt the current Wi-Fi link, because
`select_network` disables the other network profiles while switching.
Enrollment saves the new profile before requesting the switch, then saves
the newly enabled state again. Status, authentication, DHCP and DNS must
be verified separately; the script does not restart networking or configure
routes. A wrong password may leave the notebook without Wi-Fi until you
reselect the previous saved profile.

This is not yet a general enterprise or WPA3 configuration system.

For a nonsecret eligibility check, run `wifi_join_supported 'SSID'` (or
`wifi join-supported 'SSID'`). It returns success only if cached scans
confirm WPA2-PSK capability without EAP, WEP or OWE ambiguity.
SAE is permitted *only when the same entry also advertises WPA2-PSK*
(as in a WPA2/WPA3 transition hotspot). If it fails,
request `wifi_scan`, then inspect `wifi_info 'SSID'` before attempting
enrollment. The graphical and terminal menus use this same check to avoid
prompting for passwords on unsupported networks.
