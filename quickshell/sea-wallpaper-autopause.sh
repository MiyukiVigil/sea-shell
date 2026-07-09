#!/bin/sh
# sea-shell — pause the mpvpaper video wallpaper whenever it's covered by a
# fullscreen window, and resume it when the wallpaper is visible again.
#
# mpvpaper's own --auto-pause doesn't detect Hyprland's fullscreen occlusion
# reliably, so we drive mpv directly: listen to Hyprland's event socket and
# toggle mpv's `pause` property over its IPC socket.
#
# Single-instance (flock). Started alongside mpvpaper by the wallpaper
# setter (wallpaper.qml) and the login restorer (sea-wallpaper-restore.sh);
# re-running while one is live is a no-op.

SOCK="$XDG_RUNTIME_DIR/sea-mpvpaper.sock"                       # mpv IPC socket
EV="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"  # hypr events

command -v ncat >/dev/null 2>&1 || exit 0
[ -S "$EV" ] || exit 0

# only one listener per session
exec 9>"$XDG_RUNTIME_DIR/sea-autopause.lock"
flock -n 9 || exit 0

setp() { printf '{"command":["set_property","pause",%s]}\n' "$1" | ncat -U "$SOCK" >/dev/null 2>&1; }

# pause iff the currently-viewed workspace holds a fullscreen window. Querying
# the live state (rather than counting enter/exit events) keeps us correct
# across workspace and monitor switches, not just fullscreen toggles.
sync() {
    if hyprctl activeworkspace -j 2>/dev/null | grep -q '"hasfullscreen": *true'; then
        setp true
    else
        setp false
    fi
}

# give mpvpaper a moment to create its socket, then match the current state
i=0; while [ ! -S "$SOCK" ] && [ "$i" -lt 25 ]; do i=$((i+1)); sleep 0.2; done
sync

# re-evaluate on anything that changes what's on screen in front of the wallpaper
ncat -U "$EV" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        fullscreen\>\>*|workspace\>\>*|workspacev2\>\>*|focusedmon\>\>*|focusedmonv2\>\>*) sync ;;
    esac
done
