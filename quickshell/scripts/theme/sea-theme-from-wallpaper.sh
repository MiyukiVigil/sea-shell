#!/bin/sh
# sea-shell — set light/dark from the wallpaper's own brightness (appearance.json
# `modeSource` = "wallpaper").  No-op for every other mode source.
#
#   sea-theme-from-wallpaper.sh [wallpaper]     # omitted → the wallpaper currently set
#
# WHY THIS IS ITS OWN SCRIPT.  It lived inside matugen-accent.sh, which reads as the right
# place — both look at the wallpaper and both write appearance.json. It is not. That script
# only runs when "match colours" is ON, and worse, it only resolves $wp inside that same
# `if`. So a user who wanted their theme to follow the wallpaper but did NOT want their
# accent recoloured got a feature that silently did nothing: the script was never called,
# and would have had no wallpaper to look at even if it had been. Two independent features
# were sharing one switch. This one now runs on every wallpaper change, whatever matugen is
# doing, and is called directly when you pick "the wallpaper" in Settings so the decision
# lands immediately rather than at the next wallpaper.

cfg="$HOME/.config/sea-shell/appearance.json"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

src=$(python3 -c "import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(d.get('modeSource') or ('clock' if d.get('autoDark') else 'manual'))" "$cfg" 2>/dev/null)
[ "$src" = "wallpaper" ] || exit 0

command -v magick >/dev/null 2>&1 || exit 0

wp=$(printf '%s' "$1" | tr -d '\n\r')
[ -z "$wp" ] && wp=$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null | tr -d '\n\r')
[ -z "$wp" ] && exit 0
[ -f "$wp" ] || exit 0

# A clip has to be reduced to one frame first — and the indexer has already cut and cached
# that frame, so this costs a lookup rather than a decode. Frame ZERO is deliberately not
# used: a great many wallpaper clips open on black, and black is not what the wallpaper
# looks like. The poster seeks a second in for that reason.
case "$wp" in
    *.mp4|*.webm|*.mkv|*.mov|*.gif)
        ix=""
        for c in "$here/sea-wallpaper-index.py" "$here/../wallpaper/sea-wallpaper-index.py"; do
            [ -f "$c" ] && { ix="$c"; break; }
        done
        poster=""
        [ -n "$ix" ] && poster=$(python3 "$ix" --poster "$wp" 2>/dev/null)
        if [ -n "$poster" ] && [ -f "$poster" ]; then
            wp="$poster"
        else
            f=/tmp/sea-mode-frame.png
            ffmpeg -y -ss 1 -i "$wp" -vframes 1 "$f" >/dev/null 2>&1 \
                || ffmpeg -y -i "$wp" -vframes 1 "$f" >/dev/null 2>&1
            [ -f "$f" ] && wp="$f" || exit 0
        fi ;;
esac

lum=$(magick "$wp" -colorspace gray -resize 1x1! -format "%[fx:mean]" info: 2>/dev/null)
case "$lum" in
    ''|*[!0-9.]*) exit 0 ;;                 # unreadable — leave the mode exactly where it is
esac

# WHY A DEAD ZONE AND NOT A THRESHOLD.  Measured across a real eleven-wallpaper library, the
# mean luminances were .28 .31 .41 .45 .45 .49 .51 .51 .52 .74 .94 — six of the eleven sit
# inside a tenth of 0.5. A plain midpoint would call .488 dark and .512 light, which is a coin
# toss between two pictures nobody would describe differently, and auto-rotate through that
# folder would flip the whole desktop every half hour on noise. So: commit only when the
# picture is not ambiguous, and otherwise leave the mode alone. Most wallpapers change
# nothing, which is the point — the ones that do are the ones you would have switched by hand.
python3 - "$cfg" "$lum" <<'PY'
import json, os, sys
cfg = sys.argv[1]
try: lum = float(sys.argv[2])
except ValueError: raise SystemExit(0)
try: d = json.load(open(cfg))
except Exception: raise SystemExit(0)
cur = d.get("mode", "dark")
if   lum < 0.42: want = "dark"
elif lum > 0.60: want = "light"
else:            want = cur          # not bright enough or dark enough to say
if want != cur:
    d["mode"] = want
    t = cfg + ".tmp"
    with open(t, "w") as fh: json.dump(d, fh)
    os.replace(t, cfg)               # atomic: the bar watches this and pushes the mode to GTK + kitty
PY
