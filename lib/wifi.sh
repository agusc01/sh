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

# Older wpa_supplicant versions can create a world-readable .tmp file and
# rename it over the original config on save. Checking chmod only AFTER
# save_config is unsafe because credentials may already have been exposed.
wifi_wpa_save_preflight() {
    [ "$#" -eq 1 ] || return 2
    save_iface=$1
    save_conf=${WIFI_WPA_CONFIG:-/etc/wpa_supplicant/wpa_supplicant.conf}
    save_proc_root=${WIFI_WPA_PROC_ROOT:-/proc}

    if [ ! -f "$save_conf" ] || [ -L "$save_conf" ]; then
        echo 'Error: Wi-Fi configuration must be a regular file, not a symlink.' >&2
        return 1
    fi
    save_mode=$(stat -c '%a' "$save_conf" 2>/dev/null) || return 1
    if [ "$save_mode" != 600 ]; then
        echo 'Error: Refusing save_config: Wi-Fi configuration is not mode 600.' >&2
        echo 'Restore root-only permissions before saving credentials.' >&2
        return 1
    fi

    save_count=0
    save_mask=''
    for save_proc in "$save_proc_root"/[0-9]*; do
        [ -r "$save_proc/cmdline" ] && [ -r "$save_proc/status" ] || continue
        save_args=$(tr '\000' '\n' < "$save_proc/cmdline") || continue
        save_command=$(printf '%s\n' "$save_args" | sed -n '1p')
        [ "${save_command##*/}" = wpa_supplicant ] || continue
        if ! printf '%s\n' "$save_args" |
            awk -v dev="$save_iface" -v conf="$save_conf" '
                $0 == "-i" { want_dev=1; next }
                $0 == "-c" { want_conf=1; next }
                want_dev { if ($0 == dev) has_dev=1; want_dev=0; next }
                want_conf { if ($0 == conf) has_conf=1; want_conf=0; next }
                index($0, "-i") == 1 && substr($0, 3) == dev { has_dev=1 }
                index($0, "-c") == 1 && substr($0, 3) == conf { has_conf=1 }
                END { exit !(has_dev && has_conf) }'; then
            continue
        fi
        save_count=$((save_count + 1))
        save_mask=$(awk '$1 == "Umask:" { print $2; exit }' "$save_proc/status")
    done

    if [ "$save_count" -ne 1 ]; then
        echo 'Error: Could not uniquely identify the running wpa_supplicant daemon.' >&2
        echo 'Refusing save_config until the active interface/configuration is verified.' >&2
        return 1
    fi
    case "$save_mask" in
        [0-7][0-7]77) return 0 ;;
    esac
    printf 'Error: Refusing save_config: daemon umask is %s, not root-only.\n' "${save_mask:-unknown}" >&2
    echo 'Set umask="077" in /etc/conf.d/wpa_supplicant, then restart its service when safe.' >&2
    return 1
}

wifi_wpa_expect_ok() {
    expect_iface=$1
    shift
    expect_command=$1
    shift
    if [ "$expect_command" = save_config ]; then
        wifi_wpa_save_preflight "$expect_iface" || return 1
    fi
    expect_result=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$expect_iface" "$expect_command" "$@" 2>/dev/null) || {
        printf 'Error: wpa_supplicant command %s failed.\n' "$expect_command" >&2
        return 1
    }
    [ "$expect_result" = OK ] || {
        printf 'Error: wpa_supplicant rejected %s (%s).\n' "$expect_command" "$expect_result" >&2
        return 1
    }
}

# Return IDs of profiles that are currently enabled (including CURRENT).
# Snapshot this before select_network disables all other network profiles.
wifi_wpa_enabled_ids() {
    [ "$#" -eq 1 ] || return 2
    enabled_rows=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$1" list_networks 2>/dev/null) || {
        echo 'Error: Could not inspect enabled Wi-Fi profiles.' >&2
        return 1
    }
    printf '%s\n' "$enabled_rows" | awk -F '\t' '
        NR > 1 && $1 ~ /^[0-9]+$/ &&
        $4 !~ /\[(DISABLED|TEMP-DISABLED)\]/ { print $1 }'
}

# Restore only profiles enabled before selecting a new network, without
# triggering an immediate second connection or changing intentionally
# disabled profiles. Never fall back to plain enable_network.
wifi_wpa_restore_enabled() {
    [ "$#" -eq 3 ] || return 2
    restore_iface=$1
    restore_selected=$2
    restore_ids=$3
    for restore_id in $restore_ids; do
        [ "$restore_id" = "$restore_selected" ] && continue
        if ! wifi_wpa_expect_ok "$restore_iface" enable_network "$restore_id" no-connect; then
            echo 'WARNING: Could not restore previously enabled profiles.' >&2
            echo 'Current selection may work, but automatic reconnection is limited.' >&2
            return 1
        fi
    done
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
    connect_enabled=$(wifi_wpa_enabled_ids "$connect_iface") || return 1
    # Select the requested SSID, then restore the previously enabled
    # profiles without triggering a second roaming decision.
    wifi_wpa_expect_ok "$connect_iface" select_network "$connect_id" || return 1
    wifi_wpa_restore_enabled "$connect_iface" "$connect_id" "$connect_enabled" || return 1
    if ! wifi_wpa_expect_ok "$connect_iface" save_config; then
        echo 'WARNING: Connection requested, but enabled profiles were not saved.' >&2
        return 1
    fi
    printf 'Connection requested for %s; previously enabled profiles preserved.\n' "$1"
    echo 'Check wifi_status; DHCP/IP is managed separately.'
}

