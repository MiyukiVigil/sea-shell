#!/bin/sh
# sea-shell — Game Mode.
#
#   sea-gamemode.sh on | off | toggle | status | auto-on | auto-off
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
#   fans         the "gaming fans" preset picked in quick settings (saved by sea-perf.sh
#                to ~/.config/sea-shell/gaming-fans), through the root helper sea-fancurve.
#                Skipped when either is missing.
#   idle         stops hypridle. A controller is not input to Wayland, so without this
#                the screen dims and locks mid-game.
#
# auto-on / auto-off are for Feral gamemode's [custom] start/end hooks (~/.config/gamemode.ini),
# so any game launched through gamemoderun switches game mode on and off by itself. auto-on
# does nothing when game mode is already on, and auto-off only undoes an auto-on: game mode
# switched on by hand is never switched off by a game exiting.
#
# Those hooks run inside gamemoded's service, so anything long-lived (mpvpaper, hypridle) is
# started through Hyprland instead: a child of the hook would die with the service.
#
# It does NOT touch DND: the bar owns that (root.dnd), and it watches the state file
# this script writes, so the shell applies and restores DND itself. That keeps one
# owner per setting instead of two fighting.
#
# State lives in XDG_RUNTIME_DIR — game mode must not survive a reboot, but it MUST
# survive a bar restart, which is exactly that directory's lifetime.

STATE="${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode.json"
WPFILE="$HOME/.config/sea-shell/wallpaper"
FANPREF="$HOME/.config/sea-shell/gaming-fans"
FANHELPER=/usr/local/bin/sea-fancurve
HERE="$HOME/.config/quickshell/sea-shell"

# A service started before this login can carry a stale instance signature; fall back to the
# newest live instance so hyprctl still reaches the running compositor.
if ! hyprctl version >/dev/null 2>&1; then
    sig=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" 2>/dev/null | head -1)
    [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

hypr() { hyprctl eval "$1" >/dev/null 2>&1; }
# start a long-lived process as a child of Hyprland, not of this script
hypr_exec() { hyprctl dispatch "hl.dsp.exec_cmd('$1')" >/dev/null 2>&1; }

# Read a live Hyprland option. `hyprctl getoption X` prints e.g. "int: 1" / "set: true";
# take the value after the last space of the first line.
getopt_val() {
    hyprctl getoption "$1" 2>/dev/null | head -1 | awk '{print $NF}'
}

is_on() { [ -f "$STATE" ] && grep -q '"on"[[:space:]]*:[[:space:]]*true' "$STATE" 2>/dev/null; }
is_auto() { grep -q '"auto":true' "$STATE" 2>/dev/null; }
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$STATE"; }

fans() { [ -x "$FANHELPER" ] && sudo -n "$FANHELPER" "$1" >/dev/null 2>&1; }
fan_now() { sh "$HERE/sea-perf.sh" status 2>/dev/null; }

gm_on() {
    is_on && { echo "already on"; return 0; }
    auto=${1:-false}

    # ---- capture what we are about to change, before changing any of it ----
    prof=$(powerprofilesctl get 2>/dev/null || echo balanced)
    blur=$(getopt_val decoration:blur:enabled)
    shadow=$(getopt_val decoration:shadow:enabled)
    anim=$(getopt_val animations:enabled)
    wp=$(cat "$WPFILE" 2>/dev/null | tr -d '\n\r')
    mpv=0; pgrep -x mpvpaper >/dev/null 2>&1 && mpv=1
    idle=0; pgrep -x hypridle >/dev/null 2>&1 && idle=1
    fan=$(fan_now)
    want=$(cat "$FANPREF" 2>/dev/null | tr -d '\n\r')

    mkdir -p "$(dirname "$STATE")"
    cat > "$STATE" <<EOF
{"on":true,"auto":$auto,"profile":"$prof","blur":"$blur","shadow":"$shadow","anim":"$anim","mpvpaper":$mpv,"hypridle":$idle,"fans":"$fan","wallpaper":"$wp"}
EOF

    # ---- strip it back ----
    [ "$mpv" = 1 ] && pkill -x mpvpaper 2>/dev/null
    [ "$idle" = 1 ] && pkill -x hypridle 2>/dev/null
    hypr 'hl.config({ decoration = { blur = { enabled = false }, shadow = { enabled = false } } })'
    hypr 'hl.config({ animations = { enabled = false } })'
    case "$want" in auto|quiet|max) [ "$want" != "$fan" ] && fans "$want" ;; esac
    powerprofilesctl set performance 2>/dev/null

    msg='Game mode on — effects off, performance profile'
    [ "$auto" = true ] && msg='Game started — effects off, performance profile'
    case "$want" in auto|quiet|max) msg="$msg, fans $want" ;; esac
    notify-send 'sea-shell' "$msg" 2>/dev/null
    echo "on"
}

gm_off() {
    is_on || { echo "already off"; return 0; }

    # Read back what we saved. Defaults are only a fallback for a truncated state file.
    prof=$(field profile); [ -z "$prof" ] && prof=balanced
    blur=$(field blur)
    shadow=$(field shadow)
    anim=$(field anim)
    fan=$(field fans)
    mpv=$(sed -n 's/.*"mpvpaper":\([01]\).*/\1/p' "$STATE")
    idle=$(sed -n 's/.*"hypridle":\([01]\).*/\1/p' "$STATE")

    # Restore the ACTUAL prior values — someone who games with blur already off should
    # not come out of game mode with blur suddenly on.
    [ "$blur"   = true ] && hypr 'hl.config({ decoration = { blur = { enabled = true } } })'
    [ "$shadow" = true ] && hypr 'hl.config({ decoration = { shadow = { enabled = true } } })'
    [ "$anim"   = true ] && hypr 'hl.config({ animations = { enabled = true } })'
    case "$fan" in auto|quiet|max) [ "$fan" != "$(fan_now)" ] && fans "$fan" ;; esac
    powerprofilesctl set "$prof" 2>/dev/null

    # Bring the wallpaper back through the normal apply path, so an animated wallpaper
    # gets its mpvpaper AND its autopause listener again rather than a bare process.
    [ "$mpv" = 1 ] && hypr_exec "sh $HERE/sea-wallpaper-restore.sh"
    # caffeine switched on mid-game wants hypridle to stay off
    if [ "$idle" = 1 ] && [ "$(cat "$HOME/.config/sea-shell/caffeine" 2>/dev/null)" != 1 ] \
        && ! pgrep -x hypridle >/dev/null; then
        hypr_exec hypridle
    fi

    printf '{"on":false}\n' > "$STATE"
    notify-send 'sea-shell' 'Game mode off — desktop restored' 2>/dev/null
    echo "off"
}

case "${1:-toggle}" in
    on)       gm_on ;;
    off)      gm_off ;;
    auto-on)  gm_on true ;;
    auto-off) if is_on && is_auto; then gm_off; else echo "not auto"; fi ;;
    status)   is_on && echo on || echo off ;;
    toggle)   if is_on; then gm_off; else gm_on; fi ;;
    *)        echo "usage: $0 on|off|toggle|status|auto-on|auto-off" >&2; exit 2 ;;
esac
