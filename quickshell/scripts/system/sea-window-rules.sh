#!/bin/sh
# sea-shell — user window rules: JSON in, Hyprland Lua out.
#
#   sea-window-rules.sh          regenerate rules.lua from window-rules.json and apply it live
#
# The settings panel owns ~/.config/sea-shell/window-rules.json (the data). This script owns the
# translation to ~/.config/hypr/sea-shell/rules.lua (the Lua), which sea.lua dofile's AFTER its
# own built-in rules so a user rule always wins over a shipped default.
#
# Verified against Hyprland 0.56 before this was written: hl.window_rule() with float/size/center
# genuinely applies to a newly mapped window (floating=true, size=[420,300], centred). That check
# matters — hl.workspace_rule() accepts a `layout` field, returns ok, and does nothing at all, so
# "the call succeeded" is not evidence a rule works in this API.
#
# Rules apply at MAP time. Changing a rule therefore affects windows opened from now on; existing
# windows keep whatever they were given when they opened. That is Hyprland's behaviour, not a
# limitation of this script, and the panel says so rather than pretending otherwise.

SRC="$HOME/.config/sea-shell/window-rules.json"
OUT="$HOME/.config/hypr/sea-shell/rules.lua"
mkdir -p "$(dirname "$OUT")"

[ -f "$SRC" ] || { printf -- '-- no user window rules\n' > "$OUT"; exit 0; }

python3 - "$SRC" "$OUT" <<'PY'
import json, sys, subprocess

src, out = sys.argv[1], sys.argv[2]
try:
    rules = json.load(open(src))
    if not isinstance(rules, list):
        rules = []
except Exception:
    rules = []

def lua_str(s):
    # Lua long-bracket would break on ]] inside a regex, so escape for a normal quoted string.
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'

lines = ["-- sea-shell: generated from window-rules.json by sea-window-rules.sh. Do not edit."]
applied = []

for r in rules:
    if not isinstance(r, dict):
        continue
    cls = (r.get("class") or "").strip()
    ttl = (r.get("title") or "").strip()
    if not cls and not ttl:
        continue                       # a rule matching everything is never what someone meant

    match = []
    if cls: match.append("class = " + lua_str(cls))
    if ttl: match.append("title = " + lua_str(ttl))
    parts = ["match = { " + ", ".join(match) + " }"]

    if r.get("float"):    parts.append("float = true")
    if r.get("tile"):     parts.append("tile = true")
    if r.get("center"):   parts.append("center = true")
    if r.get("pin"):      parts.append("pin = true")
    if r.get("noblur"):   parts.append("no_blur = true")
    if r.get("noshadow"): parts.append("no_shadow = true")
    if r.get("fullscreen"): parts.append("fullscreen = true")

    try:
        op = float(r.get("opacity", 1) or 1)
        if 0 < op < 1:
            parts.append("opacity = %.2f" % op)
    except Exception:
        pass

    ws = (r.get("workspace") or "").strip()
    if ws:
        parts.append("workspace = " + lua_str(ws))

    size = (r.get("size") or "").strip()
    if size:
        # "800x600" / "800 600" / "800,600" all mean the same thing to a human
        nums = [p for p in size.replace("x", " ").replace(",", " ").split() if p.strip().isdigit()]
        if len(nums) == 2:
            parts.append("size = { %s, %s }" % (nums[0], nums[1]))

    if len(parts) == 1:
        continue                       # a match with no actions does nothing

    line = "hl.window_rule({ " + ", ".join(parts) + " })"
    lines.append(line)
    applied.append(line)

open(out, "w").write("\n".join(lines) + "\n")

# Live-apply so a rule takes effect for the next window without a reload. `hyprctl keyword` is
# inert under a Lua config, so this goes through eval with the exact same Lua just written.
for line in applied:
    try:
        subprocess.run(["hyprctl", "eval", line], capture_output=True, timeout=5)
    except Exception:
        pass

print("%d rule(s)" % len(applied))
PY
