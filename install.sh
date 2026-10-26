#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")" && pwd)
source_script="$root/bin/wifi"
installed_dir="$HOME/.local/share/sh/bin"
installed_script="$installed_dir/wifi"
bluetooth_source="$root/bin/bluetooth"
bluetooth_installed="$installed_dir/bluetooth"
bin_dir="$HOME/.local/bin"

[ -f "$source_script" ] && [ -f "$root/lib/wifi.sh" ] && [ -f "$root/lib/wifi-net.sh" ] &&
[ -f "$bluetooth_source" ] && [ -f "$root/lib/bluetooth.sh" ] || {
    echo 'Error: Invalid sh checkout.' >&2
    exit 1
}

# Preflight all commands before changing files.
for name in wifi wifi_status wifi_list wifi_info wifi_saved wifi_scan wifi_connect_saved wifi_enable_saved wifi_disconnect wifi_forget_saved wifi_join_new wifi_join_supported wifi_ip_status wifi_internet_status wifi_dhcp_renew; do
    target="$bin_dir/$name"
    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ "$(readlink "$target" 2>/dev/null || :)" != "$installed_script" ]; then
            echo "Error: Existing command is not managed by sh: $target" >&2
            exit 1
        fi
    fi
done
for name in bluetooth bluetooth_status bluetooth_list bluetooth_info; do
    target="$bin_dir/$name"
    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ "$(readlink "$target" 2>/dev/null || :)" != "$bluetooth_installed" ]; then
            echo "Error: Existing command is not managed by sh: $target" >&2
            exit 1
        fi
    fi
done
for managed_script in "$installed_script" "$bluetooth_installed"; do
    if [ -e "$managed_script" ] || [ -L "$managed_script" ]; then
        if [ -L "$managed_script" ] ||
           ! grep -F '# sh-managed: agusc01/sh' "$managed_script" >/dev/null 2>&1; then
            echo "Error: Existing executable is not managed by sh: $managed_script" >&2
            exit 1
        fi
    fi
done
mkdir -vp "$installed_dir"
mkdir -vp "$bin_dir"
cp -v "$source_script" "$installed_script"
chmod +x "$installed_script"
cp -v "$bluetooth_source" "$bluetooth_installed"
chmod +x "$bluetooth_installed"
for name in wifi wifi_status wifi_list wifi_info wifi_saved wifi_scan wifi_connect_saved wifi_enable_saved wifi_disconnect wifi_forget_saved wifi_join_new wifi_join_supported wifi_ip_status wifi_internet_status wifi_dhcp_renew; do
    target="$bin_dir/$name"
    if [ ! -L "$target" ]; then
        ln -sv "$installed_script" "$target"
    fi
done
for name in bluetooth bluetooth_status bluetooth_list bluetooth_info; do
    target="$bin_dir/$name"
    if [ ! -L "$target" ]; then
        ln -sv "$bluetooth_installed" "$target"
    fi
done
echo 'Wi-Fi and Bluetooth commands installed. Ensure ~/.local/bin is in PATH.'
