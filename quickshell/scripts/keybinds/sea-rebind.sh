#!/bin/sh
# sea-shell — rebind a key from the cheat-sheet UI.
# Usage: sea-rebind.sh <description> <old key> <new mods ("" for none)> <new key> [command]
#
# The optional 5th argument retargets an `exec` bind at a different command. Only the
# COMMAND is editable, not the whole dispatcher expression: a bind that closes a window or
# switches a workspace is a lua call whose shape the UI cannot safely rewrite from a text
# box, whereas "SUPER+C should open something else" is the thing people actually want and
# is a single string. Non-exec binds are shown read-only in the editor for that reason.
# Finds the bind whose description + old key match, swaps in the new combo, reloads
# Hyprland, and mirrors to the repo copy. Handles both keybinds.lua and keybinds.conf.
desc="$1"; oldkey="$2"; mods="$3"; key="$4"; newcmd="$5"
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
    python3 - "$lua" "$desc" "$oldkey" "$newkeys" "$newcmd" <<'PY'
import sys
path, desc, oldkey, newkeys = sys.argv[1:5]
newcmd = sys.argv[5] if len(sys.argv) > 5 else ""
lines = open(path).read().split("\n")
needle = 'description = "%s"' % desc


def commas(ln, start):
    """Offsets of the top-level commas after `start` — the argument boundaries."""
    out, depth, j, instr = [], 0, start, ""
    while j < len(ln):
        c = ln[j]
        if instr:
            if c == "\\":
                j += 2
                continue
            if c == instr:
                instr = ""
        elif c in "\"'":
            instr = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            out.append(j)
        j += 1
    return out


done = False
for idx, ln in enumerate(lines):
    if done or "hl.bind(" not in ln or needle not in ln:
        continue
    i = ln.index("hl.bind(") + len("hl.bind(")
    cs = commas(ln, i)
    if not cs:
        continue
    arg1 = ln[i:cs[0]]
    if oldkey.lower() not in arg1.lower():   # disambiguate duplicate descriptions by old key
        continue
    out = ln[:i] + '"%s"' % newkeys + ln[cs[0]:]
    if newcmd:
        # arg2 spans the first top-level comma to the second; rebuild the offsets against
        # the line we just rewrote, because replacing arg1 moved everything after it.
        cs2 = commas(out, i)
        if len(cs2) >= 2:
            esc = newcmd.replace("\\", "\\\\").replace('"', '\\"')
            out = out[:cs2[0]] + ', hl.dsp.exec_cmd("%s")' % esc + out[cs2[1]:]
    lines[idx] = out
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
