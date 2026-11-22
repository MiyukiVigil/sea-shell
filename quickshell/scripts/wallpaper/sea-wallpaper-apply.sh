#!/bin/sh
# sea-shell — the ONE place a wallpaper actually reaches a DAEMON.
#
# Usage: sea-wallpaper-apply.sh [/path/to/wallpaper]   put it on the screen
#
# Every surface routes through here: sea-wallpaper-set.sh (which is what the picker, the
# SUPER+N keybinds, the rotate daemon and the `wallpaper set` IPC verb all call), and
# login restore. Before this file the swww invocation was copy-pasted into
# sea-wallpaper-restore.sh AND wallpaper.qml with the transition hardcoded to
# `grow --transition-fps 60` in both — so the transition could not be configured
# without editing two files, and the picker and the keybinds were free to drift.
#
# Stills go to swww/awww, falling back to hyprpaper. Clips (mp4/webm/gif/mkv/mov) are played
# by the bar itself (VideoWallpaper.qml), which watches ~/.config/sea-shell/wallpaper — so for
# a clip this only lays its poster on awww UNDER the bar's surface. That still is what shows
# while the bar restarts, and what game mode / fullscreen freeze back to.

CFG="$HOME/.config/sea-shell"
here="$(dirname "$0")"

wp="${1:-$(cat "$CFG/wallpaper" 2>/dev/null)}"
[ -f "$wp" ] || wp="$CFG/sea-wall.png"
[ -f "$wp" ] || exit 0

SW="$(command -v swww || command -v awww)"
SWD="$(command -v swww-daemon || command -v awww-daemon)"

swww_up() {
    [ -n "$SW" ] || return 1
    "$SW" query >/dev/null 2>&1 || { [ -n "$SWD" ] && "$SWD" >/dev/null 2>&1 & sleep 0.5; }
    "$SW" query >/dev/null 2>&1
}

is_motion() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *.mp4|*.webm|*.gif|*.mkv|*.mov) return 0 ;;
        *) return 1 ;;
    esac
}

if is_motion "$wp"; then
    # The FULL-resolution frame, not the picker's 1280 thumbnail: it is the desktop whenever
    # the video is not, and a 1280 still upscaled onto a 1920 panel is visibly soft.
    poster="$(python3 "$here/sea-wallpaper-index.py" --fullposter "$wp" 2>/dev/null)"
    [ -n "$poster" ] && [ -f "$poster" ] || \
        poster="$(python3 "$here/sea-wallpaper-index.py" --poster "$wp" 2>/dev/null)"
    if [ -n "$poster" ] && [ -f "$poster" ] && swww_up; then
        "$SW" img "$poster" --transition-type none >/dev/null 2>&1
    fi
    # awww and the bar's video share the background layer, which Hyprland stacks by map
    # order. If awww-daemon was (re)started just now it is on top — ask the bar to remap.
    qs -c sea-shell ipc call wallpaper remap >/dev/null 2>&1
    exit 0
fi

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
# Login restoration should present the saved wallpaper without a reveal animation.
[ "${SEA_WALLPAPER_LOGIN:-0}" = "1" ] && TR=none

if swww_up; then
    exec "$SW" img "$wp" \
        --transition-type "$TR" \
        --transition-fps "$FPS" \
        --transition-duration "$DUR"
elif command -v hyprpaper >/dev/null 2>&1; then
    killall hyprpaper 2>/dev/null; hyprpaper >/dev/null 2>&1 & sleep 0.3
    hyprctl hyprpaper preload "$wp" >/dev/null 2>&1
    hyprctl hyprpaper wallpaper ",\"$wp\"" >/dev/null 2>&1
else
    notify-send 'sea-shell' 'Install a wallpaper daemon: pacman -S awww  (or swww / hyprpaper)' 2>/dev/null
fi
