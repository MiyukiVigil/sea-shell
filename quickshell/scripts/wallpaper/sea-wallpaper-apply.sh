#!/bin/sh
# sea-shell — the ONE place a wallpaper actually gets applied.
#
# Usage: sea-wallpaper-apply.sh [/path/to/wallpaper]      (defaults to the saved one)
#
# Every surface routes through here: the picker (wallpaper.qml), the SUPER+N cycle keybinds
# (sea-wallpaper-cycle.sh), login restore, and the auto-rotate daemon. Before this file the
# swww invocation was copy-pasted into sea-wallpaper-restore.sh AND wallpaper.qml with the
# transition hardcoded to `grow --transition-fps 60` in both — so the transition could not be
# configured without editing two files, and the picker and the keybinds were free to drift.
#
# Animated wallpapers (mp4/webm/gif) go to mpvpaper; everything else to swww/awww, falling
# back to hyprpaper and then to mpvpaper-as-still-viewer.

CFG="$HOME/.config/sea-shell"
wp="${1:-$(cat "$CFG/wallpaper" 2>/dev/null)}"
[ -f "$wp" ] || wp="$CFG/sea-wall.png"
[ -f "$wp" ] || exit 0

here="$(dirname "$0")"

# ---- transition settings, read in ONE python call (this runs on every switch) ----
# awww/swww types: none simple fade left right top bottom wipe wave grow center any outer random
eval "$(python3 - <<'PY' 2>/dev/null
import json, os, shlex
try:
    j = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
except Exception:
    j = {}
def g(k, d):
    v = j.get(k, d)
    return d if v in (None, "") else v
print("TR=%s"  % shlex.quote(str(g("wpTransition",    "grow"))))
print("FPS=%s" % shlex.quote(str(g("wpTransitionFps", 60))))
print("DUR=%s" % shlex.quote(str(g("wpTransitionDur", 1))))
PY
)"
[ -z "$TR" ]  && TR=grow
[ -z "$FPS" ] && FPS=60
[ -z "$DUR" ] && DUR=1

case "$(printf '%s' "$wp" | tr '[:upper:]' '[:lower:]')" in
    *.mp4|*.webm|*.gif)
        command -v mpvpaper >/dev/null 2>&1 || {
            notify-send 'sea-shell' 'Animated wallpapers need mpvpaper: pacman -S mpvpaper' 2>/dev/null; exit 0; }
        pkill -x mpvpaper 2>/dev/null; sleep 0.2
        S="$XDG_RUNTIME_DIR/sea-mpvpaper.sock"; rm -f "$S"
        # fullscreen auto-pause listener (single-instance; safe to re-run)
        sh "$here/sea-wallpaper-autopause.sh" >/dev/null 2>&1 &
        exec mpvpaper -o "no-audio --hwdec=auto --loop-file=inf --panscan=1.0 --input-ipc-server=$S" '*' "$wp"
        ;;
    *)
        # A video wallpaper sits ON TOP of swww on the background layer, so switching to a
        # static image must stop mpvpaper first or the video keeps playing over it. The [p]
        # bracket stops `pkill -f` matching this very command line and killing itself.
        pkill -x mpvpaper 2>/dev/null
        pkill -f 'sea-wallpaper-auto[p]ause' 2>/dev/null

        SW="$(command -v swww || command -v awww)"
        if [ -n "$SW" ]; then
            SWD="$(command -v swww-daemon || command -v awww-daemon)"
            "$SW" query >/dev/null 2>&1 || { "$SWD" >/dev/null 2>&1 & sleep 0.5; }
            exec "$SW" img "$wp" \
                --transition-type "$TR" \
                --transition-fps "$FPS" \
                --transition-duration "$DUR"
        elif command -v hyprpaper >/dev/null 2>&1; then
            killall hyprpaper 2>/dev/null; hyprpaper >/dev/null 2>&1 & sleep 0.3
            hyprctl hyprpaper preload "$wp" >/dev/null 2>&1
            hyprctl hyprpaper wallpaper ",\"$wp\"" >/dev/null 2>&1
        elif command -v mpvpaper >/dev/null 2>&1; then
            exec mpvpaper -o 'no-audio --image-display-duration=inf --panscan=1.0' '*' "$wp"
        else
            notify-send 'sea-shell' 'Install a wallpaper daemon: pacman -S swww  (or hyprpaper / mpvpaper)' 2>/dev/null
        fi
        ;;
esac
