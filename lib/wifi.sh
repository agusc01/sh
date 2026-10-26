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
        echo 'Error: No wireless interface reported by iw dev.' >&2
        echo 'Check hardware/driver visibility. VirtualBox NAT and bridged adapters are Ethernet, not Wi-Fi.' >&2
        echo 'Set WIFI_INTERFACE only when a real wireless interface exists.' >&2
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
        # Inspect cached scan results first; an active scan may need
        # CAP_NET_ADMIN. Never elevate automatically or restart services.
        raw=$("${WIFI_IW:-iw}" dev "$iface" scan dump 2>/dev/null) || raw=''
        if [ -z "$raw" ]; then
            raw=$("${WIFI_IW:-iw}" dev "$iface" scan 2>/dev/null) || {
                echo 'Error: Scan unavailable. Configure an accessible wpa_supplicant control socket, or grant explicit scan permissions.' >&2
                return 1
            }
        fi
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


# Network-changing commands require an already configured, accessible
# wpa_supplicant control interface. Never invoke doas or start a daemon.
wifi_wpa_interface() {
    write_iface=$(wifi_interface) || return 1
    wifi_control_available "$write_iface" || {
        echo 'Error: Wi-Fi changes require access to the wpa_supplicant control socket.' >&2
        return 1
    }
    printf '%s\n' "$write_iface"
}

wifi_wpa_expect_ok() {
    expect_iface=$1
    shift
    expect_command=$1
    shift
    expect_result=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$expect_iface" "$expect_command" "$@" 2>/dev/null) || {
        printf 'Error: wpa_supplicant command %s failed.\n' "$expect_command" >&2
        return 1
    }
    [ "$expect_result" = OK ] || {
        printf 'Error: wpa_supplicant rejected %s (%s).\n' "$expect_command" "$expect_result" >&2
        return 1
    }
}

# Resolve a saved SSID to exactly one network ID. Refuse ambiguous profiles,
# missing profiles, and unexpected replies rather than guessing a network ID.
wifi_saved_id() {
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        echo 'Usage: wifi_saved_id SSID' >&2
        return 2
    }
    saved_iface=$(wifi_wpa_interface) || return 1
    saved_rows=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$saved_iface" list_networks 2>/dev/null) || {
        echo 'Error: Could not list saved Wi-Fi profiles.' >&2
        return 1
    }
    WIFI_LOOKUP_SSID=$1
    export WIFI_LOOKUP_SSID
    saved_id=$(printf '%s\n' "$saved_rows" | awk -F '\t' '
        NR > 1 && NF >= 2 && $2 == ENVIRON["WIFI_LOOKUP_SSID"] {
            id=$1
            if (++count > 1) exit
        }
        END {
            if (count > 1) print "AMBIGUOUS"
            else if (count == 1) print id
        }')
    case "$saved_id" in
        '')
            printf 'Error: Network is not saved: %s\n' "$1" >&2
            return 1
            ;;
        AMBIGUOUS)
            printf 'Error: Multiple saved profiles use SSID %s; choose a network ID manually using wpa_cli.\n' "$1" >&2
            return 1
            ;;
        *[!0-9]*)
            echo 'Error: Invalid saved network ID reported by wpa_supplicant.' >&2
            return 1
            ;;
    esac
    printf '%s\n' "$saved_id"
}

wifi_connect_saved() {
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        echo 'Usage: wifi_connect_saved SSID' >&2
        return 2
    }
    connect_id=$(wifi_saved_id "$1") || return 1
    connect_iface=$(wifi_wpa_interface) || return 1
    # select_network intentionally disables other profiles in wpa_supplicant.
    wifi_wpa_expect_ok "$connect_iface" select_network "$connect_id" || return 1
    printf 'Connection requested for %s. Check wifi_status; DHCP/IP is managed separately.\n' "$1"
}

wifi_disconnect() {
    [ "$#" -eq 1 ] && [ "$1" = --confirm ] || {
        echo 'Usage: wifi_disconnect --confirm' >&2
        return 2
    }
    disconnect_iface=$(wifi_wpa_interface) || return 1
    wifi_wpa_expect_ok "$disconnect_iface" disconnect || return 1
    echo 'Wi-Fi disconnect requested. Automatic reconnection is paused until another connect/reconnect command.'
}

wifi_forget_saved() {
    [ "$#" -eq 2 ] && [ -n "$1" ] && [ "$2" = --confirm ] || {
        echo 'Usage: wifi_forget_saved SSID --confirm' >&2
        return 2
    }
    forget_id=$(wifi_saved_id "$1") || return 1
    forget_iface=$(wifi_wpa_interface) || return 1
    wifi_wpa_expect_ok "$forget_iface" remove_network "$forget_id" || return 1
    if ! wifi_wpa_expect_ok "$forget_iface" save_config; then
        echo 'WARNING: Profile removed from the running daemon but NOT saved to disk.' >&2
        echo 'Check update_config=1 and write permissions before relying on persistence.' >&2
        return 1
    fi
    printf 'Forgot saved profile: %s\n' "$1"
}
