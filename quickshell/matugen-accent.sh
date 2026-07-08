#!/bin/sh
# sea-shell — derive the bar accent from a wallpaper via matugen and write it into
# ~/.config/sea-shell/appearance.json (preserving the other fields). Video/gif → first frame.
wp="$1"
[ -z "$wp" ] && wp=$(cat "$HOME/.config/sea-shell/wallpaper" 2>/dev/null)
[ -z "$wp" ] && exit 1

case "$wp" in
    *.mp4|*.webm|*.mkv|*.mov|*.gif)
        f=/tmp/sea-matugen-frame.png
        ffmpeg -y -i "$wp" -vframes 1 "$f" >/dev/null 2>&1 && wp="$f" ;;
esac

col=$(matugen --json hex --prefer saturation image "$wp" 2>/dev/null | python3 -c \
    "import sys,json;d=json.load(sys.stdin);c=d['colors']['primary'];print((c.get('dark') or c.get('default') or c.get('light'))['color'])" 2>/dev/null)
[ -z "$col" ] && exit 1

cfg="$HOME/.config/sea-shell/appearance.json"
python3 - "$cfg" "$col" <<'PY'
import json, sys
cfg, col = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(cfg))
except Exception:
    d = {"radius": 14, "opacity": 0.82, "height": 42, "font": "monospace"}
d["accent"] = col
json.dump(d, open(cfg, "w"))
PY
notify-send 'sea-shell' "Accent from wallpaper → $col" 2>/dev/null
