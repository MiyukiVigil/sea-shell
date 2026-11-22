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
#   wallpaper    nothing to do here: the bar watches this script's state file and FREEZES
#                a video wallpaper (unloads its decoder, shows the poster) while game
#                mode is on, then plays it again when it goes off.
#   blur         4 passes at size 9 over the whole screen, every frame, on the iGPU
#                that is also compositing the game.
#   shadow       range 24 at render_power 3 — a large blur kernel per window.
#   animations   nothing to animate while a game is fullscreen; costs frames on
#                workspace switches and alt-tabs.
#   power        performance profile, so the CPU does not downclock mid-frame.
#   fans         the fan preset picked in quick settings (saved by sea-perf.sh
#                to ~/.config/sea-shell/gaming-fans), through the root helper sea-fancurve.
#                Skipped when either is missing.
#   idle         stops hypridle. A controller is not input to Wayland, so without this
#                the screen dims and locks mid-game.
#
# Switched on by hand it also asks Feral gamemode for its side (CPU governor, process priority),
# by keeping a `gamemoded -r` request open until off. That request fires the start hook below,
# which finds game mode already on and does nothing, and its end hook does not undo a manual on.
#
# auto-on / auto-off are for Feral gamemode's [custom] start/end hooks (~/.config/gamemode.ini),
# so any game launched through gamemoderun switches game mode on and off by itself. auto-on
# does nothing when game mode is already on, and auto-off only undoes an auto-on: game mode
# switched on by hand is never switched off by a game exiting.
#
# Those hooks run inside gamemoded's service, so anything long-lived (hypridle) is
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
HOLD="${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode-feral.pid"
# written by sea-gaming.py for a game whose profile has "Game mode on play" off
SKIP="${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode-skip"
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

# Read a live Hyprland option. `hyprctl getoption X` prints e.g. "int: 10" / "bool: true" / "float: 0.960000";
# take the value after the last space of the first line.
getopt_val() {
    hyprctl getoption "$1" 2>/dev/null | head -1 | awk '{print $NF}'
}

# Read a Hyprland css gap option ("css gap data: 5 5 5 5" -> "5 5 5 5").
getopt_gap() {
    hyprctl getoption "$1" 2>/dev/null | head -1 | sed -n 's/^css gap data:[[:space:]]*//p'
}

# Format "T R B L" as a Hyprland 0.55+ Lua css_gap table.
gap_lua() {
    set -- $1
    case "$1:$2:$3:$4" in
        [0-9]*:[0-9]*:[0-9]*:[0-9]*)
            printf '{ top = %s, right = %s, bottom = %s, left = %s }' "$1" "$2" "$3" "$4"
            ;;
    esac
}

# Opt-in Level 2 ("Ultra / Zero-Shell"): stop seashell + wallpaper/clipboard daemons while
# game mode is active. Never enabled inside the dedicated `sea-shell Gaming` session (Big Picture).
want_suspend_shell() {
    [ "${SEA_SESSION:-}" = gaming ] && return 1
    python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    j = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
    sys.exit(0 if bool(j.get("suspendShellGaming", False)) else 1)
except Exception:
    sys.exit(1)
PY
}

hypr_toast() {
    hyprctl notify -1 3500 "rgb(63c7dd)" "$1" >/dev/null 2>&1 || true
}

