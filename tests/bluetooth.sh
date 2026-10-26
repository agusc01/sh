#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d)
trap 'rm -R "$workspace"' 0
mkdir -p "$workspace/bin"

cat > "$workspace/bin/bluetoothctl" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_BT_CALLS"
[ "${MOCK_BT_DOWN:-0}" = 1 ] && exit 1
case "$1" in
    show)
        if [ "${MOCK_BT_NO_CONTROLLER:-0}" = 1 ]; then
            echo 'No default controller available'
        else
            printf 'Controller AA:BB:CC:DD:EE:FF laptop [default]\n'
            printf '\tName: Alpine Notebook\n'
            printf '\tPowered: yes\n\tDiscoverable: no\n\tPairable: yes\n\tDiscovering: no\n'
        fi
        ;;
    devices)
        if [ "${MOCK_BT_NO_DEVICES:-0}" != 1 ]; then
            printf 'Device 11:22:33:44:55:66 Headphones Plus\n'
            printf 'Device AA:00:BB:11:CC:22 Travel Mouse\n'
            printf 'Device 11:22:33:44:55:66 Headphones Plus\n'
            printf 'Device invalid should be ignored\n'
        fi
        ;;
    info)
        case "$2" in
            11:22:33:44:55:66)
                printf 'Device 11:22:33:44:55:66 (public)\n'
                printf '\tName: Headphones\n\tAlias: Headphones Plus\n'
                printf '\tPaired: yes\n\tTrusted: yes\n\tConnected: no\n\tRSSI: -48\n'
                ;;
            AA:00:BB:11:CC:22)
                printf 'Device AA:00:BB:11:CC:22 (public)\n'
                printf '\tName: Travel Mouse\n\tPaired: no\n\tTrusted: no\n\tConnected: yes\n'
                ;;
            *) echo 'Device not available' ;;
        esac
        ;;
    *) echo "Unexpected state-changing command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$workspace/bin/bluetoothctl"

SH_HOME=$root; export SH_HOME
BLUETOOTH_CTL="$workspace/bin/bluetoothctl"; export BLUETOOTH_CTL
MOCK_BT_CALLS="$workspace/calls"; export MOCK_BT_CALLS

sh "$root/bin/bluetooth" status | grep -Fx 'Controller: AA:BB:CC:DD:EE:FF' >/dev/null
sh "$root/bin/bluetooth" status | grep -Fx 'Powered: yes' >/dev/null
sh "$root/bin/bluetooth" status | grep -Fx 'Backend: bluetoothctl (read-only)' >/dev/null
[ "$(sh "$root/bin/bluetooth" list)" = "$(printf '11:22:33:44:55:66\tHeadphones Plus\nAA:00:BB:11:CC:22\tTravel Mouse')" ]
sh "$root/bin/bluetooth" info 11:22:33:44:55:66 | grep -Fx 'Paired: yes' >/dev/null
sh "$root/bin/bluetooth" info 11:22:33:44:55:66 | grep -Fx 'Name: Headphones Plus' >/dev/null
sh "$root/bin/bluetooth" info aa:00:bb:11:cc:22 | grep -Fx 'Connected: yes' >/dev/null

# Invalid and unknown addresses must not be mistaken for known devices.
: > "$MOCK_BT_CALLS"
if sh "$root/bin/bluetooth" info '11:22:33:44:55:66;power off' >/dev/null 2>&1; then
    echo 'Error: Invalid address was accepted.' >&2; exit 1
fi
[ ! -s "$MOCK_BT_CALLS" ] || { echo 'Error: Invalid address invoked BlueZ.' >&2; exit 1; }
if sh "$root/bin/bluetooth" info 00:00:00:00:00:00 >/dev/null 2>&1; then
    echo 'Error: Unknown device was accepted.' >&2; exit 1
fi
if sh "$root/bin/bluetooth" nonsense >/dev/null 2>&1; then
    echo 'Error: Unknown command was accepted.' >&2; exit 1
fi

MOCK_BT_NO_DEVICES=1; export MOCK_BT_NO_DEVICES
[ -z "$(sh "$root/bin/bluetooth" list)" ]
unset MOCK_BT_NO_DEVICES
MOCK_BT_NO_CONTROLLER=1; export MOCK_BT_NO_CONTROLLER
if sh "$root/bin/bluetooth" status >/dev/null 2>&1; then
    echo 'Error: No controller was reported as available.' >&2; exit 1
fi
if sh "$root/bin/bluetooth" list >/dev/null 2>&1; then
    echo 'Error: List succeeded without a controller.' >&2; exit 1
fi
unset MOCK_BT_NO_CONTROLLER
MOCK_BT_DOWN=1; export MOCK_BT_DOWN
if sh "$root/bin/bluetooth" status >/dev/null 2>&1; then
    echo 'Error: Unavailable daemon was reported as available.' >&2; exit 1
fi
unset MOCK_BT_DOWN

# The read-only milestone must invoke only show, devices and info.
if awk '$1 != "show" && $1 != "devices" && $1 != "info" { exit 1 }' "$MOCK_BT_CALLS"; then :; else
    echo 'Error: A state-changing BlueZ command was invoked.' >&2; exit 1
fi

# Installer keeps Wi-Fi intact and creates all Bluetooth command aliases.
mkdir -p "$workspace/home"
HOME="$workspace/home" sh "$root/install.sh" >/dev/null
HOME="$workspace/home" sh "$root/install.sh" >/dev/null
for name in bluetooth bluetooth_status bluetooth_list bluetooth_info; do
    [ "$(readlink "$workspace/home/.local/bin/$name")" = "$workspace/home/.local/share/sh/bin/bluetooth" ]
done
[ -L "$workspace/home/.local/bin/wifi_status" ]

# A conflicting existing command aborts before writing anything.
mkdir -p "$workspace/conflict/.local/bin"
: > "$workspace/conflict/.local/bin/bluetooth_info"
if HOME="$workspace/conflict" sh "$root/install.sh" >/dev/null 2>&1; then
    echo 'Error: Installer overwrote a conflicting command.' >&2; exit 1
fi
[ ! -e "$workspace/conflict/.local/share/sh/bin/wifi" ]

echo 'Bluetooth inspection tests passed.'
