#!/bin/sh
# sea-shell — SET a wallpaper. Everything that means, in one place.
#
# Usage: sea-wallpaper-set.sh /path/to/wallpaper [--no-history] [--quiet]
#
# Applying a wallpaper is five things, not one: remember what we are leaving, record the
# new one, put it on the screen, sync the lock background, and re-derive the palette if
# "match colours" is on. That five-step sequence was written out THREE times — in the
# cycle keybinds, in the picker's apply(), and nowhere at all for anything else that
# wanted to set a wallpaper, which is why nothing else could.
#
# So it lives here, and the picker, the keybinds, the rotate daemon and the `wallpaper
# set` IPC verb all call it. sea-wallpaper-apply.sh is still the one place that talks to
# the DAEMONS; this is the one place that decides what a wallpaper change consists of.
#
# --no-history is how "back" avoids pushing the thing it just came from, which would
# make the back stack a loop between two wallpapers. Nothing else should pass it.

here="$(dirname "$0")"
CFG="$HOME/.config/sea-shell"
STATE="$HOME/.cache/sea-shell"
HIST="$STATE/wallhistory"

# The back stack. Deep enough to walk out of an afternoon of pressing SUPER+N, shallow
# enough to stay a file you could read.
HIST_MAX=60

wp=""
history=1
quiet=0
match=""                 # "" = whatever appearance.json says
for a in "$@"; do
    case "$a" in
        --no-history) history=0 ;;
        --quiet)      quiet=1 ;;
        # The picker's "match colours" chip is a per-pick decision that is deliberately
        # not written to appearance.json, so it has to travel with the request — reading
        # the file here would re-theme the shell against a chip the user had just turned
        # off for this one wallpaper.
        --match)      match=1 ;;
        --no-match)   match=0 ;;
        -*)           ;;
        *)            [ -z "$wp" ] && wp="$a" ;;
    esac
done

[ -n "$wp" ] || { echo "sea-wallpaper-set: no wallpaper given" >&2; exit 1; }
[ -f "$wp" ] || { echo "sea-wallpaper-set: not a file: $wp" >&2; exit 1; }
# Relative paths would be resolved against whatever happened to be the caller's working
# directory, and the stored path is read back by four other processes.
case "$wp" in
    /*) ;;
    *)  wp="$(cd "$(dirname "$wp")" 2>/dev/null && pwd)/$(basename "$wp")" ;;
esac

mkdir -p "$CFG" "$STATE"

# ---- 1. remember what we are leaving ----------------------------------------------
# Pushed BEFORE the config file is overwritten, which is the whole reason this step
# cannot live in sea-wallpaper-apply.sh: by the time apply runs, the wallpaper it is
# replacing has already been forgotten.
prev="$(cat "$CFG/wallpaper" 2>/dev/null)"
if [ "$history" = "1" ] && [ -n "$prev" ] && [ "$prev" != "$wp" ]; then
    { printf '%s\n' "$prev"; [ -f "$HIST" ] && cat "$HIST"; } 2>/dev/null \
        | head -n "$HIST_MAX" > "$HIST.tmp" 2>/dev/null && mv "$HIST.tmp" "$HIST"
fi

# ---- 2. record it -----------------------------------------------------------------
printf '%s' "$wp" > "$CFG/wallpaper"

# ---- 3..5. screen, lock screen, palette -------------------------------------------
# install.sh flattens the whole quickshell/ tree into one directory, so at runtime every
# helper is a plain sibling. In the REPO they are filed under wallpaper/, lock/ and
# theme/, and this has to run from either — the rotate daemon and the picker are both
# tested straight out of the checkout.
sibling() {
    for c in "$here/$1" "$here/../lock/$1" "$here/../theme/$1"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

sh "$here/sea-wallpaper-apply.sh" "$wp" >/dev/null 2>&1 &

lock="$(sibling sea-lockwall.sh)" && sh "$lock" "$wp" >/dev/null 2>&1 &

if [ -z "$match" ]; then
    python3 -c "import json,os,sys;sys.exit(0 if json.load(open(os.path.expanduser('~/.config/sea-shell/appearance.json'))).get('matugen') else 1)" 2>/dev/null && match=1 || match=0
fi
if [ "$match" = "1" ]; then
    mat="$(sibling matugen-accent.sh)" && sh "$mat" "$wp" >/dev/null 2>&1 &
fi

# Unconditional, and deliberately NOT inside the matugen branch above: light/dark following the
# picture is its own setting, and gating it on "match colours" made it a feature that silently
# did nothing for anyone who wanted one without the other. The script itself no-ops unless
# modeSource is "wallpaper", so this costs a python startup when it is not in use.
mode="$(sibling sea-theme-from-wallpaper.sh)" && sh "$mode" "$wp" >/dev/null 2>&1 &

[ "$quiet" = "1" ] || notify-send 'sea-shell' "Wallpaper → $(basename "$wp")" 2>/dev/null
exit 0
