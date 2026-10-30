#!/bin/sh
# sea-shell — gaming performance preset: power profile + fans together.
#
#   sea-perf.sh auto | quiet | max | status
#
#   auto    balanced profile, fans on the firmware's own curve (sea-fancurve auto)
#   quiet   balanced profile, low fancontrol curve (sea-fancurve quiet)
#   max     performance profile, fans pinned at full speed (sea-fancurve max)
#   status  prints auto, quiet, max or custom, read from fancontrol and the fan's pwm mode
#
# The last preset set is saved to ~/.config/sea-shell/gaming-fans, and game mode applies it
# when a game starts (sea-gamemode.sh).
#
# The power profile goes through powerprofilesctl, the same owner the quick-settings
# profile row uses, so the two never disagree. The fan half needs root and goes through
# /usr/local/bin/sea-fancurve via `sudo -n` (see that script for the one-time setup);
# without it only the profile changes.

HELPER=/usr/local/bin/sea-fancurve

status() {
    if systemctl is-active -q fancontrol; then
        pwm=$(sed -n 's/^MAXPWM=[^=]*=\([0-9]*\).*/\1/p' /etc/fancontrol 2>/dev/null)
        [ "$pwm" = 120 ] && echo quiet || echo custom
        return
    fi
    dev=$(dirname "$(grep -lx acer /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1)")
    case "$(cat "$dev/pwm1_enable" 2>/dev/null):$(cat "$dev/pwm1" 2>/dev/null)" in
        2:*)   echo auto ;;
        1:255) echo max ;;
        *)     echo custom ;;
    esac
}

case "$1" in
    auto|quiet) prof=balanced ;;
    max)        prof=performance ;;
    status)     status; exit 0 ;;
    *)          echo "usage: $0 auto|quiet|max|status" >&2; exit 2 ;;
esac

# Remembered as the preset game mode applies (sea-gamemode.sh). While game mode is on it owns
# the profile, so only the fans change here.
mkdir -p ~/.config/sea-shell && echo "$1" > ~/.config/sea-shell/gaming-fans
[ "$(sh "$(dirname "$0")/sea-gamemode.sh" status 2>/dev/null)" = on ] && prof=performance
powerprofilesctl set "$prof" 2>/dev/null
if [ -x "$HELPER" ] && sudo -n "$HELPER" "$1"; then
    notify-send 'sea-shell' "Fans: $1 - $prof profile" 2>/dev/null
else
    notify-send 'sea-shell' "Fans: $1 - $prof profile only (sea-fancurve not set up)" 2>/dev/null
    exit 1
fi
