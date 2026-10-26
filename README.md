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

### Temporary WPA2 connection without persistent configuration

When `wpa_cli save_config` returns `FAIL`, the current daemon may not have
`update_config=1` enabled, or cannot write its actual configuration file.
Do not silently turn on persistent writes or loosen the control socket permissions.

`wifi_join_new --temporary 'SSID'` uses the same masked-stdin password flow
but intentionally skips both `save_config` calls. It adds an in-memory network
profile and requests `select_network`; the profile may disappear after restarting
`wpa_supplicant`. It may interrupt the current Wi-Fi connection and does not
guarantee DHCP/IP assignment. This is an explicit alternative, not an automatic
fallback from a failed persistent join. The normal `wifi_join_new 'SSID'`
continues to abort before switching if its first `save_config` fails.

To inspect the usual Alpine configuration without printing passwords:

```sh
ps | grep '[w]pa_supplicant'
doas grep -nE '^[[:space:]]*update_config[[:space:]]*=' /etc/wpa_supplicant/wpa_supplicant.conf
```

Check the actual `-c` path in the running process before assuming the above
file is in use. A missing or zero `update_config` disables persistence.
Editing the active root-managed file and restarting the daemon should be a
separate deliberate admin task, since restarting drops the current association.


## Wi-Fi IP status, Internet checks, and DHCP renewal (Alpine)

Wi-Fi association, an IPv4 address, a default route, DNS and Internet access
are separate states. Alpine typically uses ifupdown-ng and BusyBox udhcpc.

Read-only diagnostic commands:

    wifi_status
    wifi_ip_status
    wifi_internet_status

wifi_ip_status reports the IPv4 address and default route using BusyBox-
compatible ip addr show and ip route syntax (not ip -br). The Internet
test contacts 1.1.1.1 using two ICMP pings and looks up example.com via
the configured DNS resolver. Both checks are run only on explicit request,
never during the per-SSID preview. A failed ICMP probe cannot conclusively
prove Internet connectivity is absent.

To request a DHCP renewal from an existing BusyBox udhcpc process:

    wifi_dhcp_renew --confirm
    wifi_ip_status

This sends USR1 to one verified matching udhcpc process and may request
doas authorization. It refuses missing or ambiguous clients and never
starts a second DHCP process, flushes addresses, or restarts networking.
For dhcpcd or custom managers use their existing configuration instead.

For automatic DHCP handling after a Wi-Fi association changes, Alpine
documents the wpa_cli action service and the bundled action script at
/etc/wpa_supplicant/wpa_cli.sh. Inspect before enabling it:

    ps | grep '[w]pa_cli'
    rc-service wpa_cli status
    ls -l /etc/wpa_supplicant/wpa_cli.sh
    cat /etc/conf.d/wpa_cli

Alpine guidance: https://wiki.alpinelinux.org/wiki/Wi-Fi

## Enable persistent saved networks (explicit administrator action)

A running wpa_supplicant without update_config=1 normally refuses
save_config. The opt-in script NEVER reloads or restarts the daemon.

Inspect the exact -c configuration path of your running daemon:

    ps | grep '[w]pa_supplicant'

Then inspect the usual root-owned file WITHOUT printing passwords:

    doas sh ~/.config/sh/scripts/enable-wpa-saving.sh --check

Once a fallback saved connection is available, deliberately allow saving:

    doas sh ~/.config/sh/scripts/enable-wpa-saving.sh --enable --confirm

The script refuses symlinks, non-root ownership, duplicated directives,
and inaccessible configs. It creates a 0600 backup and 0600 replacement
in the same directory without echoing secrets; it never restarts Wi-Fi.

Enabling the file does not change the currently running daemon.
When ready for a possible interruption/loss of temporary profiles:

    wpa_cli -i wlan0 reconfigure
    wifi_status
    wpa_cli -i wlan0 save_config

The active profile may reconnect or change, and save_config may rewrite
comments in the file; keep the private backup. Never loosen control
socket permissions to make it work. After successful save_config, new
profiles can use the existing "Join WPA2 and save" menu option.

Test the new IP/DHCP logic with mocks (NO real network changes):

    sh tests/wifi-net.sh

This PR is stacked on the join-new Wi-Fi feature branch. Merge in order.

### Confirmed Alpine notebook: start existing wpa_cli action service

Notebook verification showed:
- `wpa_cli -i wlan0 reconfigure` and `save_config` both return OK.
- `/etc/conf.d/wpa_cli` already sets WPACLI_OPTS to the packaged
  `/etc/wpa_supplicant/wpa_cli.sh` action script.
- BusyBox `udhcpc` is running with `-i wlan0` and a matching PID file;
  the action script references that PID file and signals its client.
- `rc-service wpa_cli status` was stopped and `sh tests/wifi-net.sh` passed.

Therefore, prefer the packaged OpenRC action service instead of inventing
a second background DHCP monitor:

    doas rc-service wpa_cli start
    rc-service wpa_cli status
    ps | grep '[w]pa_cli'

The service may request a DHCP renewal on association events. Run the
commands locally since connectivity could briefly change. Once tested:

    doas rc-update add wpa_cli default

Test a deliberate Wi-Fi switch, then verify `wifi_status`, `wifi_ip_status`,
`ip route`, and `wifi_internet_status`. The IP address and gateway must
correspond to the current access point; `wpa_state=COMPLETED` by itself
does not prove DHCP or Internet connectivity.

Do not run `wifi_dhcp_renew --confirm` on every switch when this event
service is already handling DHCP: it is a manual recovery command only.
