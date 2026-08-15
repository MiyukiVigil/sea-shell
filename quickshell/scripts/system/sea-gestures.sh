#!/bin/sh
# sea-shell — touchpad gestures: JSON in, Hyprland Lua out.
#
#   sea-gestures.sh          regenerate gestures.lua from gestures.json and apply it live
#
# Same split as the window rules: the settings panel owns ~/.config/sea-shell/gestures.json,
# this script owns the translation to ~/.config/hypr/sea-shell/gestures.lua, which sea.lua
# dofile's.
#
# The valid values below were not taken from documentation — they were probed against this
# machine's Hyprland 0.56 one at a time, with a `hyprctl reload` between each so a leftover
# registration could not masquerade as a rejection:
#
#   actions     workspace · move · resize · special · fullscreen · close · float
#               (rejected: "scroll", "dispatcher" — unknown action)
#   directions  horizontal · vertical · left · right · up · down · pinch · swipe
#               (rejected: "diagonal" — invalid direction)
#
# Registrations are keyed on fingers+direction: adding the same pair twice in one session is an
# error, which is why live-apply failures are ignored rather than reported — on a re-apply the
# pair usually already exists, and the file on disk is what matters at the next reload.

SRC="$HOME/.config/sea-shell/gestures.json"
OUT="$HOME/.config/hypr/sea-shell/gestures.lua"
mkdir -p "$(dirname "$OUT")"

[ -f "$SRC" ] || { printf -- '-- no user gestures\n' > "$OUT"; exit 0; }

python3 - "$SRC" "$OUT" <<'PY'
import json, sys, subprocess

src, out = sys.argv[1], sys.argv[2]
try:
    gs = json.load(open(src))
    if not isinstance(gs, list):
        gs = []
except Exception:
    gs = []

ACTIONS = {"workspace", "move", "resize", "special", "fullscreen", "close", "float"}
DIRS = {"horizontal", "vertical", "left", "right", "up", "down", "pinch", "swipe"}

lines = ["-- sea-shell: generated from gestures.json by sea-gestures.sh. Do not edit."]
applied, seen = [], set()

for g in gs:
    if not isinstance(g, dict):
        continue
    try:
        fingers = int(g.get("fingers", 3))
    except Exception:
        continue
    if fingers < 2 or fingers > 5:
        continue
    d = (g.get("direction") or "").strip()
    a = (g.get("action") or "").strip()
    if d not in DIRS or a not in ACTIONS:
        continue
    key = (fingers, d)
    if key in seen:
        continue                 # Hyprland rejects a duplicate fingers+direction pair outright
    seen.add(key)

    line = 'hl.gesture({ fingers = %d, direction = "%s", action = "%s" })' % (fingers, d, a)
    lines.append(line)
    applied.append(line)

open(out, "w").write("\n".join(lines) + "\n")

for line in applied:
    try:
        subprocess.run(["hyprctl", "eval", line], capture_output=True, timeout=5)
    except Exception:
        pass

print("%d gesture(s)" % len(applied))
PY
