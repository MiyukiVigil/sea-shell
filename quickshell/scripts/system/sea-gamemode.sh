#!/bin/sh
# sea-shell — Game Mode.
#
#   sea-gamemode.sh on | off | toggle | status
#
# Strips the desktop back to what a game actually needs, then puts it all back
# exactly as it was. Everything it changes is saved into the state file FIRST, so
# "off" restores your real settings rather than some hardcoded default.
#
# What it does and why, on this machine specifically (6GB VRAM, 15GB RAM, iGPU
# compositing while the dGPU renders):
#
#   wallpaper    KILLS mpvpaper rather than pausing it. sea-wallpaper-autopause.sh
#                already pauses the video when a fullscreen/borderless window covers
#                it — but a paused mpv still holds its process, its decoded frames and
#                its GPU context. Measured here: 248 MB RSS with a 6.3 GB virtual map.
#                Pausing frees none of that; exiting does.
#   blur         4 passes at size 9 over the whole screen, every frame, on the iGPU
#                that is also compositing the game.
#   shadow       range 24 at render_power 3 — a large blur kernel per window.
#   animations   nothing to animate while a game is fullscreen; costs frames on
#                workspace switches and alt-tabs.
#   power        performance profile, so the CPU does not downclock mid-frame.
#
# It does NOT touch DND: the bar owns that (root.dnd), and it watches the state file
# this script writes, so the shell applies and restores DND itself. That keeps one
# owner per setting instead of two fighting.
#
# State lives in XDG_RUNTIME_DIR — game mode must not survive a reboot, but it MUST
# survive a bar restart, which is exactly that directory's lifetime.

STATE="${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode.json"
WPFILE="$HOME/.config/sea-shell/wallpaper"

hypr() { hyprctl eval "$1" >/dev/null 2>&1; }

# Read a live Hyprland option. `hyprctl getoption X` prints e.g. "int: 1" / "set: true";
# take the value after the last space of the first line.
getopt_val() {
    hyprctl getoption "$1" 2>/dev/null | head -1 | awk '{print $NF}'
}

is_on() { [ -f "$STATE" ] && grep -q '"on"[[:space:]]*:[[:space:]]*true' "$STATE" 2>/dev/null; }

gm_on() {
    is_on && { echo "already on"; return 0; }

    # ---- capture what we are about to change, before changing any of it ----
    prof=$(powerprofilesctl get 2>/dev/null || echo balanced)
    blur=$(getopt_val decoration:blur:enabled)
    shadow=$(getopt_val decoration:shadow:enabled)
    anim=$(getopt_val animations:enabled)
    wp=$(cat "$WPFILE" 2>/dev/null | tr -d '\n\r')
    mpv=0; pgrep -x mpvpaper >/dev/null 2>&1 && mpv=1

    mkdir -p "$(dirname "$STATE")"
    cat > "$STATE" <<EOF
{"on":true,"profile":"$prof","blur":"$blur","shadow":"$shadow","anim":"$anim","mpvpaper":$mpv,"wallpaper":"$wp"}
EOF

    # ---- strip it back ----
    [ "$mpv" = 1 ] && pkill -x mpvpaper 2>/dev/null
    hypr 'hl.config({ decoration = { blur = { enabled = false }, shadow = { enabled = false } } })'
    hypr 'hl.config({ animations = { enabled = false } })'
    powerprofilesctl set performance 2>/dev/null

    notify-send 'sea-shell' 'Game mode on — effects off, performance profile' 2>/dev/null
    echo "on"
}

gm_off() {
    is_on || { echo "already off"; return 0; }

    # Read back what we saved. Defaults are only a fallback for a truncated state file.
    prof=$(sed -n 's/.*"profile":"\([^"]*\)".*/\1/p' "$STATE"); [ -z "$prof" ] && prof=balanced
    blur=$(sed -n 's/.*"blur":"\([^"]*\)".*/\1/p' "$STATE")
    shadow=$(sed -n 's/.*"shadow":"\([^"]*\)".*/\1/p' "$STATE")
    anim=$(sed -n 's/.*"anim":"\([^"]*\)".*/\1/p' "$STATE")
    mpv=$(sed -n 's/.*"mpvpaper":\([01]\).*/\1/p' "$STATE")

    # Restore the ACTUAL prior values — someone who games with blur already off should
    # not come out of game mode with blur suddenly on.
    [ "$blur"   = true ] && hypr 'hl.config({ decoration = { blur = { enabled = true } } })'
    [ "$shadow" = true ] && hypr 'hl.config({ decoration = { shadow = { enabled = true } } })'
    [ "$anim"   = true ] && hypr 'hl.config({ animations = { enabled = true } })'
    powerprofilesctl set "$prof" 2>/dev/null

    # Bring the wallpaper back through the normal apply path, so an animated wallpaper
    # gets its mpvpaper AND its autopause listener again rather than a bare process.
    if [ "$mpv" = 1 ]; then
        sh "$HOME/.config/quickshell/sea-shell/sea-wallpaper-restore.sh" >/dev/null 2>&1 &
    fi

    printf '{"on":false}\n' > "$STATE"
    notify-send 'sea-shell' 'Game mode off — desktop restored' 2>/dev/null
    echo "off"
}

case "${1:-toggle}" in
    on)     gm_on ;;
    off)    gm_off ;;
    status) is_on && echo on || echo off ;;
    toggle) if is_on; then gm_off; else gm_on; fi ;;
    *)      echo "usage: $0 on|off|toggle|status" >&2; exit 2 ;;
esac
