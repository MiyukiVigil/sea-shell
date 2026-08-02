#!/usr/bin/env bash
# sea-shell — add a new keybind.
# Usage: sea-add-bind.sh <mods ("" for none)> <key> <description> <action>
#   action is "exec, <cmd>" (the UI default) or "<dispatcher>, <params>".
# Writes to whichever of keybinds.lua / keybinds.conf exist, so the change lands
# regardless of whether Hyprland is on the Lua or the legacy hyprlang config.
mods="$1"; key="$2"; desc="$3"; action="$4"
[ -n "$key" ] && [ -n "$desc" ] && [ -n "$action" ] || exit 1

dir="$HOME/.config/hypr/sea-shell"
# --dev installs have no copy in ~/.config/hypr — edit the repo files directly
[ -d "$dir" ] || dir="$(readlink -f "$HOME/.config/quickshell/sea-shell" 2>/dev/null)/../hypr"
lua="$dir/keybinds.lua"; conf="$dir/keybinds.conf"

# ---- legacy hyprlang append ----
if [ -f "$conf" ]; then
    if [ -z "$mods" ]; then mod_str=","; else mod_str="$mods,"; fi
    printf '\nbindd = %s %s, %s, %s\n' "$mod_str" "$key" "$desc" "$action" >> "$conf"
fi

# ---- Lua append ----
if [ -f "$lua" ]; then
    # keys string: "SUPER + SHIFT + <key>"
    if [ -n "$mods" ]; then keys="$(printf '%s' "$mods" | sed 's/  */ + /g') + $key"; else keys="$key"; fi
    # split action into "<dispatcher>, <params>"
    disp="${action%%,*}"; disp="$(printf '%s' "$disp" | tr -d ' ')"
    params="${action#*,}"; params="${params# }"
    esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
    if [ "$disp" = "exec" ]; then
        dsp="hl.dsp.exec_cmd(\"$(esc "$params")\")"
    else
        # universal fallback: run ANY dispatcher via hyprctl (avoids per-dispatcher Lua mapping)
        dsp="hl.dsp.exec_cmd(\"hyprctl dispatch $(esc "$disp $params")\")"
    fi
    printf '\nhl.bind("%s", %s, { description = "%s" })\n' "$(esc "$keys")" "$dsp" "$(esc "$desc")" >> "$lua"
fi

# keep the repo copies in sync so the change survives a re-install / gets committed
repo="$(cat "$HOME/.config/sea-shell/.repo" 2>/dev/null)/hypr"
if [ -d "$repo" ]; then
    [ -f "$conf" ] && [ "$conf" != "$repo/keybinds.conf" ] && cp "$conf" "$repo/keybinds.conf"
    [ -f "$lua" ]  && [ "$lua"  != "$repo/keybinds.lua" ]  && cp "$lua"  "$repo/keybinds.lua"
fi

hyprctl reload >/dev/null 2>&1
