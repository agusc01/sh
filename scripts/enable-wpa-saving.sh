#!/bin/sh
# Explicit one-time admin setup for saving wpa_supplicant profiles on Alpine.
# NEVER print Wi-Fi configuration contents: they can contain passwords.
set -eu

conf=/etc/wpa_supplicant/wpa_supplicant.conf
usage() {
    echo 'Usage: doas sh scripts/enable-wpa-saving.sh --check|--enable --confirm' >&2
    exit 2
}
[ "$#" -ge 1 ] || usage
action=$1
shift
case "$action:$*" in
    --check:|'--enable:--confirm') ;;
    *) usage ;;
esac
[ -f "$conf" ] && [ ! -L "$conf" ] && [ -r "$conf" ] || {
    echo 'Error: Cannot safely read the expected regular wpa_supplicant configuration.' >&2
    echo 'Check which -c file the running wpa_supplicant uses before modifying anything.' >&2
    exit 1
}
mode=$(awk '
    /^[[:space:]]*update_config[[:space:]]*=/ {
        n++
        v=$0
        sub(/^[^=]*=/, "", v)
        sub(/^[[:space:]]*/, "", v)
        sub(/[[:space:]#].*$/, "", v)
        if (v == "1") state="enabled"
        else state="disabled"
    }
    END {
        if (n > 1) print "ambiguous"
        else if (n == 0) print "missing"
        else print state
    }' "$conf")
printf 'wpa_supplicant configuration: %s\n' "$conf"
printf 'Persistent saving: %s\n' "$mode"
[ "$mode" != ambiguous ] || {
    echo 'Error: Multiple update_config settings; fix them manually.' >&2
    exit 1
}
if [ "$action" = --check ]; then
    echo 'Note: the running daemon may still have an older configuration loaded.'
    exit 0
fi
[ "$(id -u)" -eq 0 ] || {
    echo 'Error: Re-run with doas; editing persistent Wi-Fi is an admin action.' >&2
    exit 1
}
[ "$(stat -c '%u' "$conf")" = 0 ] || {
    echo 'Error: Expected root-owned configuration; refusing to change ownership.' >&2
    exit 1
}
if [ "$mode" = enabled ]; then
    echo 'No changes: update_config=1 is already present.'
    exit 0
fi

# A private backup and private replacement file are created in the same dir.
umask 077
backup=$(mktemp "$conf.backup.XXXXXXXX") || exit 1
staged=''
trap '[ -z "$staged" ] || rm -f "$staged"' 0
if ! cp "$conf" "$backup"; then
    rm -f "$backup"
    echo 'Error: Could not back up the configuration. Nothing changed.' >&2
    exit 1
fi
chmod 600 "$backup"
staged=$(mktemp "$conf.new.XXXXXXXX") || exit 1
if ! awk '
    BEGIN { print "update_config=1" }
    !/^[[:space:]]*update_config[[:space:]]*=/ { print }
' "$conf" > "$staged"; then
    echo 'Error: Could not prepare configuration. Nothing changed.' >&2
    exit 1
fi
chown 0:0 "$staged"
chmod 600 "$staged"
if ! mv "$staged" "$conf"; then
    echo 'Error: Could not replace configuration. Backup retained.' >&2
    exit 1
fi
staged=''
printf 'Saved update_config=1. Private backup: %s\n' "$backup"
echo 'The RUNNING wpa_supplicant is unchanged until it reloads this file.'
echo 'Reloading can drop a temporary Wi-Fi connection; do it only when ready.'
echo 'After reloading, verify with wpa_cli -i wlan0 save_config.'
