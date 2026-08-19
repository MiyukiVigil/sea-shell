#!/bin/sh
# sea-shell — the ONE place a wallpaper actually reaches a DAEMON.
#
# Usage: sea-wallpaper-apply.sh [/path/to/wallpaper]   put it on the screen
#        sea-wallpaper-apply.sh --freeze               swap the video for its poster
#        sea-wallpaper-apply.sh --resume               put the video back
#
# Every surface routes through here: sea-wallpaper-set.sh (which is what the picker, the
# SUPER+N keybinds, the rotate daemon and the `wallpaper set` IPC verb all call), and
# login restore. Before this file the swww invocation was copy-pasted into
# sea-wallpaper-restore.sh AND wallpaper.qml with the transition hardcoded to
# `grow --transition-fps 60` in both — so the transition could not be configured
# without editing two files, and the picker and the keybinds were free to drift.
#
# Animated wallpapers (mp4/webm/gif) go to mpvpaper; everything else to swww/awww, falling
# back to hyprpaper and then to mpvpaper-as-still-viewer.
#
# FREEZE.  A paused mpvpaper is not a free mpvpaper: it keeps its decoder, its surface and
# its VRAM for as long as it lives, which on a 6 GB card is exactly what you cannot spare
# while the thing covering the wallpaper is a game. So sea-wallpaper-autopause.sh can ask
# for the poster instead — swww draws it on the background layer UNDER mpvpaper, and only
# then is mpvpaper killed, so the swap has no black frame in either direction and costs
# nothing when nobody can see it anyway.

CFG="$HOME/.config/sea-shell"
here="$(dirname "$0")"

mode="apply"
case "$1" in
    --freeze) mode="freeze"; shift ;;
    --resume) mode="resume"; shift ;;
esac

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

# mpvpaper's options live here and only here — the freeze/resume pair would otherwise be a
# third copy of them, and a --hwdec changed in one place and not the others is a bug you
# only notice as heat.
MPV_SOCK="$XDG_RUNTIME_DIR/sea-mpvpaper.sock"
start_video() {
    command -v mpvpaper >/dev/null 2>&1 || {
        notify-send 'sea-shell' 'Animated wallpapers need mpvpaper: pacman -S mpvpaper' 2>/dev/null; return 1; }

    # Frame cap. A 60fps clip of something drifting slowly is 60 full-screen blits a
    # second that the COMPOSITOR has to do, on a machine where the iGPU is compositing
    # while the dGPU renders — that contention is the cost, not the decode. Capping to 30
    # halves the blits for motion you will not see the difference in. 0 = leave it alone,
    # which is the default.
    #
    # Read here rather than in the settings block below, because --resume comes through
    # this function without ever reaching it.
    vfps=$(python3 - <<'PYEOF' 2>/dev/null
import json, os
try:
    j = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
except Exception:
    j = {}
try:
    n = int(j.get("wpVidFps", 0) or 0)
except Exception:
    n = 0
print(n if 1 <= n <= 240 else 0)
PYEOF
)
    vf=""
    [ -n "$vfps" ] && [ "$vfps" -gt 0 ] 2>/dev/null && vf=" --vf=fps=$vfps"

    # WAIT for the old one to actually be gone, then remove the socket. A fixed 0.2s sleep
    # was a guess, and losing that race leaves the previous process's socket FILE on disk
    # with nothing listening on it: mpv will not bind an address that already exists, so the
    # new wallpaper comes up with no IPC at all. Everything that talks to it then fails
    # silently — which is how a paused wallpaper ends up with nothing able to unpause it.
    pkill -x mpvpaper 2>/dev/null
    i=0
    while pgrep -x mpvpaper >/dev/null 2>&1 && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
    rm -f "$MPV_SOCK"
    exec mpvpaper -o "no-audio --hwdec=auto --loop-file=inf --panscan=1.0$vf --input-ipc-server=$MPV_SOCK" '*' "$1"
}

# ---- freeze / resume: called by the autopause listener, never by a user surface -------
if [ "$mode" = "freeze" ]; then
    is_motion "$wp" || exit 0
    # The FULL-resolution frame, not the picker's 1280 thumbnail: this one replaces the video
    # on the actual desktop, and a 1280 still upscaled onto a 1920 panel is visibly soft.
    poster="$(python3 "$here/sea-wallpaper-index.py" --fullposter "$wp" 2>/dev/null)"
    [ -n "$poster" ] && [ -f "$poster" ] ||         poster="$(python3 "$here/sea-wallpaper-index.py" --poster "$wp" 2>/dev/null)"
    # Nothing to fall back to (no ffmpeg, or extraction failed) means killing mpvpaper would
    # leave an empty background. Staying is the safe answer.
    [ -n "$poster" ] && [ -f "$poster" ] || exit 0
    swww_up && "$SW" img "$poster" --transition-type none >/dev/null 2>&1
    pkill -x mpvpaper 2>/dev/null
    exit 0
fi
if [ "$mode" = "resume" ]; then
    is_motion "$wp" || exit 0
    pgrep -x mpvpaper >/dev/null 2>&1 && exit 0      # already playing
    start_video "$wp"
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

if is_motion "$wp"; then
    # fullscreen auto-pause / freeze listener (single-instance; safe to re-run)
    sh "$here/sea-wallpaper-autopause.sh" >/dev/null 2>&1 &
    # Seed the poster on the background layer first. mpvpaper covers it immediately, so
    # nothing changes on screen — but it means a later freeze has something to fall back
    # to without swww having to load a 4K JPEG at the exact moment a game is launching.
    poster="$(python3 "$here/sea-wallpaper-index.py" --fullposter "$wp" 2>/dev/null)"
    if [ -n "$poster" ] && [ -f "$poster" ] && swww_up; then
        "$SW" img "$poster" --transition-type none >/dev/null 2>&1
    fi
    start_video "$wp"
else
    # A video wallpaper sits ON TOP of swww on the background layer, so switching to a
    # static image must stop mpvpaper first or the video keeps playing over it. The [p]
    # bracket stops `pkill -f` matching this very command line and killing itself.
    pkill -x mpvpaper 2>/dev/null
    pkill -f 'sea-wallpaper-auto[p]ause' 2>/dev/null

    if swww_up; then
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
fi
