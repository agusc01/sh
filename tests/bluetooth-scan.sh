#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' 0
mkdir -p "$workspace/bin"

cat > "$workspace/bin/bluetoothctl" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_BT_CALLS"
case "$*" in
    show)
        if [ "${MOCK_BT_NO_CONTROLLER:-0}" = 1 ]; then
            echo 'No default controller available'
            exit 0
        fi
        echo 'Controller AA:BB:CC:DD:EE:FF laptop [default]'
        printf '\tPowered: %s\n' "${MOCK_BT_POWERED:-yes}"
        discovering=${MOCK_BT_DISCOVERING:-no}
        if [ "${MOCK_BT_STUCK:-0}" = 1 ] && [ -e "$MOCK_BT_SCANNED" ]; then discovering=yes; fi
        # BlueZ may return a stale 'Discovering: yes' after timed scanning.
        if [ -e "$MOCK_BT_SCANNED" ] && [ "$MOCK_BT_SETTLE_POLLS" -gt 0 ]; then
            count=$(cat "$MOCK_BT_SETTLE_COUNT" 2>/dev/null || printf '0')
            if [ "$count" -lt "$MOCK_BT_SETTLE_POLLS" ]; then
                discovering=yes
                printf '%s\n' "$((count + 1))" > "$MOCK_BT_SETTLE_COUNT"
            fi
        fi
        printf '\tDiscovering: %s\n' "$discovering"
        ;;
    '--timeout 10 scan on')
        [ "${MOCK_BT_SCAN_FAIL:-0}" = 1 ] && exit 1
        if [ "${MOCK_BT_NO_START:-0}" = 1 ]; then echo 'Failed to start discovery'; exit 0; fi
        touch "$MOCK_BT_SCANNED"
        echo 'Discovery started'
        echo '[NEW] Device 11:22:33:44:55:66 Headphones'
        ;;
    devices)
        if [ "${MOCK_BT_NO_DEVICES:-0}" != 1 ]; then
            echo 'Device 11:22:33:44:55:66 Headphones'
        fi
        ;;
    *) echo "Unexpected BlueZ command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$workspace/bin/bluetoothctl"
# Stub only the wait: tests must finish immediately even for stuck discovery.
cat > "$workspace/bin/sleep" <<'MOCK_SLEEP'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" -eq 1 ] || exit 1
printf '1\n' >> "$MOCK_BT_SLEEPS"
MOCK_SLEEP
chmod +x "$workspace/bin/sleep"
PATH="$workspace/bin:$PATH"; export PATH
SH_HOME=$root; export SH_HOME
BLUETOOTH_CTL="$workspace/bin/bluetoothctl"; export BLUETOOTH_CTL
MOCK_BT_CALLS="$workspace/calls"; export MOCK_BT_CALLS
MOCK_BT_SCANNED="$workspace/scanned"; export MOCK_BT_SCANNED
MOCK_BT_SETTLE_COUNT="$workspace/settle-count"; export MOCK_BT_SETTLE_COUNT
MOCK_BT_SETTLE_POLLS=0; export MOCK_BT_SETTLE_POLLS
MOCK_BT_SLEEPS="$workspace/sleeps"; export MOCK_BT_SLEEPS

sh "$root/bin/bluetooth" scan > "$workspace/output"
grep -F 'Scanning Bluetooth for 10 seconds' "$workspace/output" >/dev/null
grep -F '11:22:33:44:55:66' "$workspace/output" >/dev/null
grep -Fx -- '--timeout 10 scan on' "$MOCK_BT_CALLS" >/dev/null

# Real hardware initially returned Discovering: yes and then settled to no.
rm -f "$MOCK_BT_SCANNED" "$MOCK_BT_SETTLE_COUNT" "$MOCK_BT_SLEEPS"
MOCK_BT_SETTLE_POLLS=2; export MOCK_BT_SETTLE_POLLS
sh "$root/bin/bluetooth" scan > "$workspace/output"
grep -F 'Known devices (BlueZ cache):' "$workspace/output" >/dev/null
[ "$(wc -l < "$MOCK_BT_SLEEPS" | tr -d ' ')" -eq 2 ]
MOCK_BT_SETTLE_POLLS=0; export MOCK_BT_SETTLE_POLLS

for failure in powered busy missing failed no-start stuck; do
    rm -f "$MOCK_BT_SCANNED" "$MOCK_BT_SETTLE_COUNT" "$MOCK_BT_SLEEPS"
    : > "$MOCK_BT_CALLS"
    unset MOCK_BT_POWERED MOCK_BT_DISCOVERING MOCK_BT_NO_CONTROLLER MOCK_BT_SCAN_FAIL MOCK_BT_NO_START MOCK_BT_STUCK
    case "$failure" in
        powered) MOCK_BT_POWERED=no; export MOCK_BT_POWERED ;;
        busy) MOCK_BT_DISCOVERING=yes; export MOCK_BT_DISCOVERING ;;
        missing) MOCK_BT_NO_CONTROLLER=1; export MOCK_BT_NO_CONTROLLER ;;
        failed) MOCK_BT_SCAN_FAIL=1; export MOCK_BT_SCAN_FAIL ;;
        no-start) MOCK_BT_NO_START=1; export MOCK_BT_NO_START ;;
        stuck) MOCK_BT_STUCK=1; export MOCK_BT_STUCK ;;
    esac
    if sh "$root/bin/bluetooth" scan >/dev/null 2>&1; then
        echo "Error: Scan unexpectedly passed scenario $failure" >&2; exit 1
    fi
    if [ "$failure" = powered ] || [ "$failure" = busy ] || [ "$failure" = missing ]; then
        if grep -Fx -- '--timeout 10 scan on' "$MOCK_BT_CALLS" >/dev/null; then
            echo "Error: Scan started in scenario $failure" >&2; exit 1
        fi
    fi
    if [ "$failure" = stuck ]; then
        [ "$(wc -l < "$MOCK_BT_SLEEPS" | tr -d ' ')" -eq 5 ] || {
            echo 'Error: Stuck discovery exceeded bounded polling.' >&2; exit 1
        }
    fi
done
unset MOCK_BT_POWERED MOCK_BT_DISCOVERING MOCK_BT_NO_CONTROLLER MOCK_BT_SCAN_FAIL MOCK_BT_NO_START MOCK_BT_STUCK
: > "$MOCK_BT_CALLS"
if sh "$root/bin/bluetooth" scan unexpected >/dev/null 2>&1; then
    echo 'Error: Unexpected scan argument accepted.' >&2; exit 1
fi
[ ! -s "$MOCK_BT_CALLS" ]
MOCK_BT_NO_DEVICES=1; export MOCK_BT_NO_DEVICES
sh "$root/bin/bluetooth" scan > "$workspace/output"
grep -F 'Known devices (BlueZ cache):' "$workspace/output" >/dev/null
unset MOCK_BT_NO_DEVICES

# The installer must expose the no-argument command without replacing Wi-Fi.
mkdir -p "$workspace/home"
HOME="$workspace/home" sh "$root/install.sh" >/dev/null
[ "$(readlink "$workspace/home/.local/bin/bluetooth_scan")" = "$workspace/home/.local/share/sh/bin/bluetooth" ]
[ -L "$workspace/home/.local/bin/wifi_status" ]

echo 'Bluetooth scan tests passed.'
