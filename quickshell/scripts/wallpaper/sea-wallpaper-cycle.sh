#!/bin/sh
# sea-shell — move to the next / previous / a random wallpaper.
#
# Usage: sea-wallpaper-cycle.sh [next|prev|random] [--stills]
#
# The list comes from sea-wallpaper-index.py --paths, which is the ONE definition of
# which folder the wallpapers are in and what counts as one. This script used to carry
# its own `find ~/Pictures/wallpapers -maxdepth 1`, so the folder was unconfigurable
# and a folder with any organisation in it cycled through only its top level.
#
# PREV IS BACK, NOT MINUS ONE.  It used to find the current wallpaper's position in the
# name-sorted list and step back one — so after a random jump, "previous" went to
# whatever happened to sort before the wallpaper you had landed on, which is not where
# you came from and had never been on screen. It now pops the back stack that
# sea-wallpaper-set.sh maintains, exactly like a browser, and only falls back to
# name-order when there is nothing to go back to.
#
# RANDOM IS A BAG, NOT A DIE.  A fresh `shuf` every time repeats: over eleven
# wallpapers you see the same one twice long before you have seen them all, and
# nothing stops it picking the one already on screen. The bag is a shuffled deck that
# deals without replacement and reshuffles when it runs out.

here="$(dirname "$0")"
CFG="$HOME/.config/sea-shell"
STATE="$HOME/.cache/sea-shell"
HIST="$STATE/wallhistory"
BAG="$STATE/wallbag"

mode="next"
stills=""
for a in "$@"; do
    case "$a" in
        next|prev|previous|random) mode="$a" ;;
        --stills) stills="--stills" ;;
    esac
done
[ "$mode" = "previous" ] && mode="prev"

mkdir -p "$STATE"

list="$(python3 "$here/sea-wallpaper-index.py" --paths $stills 2>/dev/null)"
[ -z "$list" ] && {
    notify-send 'sea-shell' 'No wallpapers found — check the folder in Settings → Wallpaper' 2>/dev/null
    exit 0
}
n=$(printf '%s\n' "$list" | wc -l)
cur="$(cat "$CFG/wallpaper" 2>/dev/null)"

# ---- back ---------------------------------------------------------------------------
if [ "$mode" = "prev" ] && [ -s "$HIST" ]; then
    back="$(head -n 1 "$HIST")"
    if [ -n "$back" ] && [ -f "$back" ]; then
        tail -n +2 "$HIST" > "$HIST.tmp" 2>/dev/null && mv "$HIST.tmp" "$HIST"
        # --no-history, or going back would push the wallpaper we are leaving onto the
        # stack we are popping, and prev/prev would oscillate between two wallpapers
        # instead of walking backwards through the session.
        exec sh "$here/sea-wallpaper-set.sh" "$back" --no-history ${SEA_ROTATE_QUIET:+--quiet}
    fi
    : > "$HIST"                     # a stack of paths that no longer exist is not a stack
fi

# ---- position in the folder ---------------------------------------------------------
idx=$(printf '%s\n' "$list" | grep -nxF "$cur" 2>/dev/null | head -1 | cut -d: -f1)
[ -z "$idx" ] && idx=0

case "$mode" in
    prev)   new=$(( idx <= 1 ? n : idx - 1 ));;
    random)
        # Refill the bag whenever it is empty OR no longer describes this folder — the
        # wallpaper set can change under it (a new file, a different wpDir, --stills),
        # and dealing a path that is not there any more would be a silent no-op.
        if [ ! -s "$BAG" ]; then
            printf '%s\n' "$list" | shuf > "$BAG" 2>/dev/null || printf '%s\n' "$list" > "$BAG"
        fi
        wp=""
        while [ -s "$BAG" ]; do
            cand="$(head -n 1 "$BAG")"
            tail -n +2 "$BAG" > "$BAG.tmp" 2>/dev/null && mv "$BAG.tmp" "$BAG"
            # Skip the one already up: the last card of one bag and the first of the
            # next are independent draws, and landing on the same wallpaper twice in a
            # row is the one outcome a shuffle is supposed to rule out.
            if [ -f "$cand" ] && [ "$cand" != "$cur" ] && printf '%s\n' "$list" | grep -qxF "$cand"; then
                wp="$cand"; break
            fi
        done
        [ -z "$wp" ] && new=$(( idx >= n ? 1 : idx + 1 ))
        ;;
    *)      new=$(( idx >= n ? 1 : idx + 1 ));;
esac

[ -z "$wp" ] && wp=$(printf '%s\n' "$list" | sed -n "${new}p")
[ -z "$wp" ] && exit 0

# the auto-rotate daemon sets SEA_ROTATE_QUIET: a toast every 30 minutes, unprompted, is spam
exec sh "$here/sea-wallpaper-set.sh" "$wp" ${SEA_ROTATE_QUIET:+--quiet}
