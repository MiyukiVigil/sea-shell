#!/bin/sh
# sea-shell — toggle a Quickshell overlay (settings/power/wallpaper) without stacking dupes.
# Usage: sea-toggle.sh <name>   →   toggles ~/.config/quickshell/sea-shell/<name>.qml
# Press once to open, again to close. Stale pidfiles (overlay closed via Esc) are handled.
name="$1"
file="$HOME/.config/quickshell/sea-shell/${name}.qml"
pidf="/tmp/sea-${name}.pid"

if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$pidf")" 2>/dev/null
    rm -f "$pidf"
else
    qs -p "$file" &
    echo $! > "$pidf"
fi
