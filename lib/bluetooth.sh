#!/bin/sh
# Read-only BlueZ inspection on Alpine Linux, compatible with POSIX sh.
# No adapter configuration, discovery, pairing, or connection changes.

bluetooth_query() {
    ctl=${BLUETOOTH_CTL:-bluetoothctl}
    command -v "$ctl" >/dev/null 2>&1 || {
        echo 'Error: bluetoothctl is missing; install BlueZ through Alpine.' >&2
        return 1
    }
    "$ctl" "$@" 2>/dev/null || {
        echo 'Error: Could not query BlueZ; check the bluetooth service.' >&2
        return 1
    }
}

bluetooth_controller_output() {
    controller_output=$(bluetooth_query show) || return 1
    printf '%s\n' "$controller_output" |
        awk '$1 == "Controller" && $2 ~ /^[[:xdigit:]:]+$/ && length($2) == 17 { found=1 }
             END { exit !found }' || {
        echo 'Error: No default Bluetooth controller is available.' >&2
        return 1
    }
    printf '%s\n' "$controller_output"
}

bluetooth_address_valid() {
    case "$1" in
        [[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]) return 0 ;;
        *) return 1 ;;
    esac
}

bluetooth_status() {
    [ "$#" -eq 0 ] || { echo 'Usage: bluetooth_status' >&2; return 2; }
    details=$(bluetooth_controller_output) || return 1
    printf '%s\n' "$details" | awk '
        $1 == "Controller" { address=$2 }
        /^[[:space:]]*Name: / { sub(/^[[:space:]]*Name: /, ""); name=$0 }
        /^[[:space:]]*Powered: / { powered=$2 }
        /^[[:space:]]*Pairable: / { pairable=$2 }
        /^[[:space:]]*Discoverable: / { discoverable=$2 }
        /^[[:space:]]*Discovering: / { discovering=$2 }
        END {
            print "Controller: " address
            print "Name: " (name != "" ? name : "unknown")
            print "Powered: " (powered != "" ? powered : "unknown")
            print "Pairable: " (pairable != "" ? pairable : "unknown")
            print "Discoverable: " (discoverable != "" ? discoverable : "unknown")
            print "Discovering: " (discovering != "" ? discovering : "unknown")
            print "Backend: bluetoothctl (read-only)"
        }'
}

# Print cached/known devices as TSV: ADDRESS<TAB>NAME.
# This does not start discovery; new devices may not be listed yet.
bluetooth_list() {
    [ "$#" -eq 0 ] || { echo 'Usage: bluetooth_list' >&2; return 2; }
    bluetooth_controller_output >/dev/null || return 1
    rows=$(bluetooth_query devices) || return 1
    printf '%s\n' "$rows" | awk '
        $1 == "Device" && $2 ~ /^[[:xdigit:]:]+$/ && length($2) == 17 && !seen[toupper($2)]++ {
            address=$2
            name=$0
            sub(/^[[:space:]]*Device[[:space:]]+[^[:space:]]+[[:space:]]*/, "", name)
            if (name == "") name="(unnamed)"
            print address "\t" name
        }'
}

bluetooth_info() {
    [ "$#" -eq 1 ] && bluetooth_address_valid "$1" || {
        echo 'Usage: bluetooth_info AA:BB:CC:DD:EE:FF' >&2
        return 2
    }
    address=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    details=$(bluetooth_query info "$address") || return 1
    printf '%s\n' "$details" | awk -v wanted="$address" '
        $1 == "Device" && toupper($2) == wanted { found=1 }
        /^[[:space:]]*Name: / { sub(/^[[:space:]]*Name: /, ""); name=$0 }
        /^[[:space:]]*Alias: / { sub(/^[[:space:]]*Alias: /, ""); alias=$0 }
        /^[[:space:]]*Paired: / { paired=$2 }
        /^[[:space:]]*Trusted: / { trusted=$2 }
        /^[[:space:]]*Connected: / { connected=$2 }
        /^[[:space:]]*RSSI: / { rssi=$2 }
        END {
            if (!found) exit 1
            print "Address: " wanted
            print "Name: " (alias != "" ? alias : (name != "" ? name : "unknown"))
            print "Paired: " (paired != "" ? paired : "unknown")
            print "Trusted: " (trusted != "" ? trusted : "unknown")
            print "Connected: " (connected != "" ? connected : "unknown")
            if (rssi != "") print "RSSI: " rssi " dBm"
        }' || {
        echo 'Error: Device is not available in the BlueZ cache.' >&2
        return 1
    }
}
