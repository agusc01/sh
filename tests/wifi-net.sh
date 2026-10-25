#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d)
trap 'rm -R "$workspace"' 0
mkdir -p "$workspace/bin" "$workspace/proc/1001"

cat > "$workspace/bin/iw" <<'MOCK'
#!/bin/sh
printf 'phy#0\n\tInterface wlp2s0\n'
MOCK
cat > "$workspace/bin/wpa_cli" <<'MOCK'
#!/bin/sh
[ "$1" = -i ] && [ "$2" = wlp2s0 ] || exit 1
case "$3" in
    ping) echo PONG ;;
    status) printf 'wpa_state=COMPLETED\nssid=Mock Network\n' ;;
    *) exit 1 ;;
esac
MOCK
cat > "$workspace/bin/ip" <<'MOCK'
#!/bin/sh
case "$1:$2:$3" in
    'addr:show:wlp2s0')
        if [ "${MOCK_NO_IPV4:-0}" = 1 ]; then
            printf '2: wlp2s0: UP\n'
        else
            printf '2: wlp2s0: UP\n    inet 192.168.4.2/24 scope global wlp2s0\n'
        fi ;;
    'route::')
        if [ "${MOCK_NO_ROUTE:-0}" != 1 ]; then
            printf 'default via 192.168.4.1 dev wlp2s0 metric 200\n'
        fi ;;
    *) exit 1 ;;
esac
MOCK
cat > "$workspace/bin/ping" <<'MOCK'
#!/bin/sh
[ "${MOCK_IP_FAIL:-0}" != 1 ]
MOCK
cat > "$workspace/bin/nslookup" <<'MOCK'
#!/bin/sh
[ "${MOCK_DNS_FAIL:-0}" != 1 ]
MOCK
cat > "$workspace/bin/id" <<'MOCK'
#!/bin/sh
[ "$1" = -u ] && echo 9999
MOCK
cat > "$workspace/bin/doas" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_DOAS_ACTIONS"
MOCK
chmod +x "$workspace/bin/"*
printf 'udhcpc\000-i\000wlp2s0\000' > "$workspace/proc/1001/cmdline"
PATH="$workspace/bin:$PATH"; export PATH
SH_HOME=$root; export SH_HOME
WIFI_IW="$workspace/bin/iw"; export WIFI_IW
WIFI_WPA_CLI="$workspace/bin/wpa_cli"; export WIFI_WPA_CLI
WIFI_INTERFACE=wlp2s0; export WIFI_INTERFACE
WIFI_PROC_ROOT="$workspace/proc"; export WIFI_PROC_ROOT
MOCK_DOAS_ACTIONS="$workspace/actions"; export MOCK_DOAS_ACTIONS

sh "$root/bin/wifi" ip-status |
    grep -Fx 'IPv4: 192.168.4.2/24' >/dev/null
sh "$root/bin/wifi" internet-status |
    grep -Fx 'DNS probe (example.com): resolved' >/dev/null

MOCK_IP_FAIL=1; export MOCK_IP_FAIL
if sh "$root/bin/wifi" internet-status >/dev/null 2>&1; then
    echo 'Error: An unreachable ICMP target reported complete connectivity.' >&2
    exit 1
fi
unset MOCK_IP_FAIL

MOCK_DNS_FAIL=1; export MOCK_DNS_FAIL
if sh "$root/bin/wifi" internet-status >/dev/null 2>&1; then
    echo 'Error: Failed DNS reported complete connectivity.' >&2
    exit 1
fi
unset MOCK_DNS_FAIL

MOCK_NO_ROUTE=1; export MOCK_NO_ROUTE
if sh "$root/bin/wifi" ip-status >/dev/null 2>&1; then
    echo 'Error: Missing default route was accepted.' >&2
    exit 1
fi
unset MOCK_NO_ROUTE

MOCK_NO_IPV4=1; export MOCK_NO_IPV4
if sh "$root/bin/wifi" ip-status >/dev/null 2>&1; then
    echo 'Error: Missing IPv4 was accepted.' >&2
    exit 1
fi
unset MOCK_NO_IPV4

# No client renewal without an explicit confirmation flag.
if sh "$root/bin/wifi" dhcp-renew >/dev/null 2>&1; then
    echo 'Error: DHCP renew succeeded without --confirm.' >&2
    exit 1
fi
[ ! -e "$MOCK_DOAS_ACTIONS" ] || exit 1

sh "$root/bin/wifi" dhcp-renew --confirm |
    grep -F 'DHCP renewal requested' >/dev/null
grep -Fx 'kill -USR1 1001' "$MOCK_DOAS_ACTIONS" >/dev/null

mkdir "$workspace/proc/1002"
printf 'udhcpc\000-i\000wlp2s0\000' > "$workspace/proc/1002/cmdline"
: > "$MOCK_DOAS_ACTIONS"
if sh "$root/bin/wifi" dhcp-renew --confirm >/dev/null 2>&1; then
    echo 'Error: Ambiguous DHCP client PID was accepted.' >&2
    exit 1
fi
[ ! -s "$MOCK_DOAS_ACTIONS" ] || {
    echo 'Error: Ambiguous DHCP client was signaled.' >&2
    exit 1
}

sh -n "$root/lib/wifi-net.sh"
sh -n "$root/scripts/enable-wpa-saving.sh"
sh -n "$root/bin/wifi"
sh -n "$root/install.sh"
echo 'Wi-Fi IP, connectivity and DHCP tests passed.'
