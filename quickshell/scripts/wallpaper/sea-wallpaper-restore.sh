#!/bin/sh
# sea-shell — restore the last-picked wallpaper at login, and start the auto-rotate supervisor.
#
# The actual apply logic lives in sea-wallpaper-apply.sh; this file used to carry its own copy
# of the swww/mpvpaper invocation, which is how the transition ended up hardcoded in two places.
# It now just picks the saved wallpaper (falling back to the shipped sea gradient) and delegates.
here="$(dirname "$0")"

# auto-rotate: off unless enabled in appearance.json — the daemon checks that itself and idles
# cheaply when off, so starting it unconditionally at login costs nothing.
sh "$here/sea-wallpaper-rotate.sh" >/dev/null 2>&1 &

exec sh "$here/sea-wallpaper-apply.sh"
