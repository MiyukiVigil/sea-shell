#!/bin/sh
# sea-shell — lock the screen safely.
# If hypridle is running, use loginctl lock-session (better systemd integration).
# Otherwise (e.g. caffeine mode active), lock directly via hyprlock.

if pidof hyprlock >/dev/null 2>&1; then
    exit 0
fi

if pgrep -x hypridle >/dev/null 2>&1; then
    loginctl lock-session
else
    # Run hyprlock directly in the background/detached
    hyprlock &
fi