# Enable a previously disabled saved profile for automatic reconnection,
# without interrupting the currently associated Wi-Fi.
wifi_enable_saved() {
    [ "$#" -eq 2 ] && [ -n "$1" ] && [ "$2" = --confirm ] || {
        echo 'Usage: wifi_enable_saved SSID --confirm' >&2
        return 2
    }
    enable_id=$(wifi_saved_id "$1") || return 1
    enable_iface=$(wifi_wpa_interface) || return 1
    wifi_wpa_expect_ok "$enable_iface" enable_network "$enable_id" no-connect || return 1
    if ! wifi_wpa_expect_ok "$enable_iface" save_config; then
        echo 'WARNING: Profile enabled in memory but not saved to disk.' >&2
        return 1
    fi
    printf 'Auto-reconnect enabled for %s without switching the current Wi-Fi.\n' "$1"
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


# Check whether a visible SSID can safely use the WPA2-Personal enrollment
# path. Conservative for duplicate BSS entries: reject mixed security.
wifi_join_supported() {
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        echo 'Usage: wifi_join_supported SSID' >&2
        return 2
    }
    WIFI_LOOKUP_SSID=$1
    export WIFI_LOOKUP_SSID
    support_scans=$(wifi_scan_data) || return 1
    printf '%s\n' "$support_scans" | awk -F '\t' '
        NF >= 4 && $1 == ENVIRON["WIFI_LOOKUP_SSID"] {
            found=1
            # WPA2/WPA3 transition mode reports WPA2-PSK+SAE-CCMP.
            # SAE does not make the WPA2-PSK path unavailable. Still reject
            # WPA3-only, EAP, WEP, open, or inconsistent BSS configurations.
            if (index($3, "WPA2-PSK") == 0 ||
                $3 ~ /(EAP|WEP|OWE)/)
                unsupported=1
        }
        END { exit !found || unsupported }' || {
        printf 'Error: No compatible WPA2-PSK access point confirmed for SSID %s.\n' "$1" >&2
        echo 'Check cached security flags with wifi_info; run wifi_scan and retry if stale.' >&2
        return 1
    }
}

# Create a new WPA2-Personal profile using a passphrase from standard input.
# Never place the password or its derived PSK in argv or a temporary file.
wifi_join_new() {
    join_temporary=0
    if [ "$#" -eq 2 ] && [ "$1" = --temporary ]; then
        join_temporary=1
        shift
    fi
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        echo 'Usage: wifi_join_new [--temporary] SSID < secure-password-input' >&2
        return 2
    }
    join_ssid=$1
    [ ! -t 0 ] || {
        echo 'Error: Use a masked password prompt, not an echoed terminal.' >&2
        return 1
    }
    join_bytes=$(LC_ALL=C printf '%s' "$join_ssid" | wc -c | tr -d ' ')
    [ "$join_bytes" -ge 1 ] && [ "$join_bytes" -le 32 ] || {
        echo 'Error: SSID must be 1-32 bytes.' >&2
        return 1
    }
    case "$join_ssid" in
        *'
