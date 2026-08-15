#!/bin/sh
# sea-shell — auto-rotate the wallpaper on a timer.
#
# Usage:  sea-wallpaper-rotate.sh              supervise (started from hyprland.lua)
#         sea-wallpaper-rotate.sh --restart    pick up changed settings immediately
#         sea-wallpaper-rotate.sh --stop       stop rotating
#
# OFF by default. It only rotates while "wpRotate" is true in appearance.json, and it re-reads
# that file every tick — so toggling the switch in Settings takes effect without a restart, and
# there is no daemon to leave running when the feature is off.
#
# Why it matters that this is opt-in: with "match colours" on, every rotation runs matugen and
# re-themes the entire shell. A wallpaper that changes under you is a preference; an accent that
# changes under you every 30 minutes is a surprise.

PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/sea-wallpaper-rotate.pid"
here="$(dirname "$0")"

stop_existing() {
    [ -f "$PIDFILE" ] || return 0
    old="$(cat "$PIDFILE" 2>/dev/null)"
    # only kill it if it is really our rotator — never a recycled pid
    if [ -n "$old" ] && [ -d "/proc/$old" ] && \
       grep -qa 'sea-wallpaper-rotate' "/proc/$old/cmdline" 2>/dev/null; then
        kill "$old" 2>/dev/null
        # give the trap a moment, then insist — never leave a second rotator running, or two
        # daemons fight over the wallpaper on different intervals
        i=0
        while [ -d "/proc/$old" ] && [ "$i" -lt 20 ]; do
            sleep 0.1; i=$((i + 1))
        done
        [ -d "/proc/$old" ] && kill -9 "$old" 2>/dev/null
    fi
    rm -f "$PIDFILE"
}

case "$1" in
    --stop)    stop_existing; exit 0 ;;
    --restart) stop_existing ;;
esac

# single instance
if [ -f "$PIDFILE" ]; then
    old="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "$old" ] && [ -d "/proc/$old" ] && \
       grep -qa 'sea-wallpaper-rotate' "/proc/$old/cmdline" 2>/dev/null; then
        exit 0                                  # already supervising
    fi
fi
echo $$ > "$PIDFILE"
# Two traps, both load-bearing:
#  · INT/TERM must EXIT explicitly. A handler that only cleans up lets the shell carry on after
#    the signal is handled, so the daemon survives `kill` having already deleted the pidfile
#    that identifies it — --stop then reports success while nothing actually stopped.
#  · The pending sleep has to be killed too. See nap() below.
SLEEP_PID=""
trap 'rm -f "$PIDFILE"' EXIT
trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; rm -f "$PIDFILE"; exit 0' INT TERM

# Interruptible sleep. A bare `sleep` is a FOREGROUND child, and the shell defers trap delivery
# until it returns — so `kill` on a daemon napping 30 minutes did nothing for up to 30 minutes.
# Backgrounding it and waiting lets the trap fire the moment the signal lands.
nap() {
    sleep "$1" & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
}

# read settings fresh each tick so Settings changes apply without a restart
read_cfg() {
    python3 - <<'PY' 2>/dev/null
import json, os
try:
    j = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
except Exception:
    j = {}
on   = bool(j.get("wpRotate", False))
mins = j.get("wpRotateMins", 30)
mode = j.get("wpRotateMode", "next")
try:
    mins = float(mins)
except Exception:
    mins = 30.0
if mins < 1:
    mins = 1.0                                   # a sub-minute rotate is a strobe, not a feature
if mode not in ("next", "prev", "random"):
    mode = "next"
print("%d %d %s" % (1 if on else 0, int(mins * 60), mode))
PY
}

while :; do
    set -- $(read_cfg)
    on="${1:-0}"; secs="${2:-1800}"; mode="${3:-next}"

    if [ "$on" != "1" ]; then
        nap 30                                   # idle poll: cheap, and picks the toggle up
        continue
    fi

    nap "$secs"

    # re-check AFTER the sleep — the switch may have been turned off while we waited
    set -- $(read_cfg)
    [ "${1:-0}" = "1" ] || continue

    SEA_ROTATE_QUIET=1 sh "$here/sea-wallpaper-cycle.sh" "${3:-next}" >/dev/null 2>&1
done
