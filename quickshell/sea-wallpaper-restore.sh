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
        S="$XDG_RUNTIME_DIR/sea-mpvpaper.sock"; rm -f "$S"
        # start the fullscreen auto-pause listener (single-instance; safe to re-run)
        sh "$(dirname "$0")/sea-wallpaper-autopause.sh" >/dev/null 2>&1 &
        # the mpv IPC socket lets that listener pause playback under fullscreen windows
        exec mpvpaper -o "no-audio --loop-file=inf --panscan=1.0 --input-ipc-server=$S" '*' "$wp"
        ;;
    *)
        # a video wallpaper sits on top of swww on the background layer, so switching
        # to a static one must stop mpvpaper (and its fullscreen auto-pause listener)
        # first — otherwise the video keeps playing over the new static image.
        pkill -x mpvpaper 2>/dev/null
        pkill -f 'sea-wallpaper-auto[p]ause' 2>/dev/null
        SW="$(command -v swww || command -v awww)" || exit 0
        SWD="$(command -v swww-daemon || command -v awww-daemon)"
        "$SW" query >/dev/null 2>&1 || { "$SWD" >/dev/null 2>&1 & sleep 0.5; }
        exec "$SW" img "$wp" --transition-type grow --transition-fps 60
        ;;
esac
