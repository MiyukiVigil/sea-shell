#!/usr/bin/env bash
# sea-shell — add a new keybind.
# Usage: sea-add-bind.sh <mods ("" for none)> <key> <description> <action>
mods="$1"; key="$2"; desc="$3"; action="$4"
[ -n "$key" ] && [ -n "$desc" ] && [ -n "$action" ] || exit 1

f="$HOME/.config/hypr/sea-shell/keybinds.conf"
# --dev installs have no copy in ~/.config/hypr — edit the repo file directly
[ -f "$f" ] || f="$(readlink -f "$HOME/.config/quickshell/sea-shell" 2>/dev/null)/../hypr/keybinds.conf"
[ -f "$f" ] || exit 1

# Format mods: SUPER SHIFT -> SUPER SHIFT, (with a trailing comma)
# If no mods, just ","
if [ -z "$mods" ]; then
    mod_str=","
else
    mod_str="$mods,"
fi

# Append to keybinds.conf
printf '\nbindd = %s %s, %s, %s\n' "$mod_str" "$key" "$desc" "$action" >> "$f"

# keep the repo copy in sync so the change survives a re-install / gets committed
repo="$(cat "$HOME/.config/sea-shell/.repo" 2>/dev/null)/hypr/keybinds.conf"
[ -f "$repo" ] && [ "$repo" != "$f" ] && cp "$f" "$repo"

# reload
hyprctl reload >/dev/null 2>&1
