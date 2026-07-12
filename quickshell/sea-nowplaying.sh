#!/bin/sh
# sea-shell — get current song info with pango markup for hyprlock

status=$(playerctl status 2>/dev/null || true)
if [ "$status" = "Playing" ] || [ "$status" = "Paused" ]; then
    title=$(playerctl metadata title 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | cut -c 1-45)
    artist=$(playerctl metadata artist 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | cut -c 1-35)
    accent=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('accent','#63c7dd'))" "$HOME/.config/sea-shell/appearance.json" 2>/dev/null)
    
    icon="♬"
    if [ "$status" = "Paused" ]; then
        icon="⏸"
    fi
    
    echo "<span color=\"$accent\">$icon</span>  <b>$title</b>  ·  $artist"
else
    echo ""
fi
