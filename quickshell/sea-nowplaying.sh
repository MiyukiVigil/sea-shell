#!/bin/sh
# sea-shell — get current song info for hyprlock

status=$(playerctl status 2>/dev/null || true)
if [ "$status" = "Playing" ]; then
    title=$(playerctl metadata title 2>/dev/null | cut -c 1-45)
    artist=$(playerctl metadata artist 2>/dev/null | cut -c 1-35)
    echo "♬  $title  ·  $artist"
elif [ "$status" = "Paused" ]; then
    title=$(playerctl metadata title 2>/dev/null | cut -c 1-45)
    artist=$(playerctl metadata artist 2>/dev/null | cut -c 1-35)
    echo "⏸  $title  ·  $artist"
else
    echo ""
fi
