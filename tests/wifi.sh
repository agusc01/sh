#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d)
trap 'rm -R "$workspace"' 0
mkdir -p "$workspace/bin"
cat > "$workspace/bin/iw" <<'MOCK'
#!/bin/sh
case "$1:$2:$3" in
    dev::) echo 'phy#0'; echo ' Interface wlp2s0' ;;
    dev:wlp2s0:link) printf 'Connected to aa:bb:cc:dd:ee:ff\n\tSSID: Home:5G\n' ;;
    dev:wlp2s0:scan) printf 'BSS aa:bb:cc:dd:ee:ff\n\tfreq: 2412\n\tsignal: -64.00 dBm\n\tSSID: Home:5G\n\tRSN:\n' ;;
    *) exit 1 ;;
esac
MOCK
cat > "$workspace/bin/wpa_cli" <<'MOCK'
#!/bin/sh
[ "$1" = -i ] || exit 1
case "$3" in
    ping) [ "${MOCK_WPA_DOWN:-0}" = 1 ] && exit 1; echo PONG ;;
    status) printf 'wpa_state=COMPLETED\nssid=Home:5G\n' ;;
    scan_results)
        printf 'bssid / frequency / signal level / flags / ssid\n'
        printf 'a1\t2412\t-69\t[WPA2-PSK-CCMP][ESS]\tHome:5G\n'
        printf 'b2\t5200\t-44\t[WPA2-PSK-CCMP][ESS]\tHome:5G\n'
        printf 'c3\t2462\t-78\t[ESS]\tGuest Lounge\n'
        printf 'd4\t2437\t-55\t[WPA2-PSK-CCMP][ESS]\tNew Network\n'
        ;;
    list_networks)
        printf 'network id / ssid / bssid / flags\n0\tHome:5G\tany\t[CURRENT]\n'
        [ "${MOCK_DUPLICATE:-0}" = 1 ] && printf '4\tHome:5G\tany\t\n'
        :
        ;;
    scan) echo OK ;;
    add_network) echo 3 ;;
    set_network) printf '%s:%s:%s:%s\n' "$3" "$4" "$5" "$6" >> "$MOCK_ACTION_LOG"; echo OK ;;
    select_network|disconnect|remove_network|save_config)
        printf '%s:%s\n' "$3" "${4:-}" >> "$MOCK_ACTION_LOG"
        if [ "$3" = save_config ] && [ "${MOCK_SAVE_FAIL:-0}" = 1 ]; then
            echo FAIL
        elif [ "${MOCK_ACTION_FAIL:-}" = "$3" ]; then
            echo FAIL
        else
            echo OK
        fi
        ;;
    '')
        # Simulate interactive wpa_cli without ever writing the PSK to logs.
        IFS= read -r line || exit 1
        case "$line" in
            'set_network 3 psk '*) echo 'psk via stdin:3' >> "$MOCK_ACTION_LOG"; echo OK ;;
            *) echo FAIL ;;
        esac
        ;;
    *) exit 1 ;;
esac
MOCK
cat > "$workspace/bin/wpa_passphrase" <<'MOCK'
#!/bin/sh
[ "$1" = 'New Network' ] || exit 1
IFS= read -r passphrase || exit 1
[ "$passphrase" = 'samplepass123' ] || exit 1
printf 'network={\n\t#psk=samplepass123\n\tpsk=%064d\n}\n' 0
MOCK
chmod +x "$workspace/bin/iw" "$workspace/bin/wpa_cli" "$workspace/bin/wpa_passphrase"
SH_HOME=$root; export SH_HOME
WIFI_IW="$workspace/bin/iw"; export WIFI_IW
WIFI_WPA_CLI="$workspace/bin/wpa_cli"; export WIFI_WPA_CLI
WIFI_WPA_PASSPHRASE="$workspace/bin/wpa_passphrase"; export WIFI_WPA_PASSPHRASE
WIFI_INTERFACE=wlp2s0; export WIFI_INTERFACE
MOCK_ACTION_LOG="$workspace/actions"; export MOCK_ACTION_LOG

[ "$(sh "$root/bin/wifi" list)" = "$(printf 'Home:5G\nGuest Lounge')" ]
[ "$(sh "$root/bin/wifi" saved)" = Home:5G ]
sh "$root/bin/wifi" status | grep -F 'State: connected' >/dev/null
sh "$root/bin/wifi" info 'Home:5G' | grep -F 'Signal: -44 dBm' >/dev/null
sh "$root/bin/wifi" info 'Home:5G' | grep -F 'Connected: yes' >/dev/null
sh "$root/bin/wifi" scan | grep -F 'Scan requested' >/dev/null
if sh "$root/bin/wifi" info 'Unknown network' >/dev/null; then
    echo 'Error: Unknown SSID was accepted.' >&2
    exit 1
fi

# Write commands require explicit intent and must never change unknown profiles.
if sh "$root/bin/wifi" disconnect >/dev/null 2>&1; then
    echo 'Error: Disconnect without --confirm succeeded.' >&2; exit 1
