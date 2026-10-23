#!/bin/sh
# Wi-Fi inspection for Alpine Linux, compatible with BusyBox ash.
# Use wpa_cli if its control socket is accessible, otherwise fall back to iw.

wifi_interface() {
    if [ -n "${WIFI_INTERFACE:-}" ]; then
        printf '%s\n' "$WIFI_INTERFACE"
        return 0
    fi
    command -v "${WIFI_IW:-iw}" >/dev/null 2>&1 || {
        echo 'Error: iw is missing; install it through init-alpine.' >&2
        return 1
    }
    iface=$("${WIFI_IW:-iw}" dev 2>/dev/null |
        awk '$1 == "Interface" { print $2; exit }')
    [ -n "$iface" ] || {
        echo 'Error: No Wi-Fi interface found. Set WIFI_INTERFACE if necessary.' >&2
        return 1
    }
    printf '%s\n' "$iface"
}

wifi_control_available() {
    command -v "${WIFI_WPA_CLI:-wpa_cli}" >/dev/null 2>&1 || return 1
    [ "$("${WIFI_WPA_CLI:-wpa_cli}" -i "$1" ping 2>/dev/null)" = PONG ]
}

wifi_current_ssid() {
    current_iface=$1
    if wifi_control_available "$current_iface"; then
        "${WIFI_WPA_CLI:-wpa_cli}" -i "$current_iface" status 2>/dev/null |
            awk -F= '
                $1 == "wpa_state" && $2 == "COMPLETED" { completed=1 }
                $1 == "ssid" { sub(/^[^=]*=/, ""); name=$0 }
                END { if (completed) print name }'
    else
        "${WIFI_IW:-iw}" dev "$current_iface" link 2>/dev/null |
            sed -n 's/^[[:space:]]*SSID: //p' | sed -n '1p'
    fi
}

wifi_status() {
    iface=$(wifi_interface) || return 1
    ssid=$(wifi_current_ssid "$iface") || return 1
    printf 'Interface: %s\n' "$iface"
    if [ -n "$ssid" ]; then
        printf 'State: connected\nSSID: %s\n' "$ssid"
    else
        printf 'State: disconnected\n'
    fi
    if wifi_control_available "$iface"; then
        echo 'Backend: wpa_supplicant'
    else
        echo 'Backend: iw (read-only)'
    fi
}

# Print TSV: SSID, signal in dBm, security, frequency in MHz.
wifi_scan_data() {
    iface=$(wifi_interface) || return 1
    if wifi_control_available "$iface"; then
        raw=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$iface" scan_results 2>/dev/null) || {
            echo 'Error: Could not read wpa_supplicant scan results.' >&2
            return 1
        }
        printf '%s\n' "$raw" | awk -F '\t' '
            NR > 1 && NF >= 5 {
                name=$5
                for (i=6; i<=NF; i++) name=name " " $i
                if (name != "" && name !~ /[\r\n]/)
                    print name "\t" $3 "\t" $4 "\t" $2
            }'
    else
        # An iw scan usually requires CAP_NET_ADMIN. Never elevate automatically.
        raw=$("${WIFI_IW:-iw}" dev "$iface" scan 2>/dev/null) || {
            echo 'Error: Scan unavailable. Configure an accessible wpa_supplicant control socket, or grant explicit scan permissions.' >&2
            return 1
        }
        printf '%s\n' "$raw" | awk '
            function emit() {
                if (name != "") print name "\t" signal "\t" security "\t" frequency
            }
            /^BSS / { emit(); name=""; signal="?"; frequency="?"; security="open" }
            /^[[:space:]]*SSID: / { sub(/^[[:space:]]*SSID: /, ""); name=$0 }
            /^[[:space:]]*signal: / { signal=$2 }
            /^[[:space:]]*freq: / { frequency=$2 }
            /^[[:space:]]*RSN:/ { security="WPA2/WPA3" }
            /^[[:space:]]*WPA:/ { if (security == "open") security="WPA" }
            END { emit() }'
    fi
}

wifi_list() {
    rows=$(wifi_scan_data) || return 1
    printf '%s\n' "$rows" |
        awk -F '\t' 'NF >= 4 && $1 != "" && !seen[$1]++ { print $1 }'
}

wifi_info() {
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        echo 'Usage: wifi_info SSID' >&2
        return 2
    }
    WIFI_SELECTED=$1
    export WIFI_SELECTED
    rows=$(wifi_scan_data) || return 1
    iface=$(wifi_interface) || return 1
    WIFI_CONNECTED=$(wifi_current_ssid "$iface") || return 1
    export WIFI_CONNECTED
    printf '%s\n' "$rows" | awk -F '\t' '
        NF >= 4 && $1 == ENVIRON["WIFI_SELECTED"] {
            level=$2+0
            if (!found || level > best) {
                found=1; best=level; signal=$2; security=$3; frequency=$4
            }
        }
        END {
            if (!found) { print "Network not found in scan results."; exit 1 }
            print "SSID: " ENVIRON["WIFI_SELECTED"]
            print "Signal: " signal " dBm"
            print "Security: " security
            print "Frequency: " frequency " MHz"
            print "Connected: " (ENVIRON["WIFI_CONNECTED"] == ENVIRON["WIFI_SELECTED"] ? "yes" : "no")
        }'
}

wifi_saved() {
    iface=$(wifi_interface) || return 1
    wifi_control_available "$iface" || {
        echo 'Error: Saved networks require access to the wpa_supplicant control socket.' >&2
        return 1
    }
    rows=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$iface" list_networks 2>/dev/null) || return 1
    printf '%s\n' "$rows" |
        awk -F '\t' 'NR > 1 && NF >= 2 && $2 != "" && !seen[$2]++ { print $2 }'
}

wifi_scan() {
    iface=$(wifi_interface) || return 1
    if wifi_control_available "$iface"; then
        result=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$iface" scan 2>/dev/null) || return 1
        [ "$result" = OK ] || {
            echo "Error: Scan rejected: $result" >&2
            return 1
        }
        echo 'Scan requested; cached results may need a few seconds to update.'
    else
        "${WIFI_IW:-iw}" dev "$iface" scan >/dev/null || {
            echo 'Error: Wi-Fi scan failed; check permissions.' >&2
            return 1
        }
        echo 'Scan completed.'
    fi
}
