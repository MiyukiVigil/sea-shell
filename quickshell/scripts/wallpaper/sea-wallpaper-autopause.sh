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

# Only one listener per session. The lock is keyed to the Hyprland instance so a
# listener stranded by a previous session can never block this one — and fd 9 is
# closed for the ncat below, because an ncat that outlives its parent script (its
# event socket died with the old compositor) would otherwise hold the lock
# forever and silently prevent every future listener from starting.
exec 9>"$XDG_RUNTIME_DIR/sea-autopause-$HYPRLAND_INSTANCE_SIGNATURE.lock"
flock -n 9 || exit 0

setp() { printf '{"command":["set_property","pause",%s]}\n' "$1" | ncat -U "$SOCK" >/dev/null 2>&1; }

# Pause iff the wallpaper is hidden on EVERY monitor. Querying the live state
# (rather than counting enter/exit events) keeps us correct across workspace and
# monitor switches, not just fullscreen toggles.
#
# "Hidden" is not the same as Hyprland's `hasfullscreen`: most games — and every
# maximised window — run BORDERLESS, which is an ordinary window that merely
# covers the whole monitor. Those left a 4K video decoding at full rate behind a
# game, fighting it for the same iGPU. So a monitor counts as covered when its
# active workspace holds a fullscreen window OR a window filling >=95% of it.
# Old behaviour also only ever looked at the FOCUSED monitor, which paused a
# wallpaper that was still plainly visible on the other screen.
covered() {
    python3 - <<'PY' 2>/dev/null
import json, subprocess, sys

def hj(what):
    try:
        out = subprocess.run(["hyprctl", what, "-j"], capture_output=True,
                             text=True, timeout=4).stdout
        return json.loads(out or "[]")
    except Exception:
        sys.exit(1)                      # can't tell -> assume visible, keep playing

mons, clients = hj("monitors"), hj("clients")
for m in mons:
    if m.get("disabled"):
        continue
    scale = m.get("scale") or 1
    mw, mh = m.get("width", 0) / scale, m.get("height", 0) / scale
    # the bar's exclusive zone is not wallpaper the user can see
    res = m.get("reserved") or [0, 0, 0, 0]
    uw, uh = mw - res[0] - res[2], mh - res[1] - res[3]
    usable = max(uw * uh, 1)
    ws = (m.get("activeWorkspace") or {}).get("id")

    tiled_area = 0
    hidden = False
    for c in clients:
        if (c.get("workspace") or {}).get("id") != ws:
            continue
        if c.get("hidden") or not c.get("mapped"):
            continue
        w, h = (c.get("size") or [0, 0])[:2]
        # fullscreen, or a borderless window sized to the whole monitor (games)
        if c.get("fullscreen") or (mw and mh and w >= mw * 0.95 and h >= mh * 0.95):
            hidden = True
            break
        # tiled windows never overlap, so their areas add up to real coverage
        if not c.get("floating"):
            tiled_area += w * h
    if not hidden and tiled_area / usable < 0.85:
        sys.exit(1)                      # wallpaper still visible somewhere
sys.exit(0)
PY
}

sync() {
    if covered; then setp true; else setp false; fi
}

# give mpvpaper a moment to create its socket, then match the current state
i=0; while [ ! -S "$SOCK" ] && [ "$i" -lt 25 ]; do i=$((i+1)); sleep 0.2; done
sync

# Re-evaluate on anything that changes what's on screen in front of the wallpaper.
# open/close/move/float matter as much as `fullscreen` now that a borderless window
# filling the monitor counts as covering it — a game launched into an existing
# workspace emits openwindow and nothing else.
ncat -U "$EV" 2>/dev/null 9<&- | while IFS= read -r line; do
    case "$line" in
        fullscreen\>\>*|workspace\>\>*|workspacev2\>\>*|focusedmon\>\>*|focusedmonv2\>\>*|\
        openwindow\>\>*|closewindow\>\>*|movewindow\>\>*|movewindowv2\>\>*|\
        changefloatingmode\>\>*|monitoradded\>\>*|monitorremoved\>\>*) sync ;;
    esac
done