is_on() { [ -f "$STATE" ] && grep -q '"on"[[:space:]]*:[[:space:]]*true' "$STATE" 2>/dev/null; }
is_auto() { grep -q '"auto":true' "$STATE" 2>/dev/null; }
is_suspended() { grep -q '"shell_suspended":true' "$STATE" 2>/dev/null; }
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$STATE"; }
int_field() { sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" "$STATE"; }

fans() { [ -x "$FANHELPER" ] && sudo -n "$FANHELPER" "$1" >/dev/null 2>&1; }
fan_now() { sh "$HERE/sea-perf.sh" status 2>/dev/null; }

# A pid file can outlive its process and the number be reused, so check what it points at.
feral_release() {
    pid=$(cat "$HOLD" 2>/dev/null)
    [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = gamemoded ] && kill "$pid" 2>/dev/null
    rm -f "$HOLD"
}
feral_hold() {
    feral_release
    command -v gamemoded >/dev/null 2>&1 || return 0
    setsid gamemoded -r >/dev/null 2>&1 &
    echo $! > "$HOLD"
}

# While Feral holds the governor on performance the CPU driver refuses a profile change (EBUSY on
# energy_performance_preference), and Feral takes some seconds to notice a game or request has
# ended. A single attempt fails silently and leaves the machine in performance, so keep trying,
# in the background so the desktop comes back right away.
restore_profile() {
    powerprofilesctl set "$1" 2>/dev/null && return
    (
        i=0
        while [ "$i" -lt 60 ]; do
            sleep 0.5
            powerprofilesctl set "$1" 2>/dev/null && exit 0
            i=$((i + 1))
        done
    ) >/dev/null 2>&1 &
}

gm_on() {
    is_on && { echo "already on"; return 0; }
    auto=${1:-false}

    # ---- capture what we are about to change, before changing any of it ----
    prof=$(powerprofilesctl get 2>/dev/null || echo balanced)
    blur=$(getopt_val decoration:blur:enabled)
    shadow=$(getopt_val decoration:shadow:enabled)
    anim=$(getopt_val animations:enabled)
    rounding=$(getopt_val decoration:rounding)
    gaps_in=$(getopt_gap general:gaps_in)
    gaps_out=$(getopt_gap general:gaps_out)
    border_size=$(getopt_val general:border_size)
    inact_op=$(getopt_val decoration:inactive_opacity)
    wp=$(cat "$WPFILE" 2>/dev/null | tr -d '\n\r')
    idle=0; pgrep -x hypridle >/dev/null 2>&1 && idle=1
    fan=$(fan_now)
    want=$(cat "$FANPREF" 2>/dev/null | tr -d '\n\r')

    suspend_shell=false
    awww_was=0
    rotate_was=0
    if want_suspend_shell; then
        suspend_shell=true
        (pgrep -x awww-daemon >/dev/null 2>&1 || pgrep -x swww-daemon >/dev/null 2>&1) && awww_was=1
        pgrep -f 'sea-wallpaper-rotate\.sh' >/dev/null 2>&1 && rotate_was=1
    fi

    mkdir -p "$(dirname "$STATE")"
    cat > "$STATE" <<EOF
{"on":true,"auto":$auto,"profile":"$prof","blur":"$blur","shadow":"$shadow","anim":"$anim","rounding":"$rounding","gaps_in":"$gaps_in","gaps_out":"$gaps_out","border_size":"$border_size","inactive_opacity":"$inact_op","hypridle":$idle,"fans":"$fan","wallpaper":"$wp","shell_suspended":$suspend_shell,"awww_was":$awww_was,"rotate_was":$rotate_was}
EOF

    # after the state file, so the start hook this fires sees game mode already on
    [ "$auto" = true ] || feral_hold

    # ---- strip it back ----
    [ "$idle" = 1 ] && pkill -x hypridle 2>/dev/null
    hypr 'hl.config({ general = { gaps_in = 0, gaps_out = 0, border_size = 0 }, decoration = { rounding = 0, inactive_opacity = 1.0, blur = { enabled = false }, shadow = { enabled = false } }, animations = { enabled = false } })'
    case "$want" in auto|quiet|max) [ "$want" != "$fan" ] && fans "$want" ;; esac
    powerprofilesctl set performance 2>/dev/null

    if [ "$suspend_shell" = true ]; then
        # Level 2 (Ultra / Zero-Shell): tear down seashell + desktop background helpers so
        # 100% of shell RAM, VRAM, and wakeups are reclaimed while gaming.
        sh "$HERE/sea-bar-supervisor.sh" --stop >/dev/null 2>&1 || true
        sh "$HERE/sea-wallpaper-rotate.sh" --stop >/dev/null 2>&1 || true
        pkill -f 'mpvpaper.*sea-shell/wallvideo' 2>/dev/null || true
        pkill -KILL -f 'mpvpaper.*sea-shell/wallvideo' 2>/dev/null || true
        pkill -x awww-daemon 2>/dev/null || true
        pkill -x swww-daemon 2>/dev/null || true
        pkill -f 'wl-paste --type text --watch cliphist store'  2>/dev/null || true
        pkill -f 'wl-paste --type image --watch cliphist store' 2>/dev/null || true
        msg='sea-shell: Ultra game mode ON (shell suspended) — Super+Shift+G to restore'
        [ "$auto" = true ] && msg='sea-shell: Ultra game mode ON — restores on game exit or Super+Shift+G'
        hypr_toast "$msg"
    else
        msg='Game mode on — effects off, shell hibernated, performance profile'
        [ "$auto" = true ] && msg='Game started — effects off, shell hibernated, performance profile'
        case "$want" in auto|quiet|max) msg="$msg, fans $want" ;; esac
        notify-send 'sea-shell' "$msg" 2>/dev/null
    fi
    echo "on"
}

