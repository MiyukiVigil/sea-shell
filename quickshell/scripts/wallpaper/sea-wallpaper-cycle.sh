#!/bin/sh
# sea-shell — cycle to the next / previous / random wallpaper in ~/Pictures/wallpapers,
# applying it exactly like the picker does: swww/mpvpaper + lock-screen bg + matugen
# recolour (only when "auto colours" is on). Usage: sea-wallpaper-cycle.sh [next|prev|random]
dir="$HOME/Pictures/wallpapers"
here=$(dirname "$0")
cfgwp="$HOME/.config/sea-shell/wallpaper"
mode="${1:-next}"

list=$(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
        -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.mp4' -o -iname '*.webm' \) 2>/dev/null | sort)
[ -z "$list" ] && { notify-send 'sea-shell' 'No wallpapers in ~/Pictures/wallpapers' 2>/dev/null; exit 0; }
n=$(printf '%s\n' "$list" | wc -l)

cur=$(cat "$cfgwp" 2>/dev/null)
idx=$(printf '%s\n' "$list" | grep -nxF "$cur" 2>/dev/null | head -1 | cut -d: -f1)
[ -z "$idx" ] && idx=0

case "$mode" in
    prev)   new=$(( idx <= 1 ? n : idx - 1 ));;
    random) new=$(shuf -i 1-"$n" -n 1 2>/dev/null || echo $(( idx >= n ? 1 : idx + 1 )) );;
    *)      new=$(( idx >= n ? 1 : idx + 1 ));;
esac

wp=$(printf '%s\n' "$list" | sed -n "${new}p")
[ -z "$wp" ] && exit 0
printf '%s' "$wp" > "$cfgwp"

# apply through the shared path, sync the lock-screen bg, and recolour if matugen is on
sh "$here/sea-wallpaper-apply.sh" "$wp" >/dev/null 2>&1 &
[ -f "$here/sea-lockwall.sh" ] && sh "$here/sea-lockwall.sh" "$wp" >/dev/null 2>&1 &
if python3 -c "import json,sys;sys.exit(0 if json.load(open('$HOME/.config/sea-shell/appearance.json')).get('matugen') else 1)" 2>/dev/null; then
    sh "$here/matugen-accent.sh" "$wp" >/dev/null 2>&1 &
fi
# the auto-rotate daemon sets SEA_ROTATE_QUIET: a toast every 30 minutes, unprompted, is spam
[ -n "$SEA_ROTATE_QUIET" ] || notify-send 'sea-shell' "Wallpaper → $(basename "$wp")" 2>/dev/null
