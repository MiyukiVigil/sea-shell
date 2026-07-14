#!/bin/sh
# sea-shell — rebind a key from the cheat-sheet UI.
# Usage: sea-rebind.sh <description> <old key> <new mods ("" for none)> <new key>
# Finds the bindd line whose description + key match, swaps in the new combo,
# reloads Hyprland, and mirrors the change to the repo copy when known.
desc="$1"; oldkey="$2"; mods="$3"; key="$4"
[ -n "$desc" ] && [ -n "$key" ] || exit 1

f="$HOME/.config/hypr/sea-shell/keybinds.conf"
# --dev installs have no copy in ~/.config/hypr — edit the repo file directly
[ -f "$f" ] || f="$(readlink -f "$HOME/.config/quickshell/sea-shell" 2>/dev/null)/../hypr/keybinds.conf"
[ -f "$f" ] || exit 1

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
}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"

# keep the repo copy in sync so the change survives a re-install / gets committed
repo="$(cat "$HOME/.config/sea-shell/.repo" 2>/dev/null)/hypr/keybinds.conf"
[ -f "$repo" ] && [ "$repo" != "$f" ] && cp "$f" "$repo"

hyprctl reload >/dev/null 2>&1
