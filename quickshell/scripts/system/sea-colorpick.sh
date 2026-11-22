#!/bin/sh
# Pick a colour anywhere on screen. The hex goes to the clipboard, and the notification
# shows a swatch of it so you can see what was picked.
if ! command -v hyprpicker >/dev/null 2>&1; then
    notify-send -a sea-shell -i color-select "Colour picker" \
        "hyprpicker is not installed. Install it with: sudo pacman -S hyprpicker"
    exit 1
fi

hex=$(hyprpicker -n -f hex 2>/dev/null | tr -d '[:space:]')
case "$hex" in
    \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*) ;;
    *) exit 0 ;;                       # Escape or a click off-screen
esac

printf '%s' "$hex" | wl-copy

# Record into Color Studio history (~/.config/sea-shell/color-history.json)
python3 - "$hex" <<'PY' 2>/dev/null || true
import json, os, pathlib, sys, time
hx = sys.argv[1].upper()
p = pathlib.Path.home() / ".config/sea-shell/color-history.json"
p.parent.mkdir(parents=True, exist_ok=True)
try:
    arr = json.loads(p.read_text())
    if not isinstance(arr, list):
        arr = []
except Exception:
    arr = []
arr = [x for x in arr if isinstance(x, dict) and str(x.get("hex", "")).upper() != hx]
arr.insert(0, {"hex": hx, "ts": int(time.time())})
tmp = p.with_suffix(".json.tmp")
tmp.write_text(json.dumps(arr[:48], indent=2))
os.replace(tmp, p)
PY

swatch="${XDG_RUNTIME_DIR:-/tmp}/sea-colour.png"
icon=color-select
if command -v magick >/dev/null 2>&1 && magick -size 64x64 "xc:$hex" "$swatch" 2>/dev/null; then
    icon=$swatch
fi
notify-send -a sea-shell -i "$icon" "Copied $hex" "Paste it anywhere."
