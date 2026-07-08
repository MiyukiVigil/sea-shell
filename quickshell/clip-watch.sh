#!/bin/sh
# sea-shell — (re)start the clipboard-history watchers exactly once.
# Because this pattern lives in a file, the `sh clip-watch.sh` process cmdline does
# NOT contain "wl-paste", so pkill matches only real watchers — never itself.
pkill -f "wl-paste --type text --watch cliphist store"  2>/dev/null
pkill -f "wl-paste --type image --watch cliphist store" 2>/dev/null
sleep 0.2
setsid wl-paste --type text  --watch cliphist store >/dev/null 2>&1 &
setsid wl-paste --type image --watch cliphist store >/dev/null 2>&1 &