fi
if sh "$root/bin/wifi" forget-saved 'Home:5G' >/dev/null 2>&1; then
    echo 'Error: Forget without --confirm succeeded.' >&2; exit 1
fi
if sh "$root/bin/wifi" connect-saved 'Unknown' >/dev/null 2>&1; then
    echo 'Error: Unknown saved profile was accepted.' >&2; exit 1
fi
[ ! -e "$MOCK_ACTION_LOG" ] || {
    echo 'Error: Rejected actions changed wpa_supplicant.' >&2; exit 1
}

sh "$root/bin/wifi" connect-saved 'Home:5G' |
    grep -F 'Connection requested' >/dev/null
grep -Fx 'select_network:0' "$MOCK_ACTION_LOG" >/dev/null
sh "$root/bin/wifi" disconnect --confirm |
    grep -F 'disconnect requested' >/dev/null
grep -Fx 'disconnect:' "$MOCK_ACTION_LOG" >/dev/null
sh "$root/bin/wifi" forget-saved 'Home:5G' --confirm |
    grep -F 'Forgot saved profile' >/dev/null
grep -Fx 'remove_network:0' "$MOCK_ACTION_LOG" >/dev/null
grep -Fx 'save_config:' "$MOCK_ACTION_LOG" >/dev/null

: > "$MOCK_ACTION_LOG"
MOCK_DUPLICATE=1; export MOCK_DUPLICATE
if sh "$root/bin/wifi" forget-saved 'Home:5G' --confirm >/dev/null 2>&1; then
    echo 'Error: Ambiguous saved profiles were accepted.' >&2; exit 1
fi
[ ! -s "$MOCK_ACTION_LOG" ] || {
    echo 'Error: Ambiguous ID triggered a write.' >&2; exit 1
}
unset MOCK_DUPLICATE

MOCK_ACTION_FAIL=select_network; export MOCK_ACTION_FAIL
if sh "$root/bin/wifi" connect-saved 'Home:5G' >/dev/null 2>&1; then
    echo 'Error: A rejected connection was reported as successful.' >&2; exit 1
fi
unset MOCK_ACTION_FAIL

MOCK_SAVE_FAIL=1; export MOCK_SAVE_FAIL
if sh "$root/bin/wifi" forget-saved 'Home:5G' --confirm >/dev/null 2>&1; then
    echo 'Error: Failed profile persistence was reported as successful.' >&2; exit 1
fi
unset MOCK_SAVE_FAIL


# WPA2 profile enrollment consumes the password from stdin, not argv.
# All secrets here are harmless fixed fixtures used only in mocked tests.
: > "$MOCK_ACTION_LOG"
printf 'samplepass123\n' | sh "$root/bin/wifi" join-new 'New Network' |
    grep -F 'WPA2 connection requested' >/dev/null
grep -Fx 'set_network:3:ssid:4e6577204e6574776f726b' "$MOCK_ACTION_LOG" >/dev/null
grep -Fx 'psk via stdin:3' "$MOCK_ACTION_LOG" >/dev/null
grep -Fx 'save_config:' "$MOCK_ACTION_LOG" >/dev/null
grep -Fx 'select_network:3' "$MOCK_ACTION_LOG" >/dev/null
if grep -F 'samplepass123' "$MOCK_ACTION_LOG" >/dev/null; then
    echo 'Error: Wi-Fi password appeared in the action log.' >&2; exit 1
fi
: > "$MOCK_ACTION_LOG"
if printf 'badpass\n' | sh "$root/bin/wifi" join-new 'New Network' >/dev/null 2>&1; then
    echo 'Error: Bad password input succeeded.' >&2; exit 1
fi
[ ! -s "$MOCK_ACTION_LOG" ] || {
    echo 'Error: Invalid password modified a network.' >&2; exit 1
}
if printf 'samplepass123\n' | sh "$root/bin/wifi" join-new 'Guest Lounge' >/dev/null 2>&1; then
    echo 'Error: Open SSID incorrectly accepted as WPA2.' >&2; exit 1
fi
if printf 'samplepass123\n' | sh "$root/bin/wifi" join-new 'Home:5G' >/dev/null 2>&1; then
    echo 'Error: Saved SSID improperly re-enrolled.' >&2; exit 1
fi
[ ! -s "$MOCK_ACTION_LOG" ] || {
    echo 'Error: Rejected join performed network writes.' >&2; exit 1
}

MOCK_WPA_DOWN=1; export MOCK_WPA_DOWN
[ "$(sh "$root/bin/wifi" list)" = Home:5G ]
sh "$root/bin/wifi" status | grep -F 'Backend: iw (read-only)' >/dev/null
if sh "$root/bin/wifi" saved >/dev/null 2>&1; then
    echo 'Error: Saved networks must not be accessible without control socket.' >&2
    exit 1
fi
if sh "$root/bin/wifi" connect-saved 'Home:5G' >/dev/null 2>&1; then
    echo 'Error: Connecting should require a working control socket.' >&2
    exit 1
fi

sh -n "$root/bin/wifi"
sh -n "$root/lib/wifi.sh"
sh -n "$root/install.sh"
echo 'Wi-Fi backend tests passed.'