'*|*'	'*) echo 'Error: Control characters in SSID are unsupported.' >&2; return 1 ;;
    esac

    join_iface=$(wifi_wpa_interface) || return 1

    # Use the same security policy as the graphical/terminal menus.
    wifi_join_supported "$join_ssid" || return 1
    WIFI_LOOKUP_SSID=$join_ssid; export WIFI_LOOKUP_SSID

    join_saved=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" list_networks 2>/dev/null) || {
        echo 'Error: Could not verify saved network names.' >&2; return 1
    }
    if printf '%s\n' "$join_saved" | awk -F '\t' '
        NR > 1 && $2 == ENVIRON["WIFI_LOOKUP_SSID"] { found=1 }
        END { exit !found }'; then
        echo 'Error: This SSID is already saved. Use wifi_connect_saved.' >&2
        return 1
    fi

    # Read one password line from stdin. Never expose it via argv or echo it.
    join_password=''
    if ! IFS= read -r join_password; then
        echo 'Error: No WPA2 password received on stdin.' >&2
        return 1
    fi
    join_password_len=$(LC_ALL=C printf '%s' "$join_password" | wc -c | tr -d ' ')
    if [ "$join_password_len" -lt 8 ] || [ "$join_password_len" -gt 63 ]; then
        join_password=''
        echo 'Error: WPA2 password must contain 8-63 bytes.' >&2
        return 1
    fi
    # Quote/backslash need a separate escaping implementation in interactive
    # wpa_cli. Reject rather than altering user-entered credentials.
    case "$join_password" in
        *'"'*|*'\'*)
            join_password=''
            echo 'Error: Quotation marks and backslashes in passwords are not yet supported.' >&2
            return 1
            ;;
    esac
    if LC_ALL=C printf '%s' "$join_password" | LC_ALL=C grep '[^ -~]' >/dev/null; then
        join_password=''
        echo 'Error: This initial WPA2 flow supports only printable ASCII passwords.' >&2
        return 1
    fi

    join_hex=$(LC_ALL=C printf '%s' "$join_ssid" | od -An -tx1 | tr -d ' \n')
    [ "${#join_hex}" -eq "$((join_bytes * 2))" ] || {
        echo 'Error: Could not encode SSID.' >&2; return 1
    }
    join_enabled=$(wifi_wpa_enabled_ids "$join_iface") || return 1
    join_id=$("${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" add_network 2>/dev/null) || {
        echo 'Error: Could not add a network profile.' >&2; return 1
    }
    case "$join_id" in
        ''|*[!0-9]*)
            echo 'Error: Unexpected new network ID.' >&2; return 1 ;;
    esac
    if ! wifi_wpa_expect_ok "$join_iface" set_network "$join_id" ssid "$join_hex"; then
        "${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" remove_network "$join_id" >/dev/null 2>&1 || :
        return 1
    fi
    # Prefer WPA2-Personal explicitly when joining a WPA2/WPA3 transition AP.
    # Do not silently select SAE without negotiating its separate requirements.
    if ! wifi_wpa_expect_ok "$join_iface" set_network "$join_id" key_mgmt WPA-PSK; then
        "${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" remove_network "$join_id" >/dev/null 2>&1 || :
        return 1
    fi

    # wpa_cli accepts a quoted ASCII passphrase through its interactive
    # standard input. Do not put this secret in argv, log output, or files.
    # wpa_supplicant derives the PSK internally and save_config persists
    # the credential, so its config file MUST remain access-restricted.
    join_result=$(printf 'set_network %s psk "%s"\nquit\n' "$join_id" "$join_password" |
        "${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" 2>/dev/null) || join_result=''
    join_password=''
    if ! printf '%s\n' "$join_result" |
        awk '/(^|[[:space:]>])OK[[:space:]]*$/ { found=1 }
             /(^|[[:space:]>])FAIL[[:space:]]*$/ { failed=1 }
             END { exit !found || failed }'; then
        join_result=''
        "${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" remove_network "$join_id" >/dev/null 2>&1 || :
        echo 'Error: wpa_supplicant did not accept the new WPA2 passphrase.' >&2
        return 1
    fi
    join_result=''

    if [ "$join_temporary" -eq 0 ]; then
        # For explicitly persistent joins, save before switching. A failure
        # MUST NOT alter the current association or become a temporary join.
        if ! wifi_wpa_expect_ok "$join_iface" save_config; then
            "${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" remove_network "$join_id" >/dev/null 2>&1 || :
            echo 'Error: Profile not activated because it could not be saved.' >&2
            echo 'Try --temporary for an explicitly unsaved Wi-Fi connection.' >&2
            return 1
        fi
    fi
    if ! wifi_wpa_expect_ok "$join_iface" select_network "$join_id"; then
        if [ "$join_temporary" -eq 1 ]; then
            "${WIFI_WPA_CLI:-wpa_cli}" -i "$join_iface" remove_network "$join_id" >/dev/null 2>&1 || :
            echo 'Error: Temporary Wi-Fi association was not requested.' >&2
        else
            echo 'WARNING: Profile saved, but association could not be requested.' >&2
        fi
        return 1
    fi
    # Restore profiles which were enabled before the manual connection.
    # Intentionally disabled profiles require a separate explicit action.
    wifi_wpa_restore_enabled "$join_iface" "$join_id" "$join_enabled" || return 1
    if [ "$join_temporary" -eq 1 ]; then
        printf 'Temporary WPA2 connection requested for %s (NOT saved to disk).\n' "$join_ssid"
        echo 'This session-only profile is held in wpa_supplicant memory; it may disappear when it restarts.'
        echo 'Verify authentication, IP and DHCP separately using wifi_status and ip addr show.'
        return 0
    fi
    # Persist the enabled selection, since add_network creates a disabled
    # profile and select_network changes its enabled state.
    if ! wifi_wpa_expect_ok "$join_iface" save_config; then
        echo 'WARNING: Association requested, but the enabled profile may not persist across reboot.' >&2
        return 1
    fi
    printf 'WPA2 connection requested for %s. Verify status and DHCP/IP separately.\n' "$join_ssid"
}
