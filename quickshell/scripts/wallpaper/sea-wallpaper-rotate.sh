#!/bin/sh
# sea-shell — auto-rotate the wallpaper on a timer, and hold the day/night pair.
#
# Usage:  sea-wallpaper-rotate.sh              supervise (started from hyprland.lua)
#         sea-wallpaper-rotate.sh --restart    pick up changed settings immediately
#         sea-wallpaper-rotate.sh --stop       stop rotating
#
# OFF by default. It only rotates while "wpRotate" is true in appearance.json, and it
# re-reads that file every tick — so toggling the switch in Settings takes effect without
# a restart, and there is no daemon to leave running when the feature is off.
#
# Why it matters that this is opt-in: with "match colours" on, every rotation runs matugen
# and re-themes the entire shell. A wallpaper that changes under you is a preference; an
# accent that changes under you every 30 minutes is a surprise.
#
# THE DAY/NIGHT PAIR rides in the same daemon rather than in a timer of its own. It also
# borrows the theme schedule's OWN darkStart/darkEnd rather than inventing a second pair
# of times, because "the desktop goes dark at 19:00" should mean one thing. Two clocks
# that are supposed to agree are two clocks that will not.
#
# It also OUTRANKS rotation: a pinned pair and a shuffle every 30 minutes are directly
# contradictory instructions, and quietly letting the rotate timer overwrite the night
# wallpaper would read as the pair not working.

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
import json, os, datetime
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
stills = 1 if j.get("wpRotateStills", False) else 0

# The day/night pair, resolved to the ONE wallpaper that should be up right now — the
# daemon never has to know what time it is, only whether what is on screen is right.
def mm(t, dv):
    try:
        h, m = str(t).split(":")
        return (int(h) % 24) * 60 + (int(m) % 60)
    except Exception:
        return dv
pair = ""
if j.get("wpDayNight"):
    day = os.path.expanduser(str(j.get("wpDay") or ""))
    night = os.path.expanduser(str(j.get("wpNight") or ""))
    if day and night and os.path.isfile(day) and os.path.isfile(night):
        start, end = mm(j.get("darkStart", "19:00"), 19 * 60), mm(j.get("darkEnd", "07:00"), 7 * 60)
        now = datetime.datetime.now()
        cur = now.hour * 60 + now.minute
        dark = (start <= cur < end) if start <= end else (cur >= start or cur < end)
        pair = night if dark else day
# A tab would split the line; a wallpaper path containing one is already refused upstream.
print("%d\t%d\t%s\t%d\t%s" % (1 if on else 0, int(mins * 60), mode, stills, pair))
PY
}

cfg_field() { printf '%s' "$1" | cut -d "$(printf '\t')" -f "$2"; }

# The pinned pair, checked every tick. Setting it only when it differs is what keeps this
# from re-applying the same wallpaper — and re-running matugen — once a minute.
hold_pair() {
    [ -n "$1" ] || return 1
    [ "$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null)" = "$1" ] && return 0
    SEA_ROTATE_QUIET=1 sh "$here/sea-wallpaper-set.sh" "$1" --quiet >/dev/null 2>&1
    return 0
}

while :; do
    cfg="$(read_cfg)"
    on="$(cfg_field "$cfg" 1)";     secs="$(cfg_field "$cfg" 2)"
    mode="$(cfg_field "$cfg" 3)";   stills="$(cfg_field "$cfg" 4)"
    pair="$(cfg_field "$cfg" 5)"
    [ -z "$on" ] && on=0
    [ -z "$secs" ] && secs=1800

    if [ -n "$pair" ]; then
        hold_pair "$pair"
        nap 60                                   # a boundary is worth a minute's resolution
        continue
    fi

    if [ "$on" != "1" ]; then
        nap 30                                   # idle poll: cheap, and picks the toggle up
        continue
    fi

    nap "$secs"

    # re-check AFTER the sleep — the switch may have been turned off, or the pair pinned,
    # while we waited
    cfg="$(read_cfg)"
    [ "$(cfg_field "$cfg" 1)" = "1" ] || continue
    [ -n "$(cfg_field "$cfg" 5)" ] && continue
    mode="$(cfg_field "$cfg" 3)"; stills="$(cfg_field "$cfg" 4)"

    if [ "$stills" = "1" ]; then
        SEA_ROTATE_QUIET=1 sh "$here/sea-wallpaper-cycle.sh" "$mode" --stills >/dev/null 2>&1
    else
        SEA_ROTATE_QUIET=1 sh "$here/sea-wallpaper-cycle.sh" "$mode" >/dev/null 2>&1
    fi
done
