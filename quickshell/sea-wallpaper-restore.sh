#!/bin/sh
# sea-shell — restore the last-picked wallpaper at login.
# Animated (mp4/webm/gif → mpvpaper) or static (swww / its awww fork).
# Falls back to the sea gradient if nothing was ever picked.
wp="$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null)"
[ -f "$wp" ] || wp="$HOME/.config/sea-shell/sea-wall.png"
[ -f "$wp" ] || exit 0

case "$(printf '%s' "$wp" | tr '[:upper:]' '[:lower:]')" in
    *.mp4|*.webm|*.gif)
        command -v mpvpaper >/dev/null 2>&1 || exit 0
        pkill -x mpvpaper 2>/dev/null; sleep 0.2
        exec mpvpaper -o 'no-audio --loop-file=inf --panscan=1.0' '*' "$wp"
        ;;
    *)
        SW="$(command -v swww || command -v awww)" || exit 0
        SWD="$(command -v swww-daemon || command -v awww-daemon)"
        "$SW" query >/dev/null 2>&1 || { "$SWD" >/dev/null 2>&1 & sleep 0.5; }
        exec "$SW" img "$wp" --transition-type grow --transition-fps 60
        ;;
esac
