#!/bin/sh
# sea-shell — fan preset (ROOT helper).
#
#   sea-fancurve auto | quiet | max | firmware
#
#   auto      speeds up smoothly with temperature, sooner than the firmware does
#   quiet     stays slow, and only climbs when the CPU nears its limit
#   max       fast all the time, full speed once hot
#   firmware  stop sea-fand and hand the fans back to the firmware's own curve
#
# The curves themselves live in sea-fand. This only records which one to follow.
#
# It runs as root, so it takes no numbers, only the named presets: a sudoers rule for it
# then cannot be used to write arbitrary values to the fans or the config.
#
# Install (once): sudo sh sea-fan-setup.sh

STATE=/var/lib/sea-fan

case "$1" in
    auto|quiet|max)
        mkdir -p "$STATE"
        printf '%s\n' "$1" > "$STATE/mode.new" && mv "$STATE/mode.new" "$STATE/mode" || exit 1
        # the old curve must not be left fighting the daemon for the same pwm
        systemctl disable --now fancontrol 2>/dev/null
        systemctl reset-failed sea-fand 2>/dev/null
        systemctl enable --now sea-fand ;;
    firmware)
        systemctl disable --now sea-fand ;;
    *)  echo "usage: sea-fancurve auto|quiet|max|firmware" >&2; exit 2 ;;
esac
