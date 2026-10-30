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
    # Legacy dispatchers are mapped onto the Lua API — the old `hyprctl dispatch <disp> <params>`
    # fallback stopped working on Lua configs, where hyprctl evaluates its argument as Lua
    # (`hl.dispatch(workspace 3)` → parse error), so every non-exec bind added here was dead.
    # A raw `hl.dsp.…(…)` expression typed as the action is passed through untouched.
    p="$(esc "$params")"
    case "$action" in hl.dsp.*) disp="lua" ;; esac
    case "$disp" in
        lua)            dsp="$action" ;;
        exec)           dsp="hl.dsp.exec_cmd(\"$p\")" ;;
        killactive)     dsp="hl.dsp.window.close()" ;;
        togglefloating) dsp="hl.dsp.window.float({ action = \"toggle\" })" ;;
        fullscreen)     dsp="hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"toggle\" })" ;;
        centerwindow)   dsp="hl.dsp.window.center()" ;;
        workspace)      dsp="hl.dsp.focus({ workspace = \"$p\" })" ;;
        movetoworkspace) dsp="hl.dsp.window.move({ workspace = \"$p\" })" ;;
        movefocus)      dsp="hl.dsp.focus({ direction = \"$p\" })" ;;
        movewindow)     dsp="hl.dsp.window.move({ direction = \"$p\" })" ;;
        togglespecialworkspace) dsp="hl.dsp.workspace.toggle_special(\"${p:-special}\")" ;;
        exit)           dsp="hl.dsp.exit()" ;;
        *)
            echo "sea-add-bind: no Lua mapping for dispatcher '$disp' — use 'exec, <cmd>' or an hl.dsp.… expression" >&2
            exit 2 ;;
    esac
    printf '\nhl.bind("%s", %s, { description = "%s" })\n' "$(esc "$keys")" "$dsp" "$(esc "$desc")" >> "$lua"
fi

# keep the repo copies in sync so the change survives a re-install / gets committed
repo="$(cat "$HOME/.config/sea-shell/.repo" 2>/dev/null)/hypr"
if [ -d "$repo" ]; then
    [ -f "$conf" ] && [ "$conf" != "$repo/keybinds.conf" ] && cp "$conf" "$repo/keybinds.conf"
    [ -f "$lua" ]  && [ "$lua"  != "$repo/keybinds.lua" ]  && cp "$lua"  "$repo/keybinds.lua"
fi

hyprctl reload >/dev/null 2>&1
