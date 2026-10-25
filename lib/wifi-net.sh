#!/bin/sh
# Alpine Wi-Fi IP diagnostics. Nothing here runs unless explicitly requested.

wifi_ip_status() {
    [ "$#" -eq 0 ] || { echo 'Usage: wifi_ip_status' >&2; return 2; }
    net_iface=$(wifi_interface) || return 1
    net_addr=$(ip addr show "$net_iface" 2>/dev/null) || {
        echo 'Error: Could not inspect IPv4 address.' >&2; return 1
    }
    net_ipv4=$(printf '%s\n' "$net_addr" | awk '$1 == "inet" { print $2; exit }')
    net_route=$(ip route 2>/dev/null | awk -v dev="$net_iface" '
        $1 == "default" {
            for (i = 1; i < NF; i++)
                if ($i == "dev" && $(i+1) == dev) { print; exit }
        }')
    printf 'Interface: %s\n' "$net_iface"
    printf 'IPv4: %s\n' "${net_ipv4:-none}"
    printf 'Default route: %s\n' "${net_route:-none for this interface}"
    [ -n "$net_ipv4" ] && [ -n "$net_route" ] || {
        echo 'Warning: no confirmed IPv4 address/default route. Check DHCP or static IP.'
        return 1
    }
}

wifi_internet_status() {
    [ "$#" -eq 0 ] || { echo 'Usage: wifi_internet_status' >&2; return 2; }
    # Explicit opt-in network probes, never run while moving over SSIDs.
    wifi_ip_status || return 1
    probe_ip=${WIFI_PROBE_IP:-1.1.1.1}
    probe_host=${WIFI_PROBE_HOST:-example.com}
    if ping -c 2 -W 2 "$probe_ip" >/dev/null 2>&1; then
        printf 'IP probe (%s): reachable\n' "$probe_ip"
        ip_ok=1
    else
        printf 'IP probe (%s): no ICMP response (Internet not confirmed)\n' "$probe_ip"
        ip_ok=0
    fi
    if nslookup "$probe_host" >/dev/null 2>&1; then
        printf 'DNS probe (%s): resolved\n' "$probe_host"
        dns_ok=1
    else
        printf 'DNS probe (%s): failed\n' "$probe_host"
        dns_ok=0
    fi
    [ "$ip_ok" -eq 1 ] && [ "$dns_ok" -eq 1 ]
}

wifi_udhcpc_pid() {
    # Match udhcpc's interface argument exactly by examining /proc, not ps.
    match_iface=$1
    proc_root=${WIFI_PROC_ROOT:-/proc}
    matched=''
    for procpath in "$proc_root"/[0-9]*; do
        [ -r "$procpath/cmdline" ] || continue
        args=$(tr '\000' '\n' < "$procpath/cmdline") || continue
        [ -n "$args" ] || continue
        first=$(printf '%s\n' "$args" | sed -n '1p')
        second=$(printf '%s\n' "$args" | sed -n '2p')
        case "${first##*/}" in
            udhcpc) ;;
            busybox) [ "$second" = udhcpc ] || continue ;;
            *) continue ;;
        esac
        if ! printf '%s\n' "$args" | awk -v dev="$match_iface" '
            prev == "-i" && $0 == dev { yes=1 }
            { prev=$0 }
            END { exit !yes }'; then
            continue
        fi
        if [ -n "$matched" ]; then
            echo 'Error: Multiple matching udhcpc processes; refusing renewal.' >&2
            return 1
        fi
        matched=${procpath##*/}
    done
    [ -n "$matched" ] || {
        echo 'Error: No existing udhcpc process for this Wi-Fi interface.' >&2
        echo 'Inspect the installed Alpine wpa_cli DHCP event hook.' >&2
        return 1
    }
    printf '%s\n' "$matched"
}

wifi_dhcp_renew() {
    [ "$#" -eq 1 ] && [ "$1" = --confirm ] || {
        echo 'Usage: wifi_dhcp_renew --confirm' >&2; return 2
    }
    renew_iface=$(wifi_interface) || return 1
    wifi_control_available "$renew_iface" || {
        echo 'Error: Cannot access wpa_supplicant.' >&2; return 1
    }
    renew_state=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$renew_iface" status 2>/dev/null |
        awk -F = '$1 == "wpa_state" { print $2; exit }')
    [ "$renew_state" = COMPLETED ] || {
        echo 'Error: Wi-Fi association not completed; no DHCP renewal.' >&2
        return 1
    }
    renew_pid=$(wifi_udhcpc_pid "$renew_iface") || return 1
    if [ "$(id -u)" -eq 0 ]; then
        kill -USR1 "$renew_pid" || return 1
    else
        command -v doas >/dev/null 2>&1 || {
            echo 'Error: doas is required to signal root-owned udhcpc.' >&2
            return 1
        }
        doas kill -USR1 "$renew_pid" || return 1
    fi
    printf 'DHCP renewal requested on %s; check wifi_ip_status.\n' "$renew_iface"
}
