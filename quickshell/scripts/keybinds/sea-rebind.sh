#!/bin/sh
# sea-shell — rebind a key from the cheat-sheet UI.
# Usage: sea-rebind.sh <description> <old key> <new mods ("" for none)> <new key>
# Finds the bind whose description + old key match, swaps in the new combo, reloads
# Hyprland, and mirrors to the repo copy. Handles both keybinds.lua and keybinds.conf.
desc="$1"; oldkey="$2"; mods="$3"; key="$4"
[ -n "$desc" ] && [ -n "$key" ] || exit 1

dir="$HOME/.config/hypr/sea-shell"
# --dev installs have no copy in ~/.config/hypr — edit the repo files directly
[ -d "$dir" ] || dir="$(readlink -f "$HOME/.config/quickshell/sea-shell" 2>/dev/null)/../hypr"
lua="$dir/keybinds.lua"; conf="$dir/keybinds.conf"

# new combo as a Hyprland keys string: "SUPER + SHIFT + <key>" (or just "<key>")
if [ -n "$mods" ]; then newkeys="$(printf '%s' "$mods" | sed 's/  */ + /g') + $key"; else newkeys="$key"; fi

# ---- legacy hyprlang (.conf) ----
if [ -f "$conf" ]; then
    awk -v d="$desc" -v ok="$oldkey" -v m="$mods" -v k="$key" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
        line = $0
        if (line ~ /^bind[a-z]* *=/) {
            eq = index(line, "=")
            head = substr(line, 1, eq)
            rest = substr(line, eq + 1)
            n = split(rest, fld, ",")
            if (n >= 4 && trim(fld[3]) == d && tolower(trim(fld[2])) == tolower(ok)) {
                out = head " " m ", " k
                for (i = 3; i <= n; i++) out = out "," fld[i]
                print out; next
            }
        }
        print line
    }' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
fi

# ---- Lua (.lua): replace the first hl.bind() argument (the keys) on the matching line ----
if [ -f "$lua" ]; then
    python3 - "$lua" "$desc" "$oldkey" "$newkeys" <<'PY'
import sys
path, desc, oldkey, newkeys = sys.argv[1:5]
lines = open(path).read().split("\n")
needle = 'description = "%s"' % desc
done = False
for idx, ln in enumerate(lines):
    if done or "hl.bind(" not in ln or needle not in ln:
        continue
    i = ln.index("hl.bind(") + len("hl.bind(")
    depth, j, comma = 0, i, -1
    while j < len(ln):                    # first comma at paren-depth 0 ends arg1 (the keys)
        c = ln[j]
        if c in "([{": depth += 1
        elif c in ")]}": depth -= 1
        elif c == "," and depth == 0: comma = j; break
        j += 1
    if comma < 0: continue
    arg1 = ln[i:comma]
    if oldkey.lower() in arg1.lower():    # disambiguate duplicate descriptions by old key
        lines[idx] = ln[:i] + '"%s"' % newkeys + ln[comma:]
        done = True
open(path, "w").write("\n".join(lines))
PY
fi

# keep the repo copies in sync so the change survives a re-install / gets committed
repo="$(cat "$HOME/.config/sea-shell/.repo" 2>/dev/null)/hypr"
if [ -d "$repo" ]; then
    [ -f "$conf" ] && [ "$conf" != "$repo/keybinds.conf" ] && cp "$conf" "$repo/keybinds.conf"
    [ -f "$lua" ]  && [ "$lua"  != "$repo/keybinds.lua" ]  && cp "$lua"  "$repo/keybinds.lua"
fi

hyprctl reload >/dev/null 2>&1
