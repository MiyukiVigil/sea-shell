#!/bin/sh
# sea-shell — "sea-shell Gaming" login session: Hyprland with hypr/gaming.lua (big picture only).
# Falls back to the normal session when gaming.lua is missing so a login never dead-ends.
log="${XDG_RUNTIME_DIR:-/tmp}/sea-gaming-session.log"
exec >>"$log" 2>&1
echo "== $(date '+%F %T') sea-gaming-session start"
export SEA_SESSION=gaming
cfg="$HOME/.config/hypr/sea-shell/gaming.lua"
[ -f "$cfg" ] || { echo "missing $cfg; starting the normal session"; unset SEA_SESSION; }
if command -v start-hyprland >/dev/null 2>&1; then
    [ -n "$SEA_SESSION" ] && exec start-hyprland -- -c "$cfg"
    exec start-hyprland
fi
[ -n "$SEA_SESSION" ] && exec Hyprland -c "$cfg"
exec Hyprland