gm_off() {
    is_on || { echo "already off"; return 0; }

    feral_release

    # Read back what we saved. Defaults are only a fallback for a truncated state file.
    prof=$(field profile); [ -z "$prof" ] && prof=balanced
    blur=$(field blur)
    shadow=$(field shadow)
    anim=$(field anim)
    rounding=$(field rounding)
    gaps_in=$(field gaps_in)
    gaps_out=$(field gaps_out)
    border_size=$(field border_size)
    inact_op=$(field inactive_opacity)
    fan=$(field fans)
    idle=$(int_field hypridle)
    was_suspended=0; is_suspended && was_suspended=1
    awww_was=$(int_field awww_was)
    rotate_was=$(int_field rotate_was)

    # Restore the ACTUAL prior values — someone who games with blur already off should
    # not come out of game mode with blur suddenly on.
    [ "$blur"   = true ] && hypr 'hl.config({ decoration = { blur = { enabled = true } } })'
    [ "$shadow" = true ] && hypr 'hl.config({ decoration = { shadow = { enabled = true } } })'
    [ "$anim"   = true ] && hypr 'hl.config({ animations = { enabled = true } })'
    case "$rounding" in [0-9]*) hypr "hl.config({ decoration = { rounding = $rounding } })" ;; esac
    case "$border_size" in [0-9]*) hypr "hl.config({ general = { border_size = $border_size } })" ;; esac
    case "$inact_op" in [0-9]*) hypr "hl.config({ decoration = { inactive_opacity = $inact_op } })" ;; esac
    gin_tbl=$(gap_lua "$gaps_in")
    [ -n "$gin_tbl" ] && hypr "hl.config({ general = { gaps_in = $gin_tbl } })"
    gout_tbl=$(gap_lua "$gaps_out")
    [ -n "$gout_tbl" ] && hypr "hl.config({ general = { gaps_out = $gout_tbl } })"

    case "$fan" in auto|quiet|max) [ "$fan" != "$(fan_now)" ] && fans "$fan" ;; esac
    restore_profile "$prof"

    # The bar sees this and plays the video wallpaper again.
    printf '{"on":false}\n' > "$STATE"

    # caffeine switched on mid-game wants hypridle to stay off
    if [ "$idle" = 1 ] && [ "$(cat "$HOME/.config/sea-shell/caffeine" 2>/dev/null)" != 1 ] \
        && ! pgrep -x hypridle >/dev/null; then
        hypr_exec hypridle
    fi

    if [ "$was_suspended" = 1 ]; then
        hypr_toast 'sea-shell: Game mode off — restoring desktop...'
        if [ "$awww_was" = 1 ] || [ "$rotate_was" = 1 ]; then
            hypr_exec "sh $HERE/sea-wallpaper-restore.sh"
        fi
        hypr_exec "sh $HERE/sea-bar-supervisor.sh"
    else
        notify-send 'sea-shell' 'Game mode off — desktop restored' 2>/dev/null
    fi
    echo "off"
}

case "${1:-toggle}" in
    on)       gm_on ;;
    off)      gm_off ;;
    auto-on)  [ -f "$SKIP" ] || gm_on true ;;
    auto-off)
        # Steam's launch chain registers and exits several short-lived wrappers, and Feral leaves
        # and re-enters between them. Only act if it is still inactive a few seconds later, or
        # every launch tears the wallpaper and fans down and brings them straight back.
        (
            sleep 8
            gamemoded -s 2>/dev/null | grep -q 'is active' && exit 0
            rm -f "$SKIP"
            if is_on && is_auto; then gm_off; fi
        ) >/dev/null 2>&1 &
        ;;
    status)   is_on && echo on || echo off ;;
    toggle)   if is_on; then gm_off; else gm_on; fi ;;
    *)        echo "usage: $0 on|off|toggle|status|auto-on|auto-off" >&2; exit 2 ;;
esac
