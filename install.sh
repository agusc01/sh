#!/bin/sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")" && pwd)
source_script="$root/bin/wifi"
installed_dir="$HOME/.local/share/sh/bin"
installed_script="$installed_dir/wifi"
bin_dir="$HOME/.local/bin"

[ -f "$source_script" ] && [ -f "$root/lib/wifi.sh" ] || {
    echo 'Error: Invalid sh checkout.' >&2
    exit 1
}

# Preflight all commands before changing files.
for name in wifi wifi_status wifi_list wifi_info wifi_saved wifi_scan wifi_connect_saved wifi_disconnect wifi_forget_saved wifi_join_new; do
    target="$bin_dir/$name"
    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ "$(readlink "$target" 2>/dev/null || :)" != "$installed_script" ]; then
            echo "Error: Existing command is not managed by sh: $target" >&2
            exit 1
        fi
    fi
done
if [ -e "$installed_script" ] || [ -L "$installed_script" ]; then
    if [ -L "$installed_script" ] ||
       ! grep -F '# sh-managed: agusc01/sh' "$installed_script" >/dev/null 2>&1; then
        echo "Error: Existing executable is not managed by sh: $installed_script" >&2
        exit 1
    fi
fi
mkdir -vp "$installed_dir"
mkdir -vp "$bin_dir"
cp -v "$source_script" "$installed_script"
chmod +x "$installed_script"
for name in wifi wifi_status wifi_list wifi_info wifi_saved wifi_scan wifi_connect_saved wifi_disconnect wifi_forget_saved wifi_join_new; do
    target="$bin_dir/$name"
    if [ ! -L "$target" ]; then
        ln -sv "$installed_script" "$target"
    fi
done
echo 'Wi-Fi commands installed. Ensure ~/.local/bin is in PATH.'
