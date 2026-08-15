#!/bin/sh
# sea-shell — health check.
#
#   sea-doctor.sh          one record per line: status|category|item|detail
#
# status is ok | warn | crit, so the panel can colour rows without re-deciding severity.
#
# This exists because of a specific failure shape: the bar dies, the supervisor silently
# respawns it five times, gives up, and you are left with no bar and no idea why — the evidence
# is in a log in XDG_RUNTIME_DIR that nothing ever surfaces. Six months from now, on a machine
# you are not actively developing, that log is the difference between a fix and a reinstall.
#
# Everything here is READ-ONLY. A diagnostic that changes state to fix things is a diagnostic
# you cannot trust to tell you what was wrong.

STATE="${XDG_RUNTIME_DIR:-/tmp}"
CFG="$HOME/.config/sea-shell"
QSD="$HOME/.config/quickshell/sea-shell"
HYD="$HOME/.config/hypr/sea-shell"

row() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- required ----
for d in hyprctl qs kitty python3; do
    if have "$d"; then row ok required "$d" "on PATH"
    else row crit required "$d" "MISSING — core features will not work"; fi
done

# ---- optional, grouped by what breaks without them ----
opt_check() {
    if have "$1"; then row ok optional "$1" "$2"
    else row warn optional "$1" "missing — $2 unavailable"; fi
}
opt_check grim          "screenshots"
opt_check slurp         "region select"
opt_check wl-copy       "clipboard"
opt_check cliphist      "clipboard history"
opt_check fd            "launcher file search"
opt_check playerctl     "media keys"
opt_check brightnessctl "brightness"
opt_check hyprlock      "lock screen"
opt_check hypridle      "idle handling"
opt_check hyprsunset    "night light"
opt_check wf-recorder   "screen recording"
opt_check tesseract     "OCR"
opt_check checkupdates  "update count"
opt_check matugen       "wallpaper colour matching"
opt_check ncat          "wallpaper auto-pause"
opt_check powerprofilesctl "power profiles"
opt_check udisksctl     "disk mount/unmount"

if have swww || have awww; then row ok optional "swww/awww" "static wallpapers"
else row warn optional "swww/awww" "missing — static wallpapers unavailable"; fi
if have mpvpaper; then row ok optional mpvpaper "animated wallpapers"
else row warn optional mpvpaper "missing — animated wallpapers unavailable"; fi

# ---- fonts (bar icons are unreadable boxes without these) ----
if fc-list 2>/dev/null | grep -qi "material symbols"; then
    row ok fonts "Material Symbols" "installed"
else
    row crit fonts "Material Symbols" "MISSING — every bar icon renders as a box"
fi
if fc-list 2>/dev/null | grep -qi "symbols nerd font"; then
    row ok fonts "Symbols Nerd Font" "installed"
else
    row warn fonts "Symbols Nerd Font" "missing — distro/brand glyphs render as boxes"
fi

# ---- config integrity ----
# Invalid JSON is the quiet killer: the shell try/catches every parse, so a corrupt file does
# not crash anything, it just silently reverts that whole area to defaults.
for f in appearance.json dock.json window-rules.json gestures.json usage.json timers.json; do
    p="$CFG/$f"
    if [ ! -f "$p" ]; then
        row ok config "$f" "not created yet (defaults in use)"
    elif python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$p" 2>/dev/null; then
        row ok config "$f" "valid — $(wc -c < "$p" | tr -d ' ') bytes"
    else
        row crit config "$f" "INVALID JSON — these settings silently fall back to defaults"
    fi
done

# ---- deployment ----
if [ -f "$QSD/.sea-shell" ]; then
    row ok deploy "shell files" "installed ($(ls "$QSD" | wc -l | tr -d ' ') files, v$(cat "$QSD/VERSION" 2>/dev/null || echo '?'))"
else
    row crit deploy "shell files" "not installed — run ./install.sh"
fi
for f in sea.lua keybinds.lua; do
    [ -f "$HYD/$f" ] && row ok deploy "$f" "present" || row crit deploy "$f" "missing from ~/.config/hypr/sea-shell"
done
for f in matugen.lua rules.lua gestures.lua; do
    [ -f "$HYD/$f" ] && row ok deploy "$f" "generated" || row ok deploy "$f" "not generated (nothing configured)"
done

# ---- compositor ----
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    row ok hyprland session "$(hyprctl version 2>/dev/null | head -1 | sed 's/^Hyprland //;s/ built.*//')"
    # Which parser is in use decides whether the shell's `hyprctl eval` fallbacks are the right
    # path. Detected from the config FILE, not by probing `hyprctl keyword` — probing would have
    # meant actually setting a keyword to see whether it was refused, and a health check that
    # mutates the thing it is inspecting is not a health check.
    if [ -f "$HOME/.config/hypr/hyprland.lua" ]; then
        row ok hyprland "config parser" "lua (eval path in use — correct for 0.55+)"
    elif [ -f "$HOME/.config/hypr/hyprland.conf" ]; then
        row warn hyprland "config parser" "legacy hyprlang — sea-shell 5.0+ targets the lua config"
    else
        row warn hyprland "config parser" "no hyprland.lua or hyprland.conf found"
    fi
else
    row warn hyprland session "not inside a hyprland session"
fi

# ---- the bar itself ----
barpid=$(pgrep -xf "qs -c sea-shell" 2>/dev/null | head -1)
if [ -n "$barpid" ]; then
    up=$(ps -o etimes= -p "$barpid" 2>/dev/null | tr -d ' ')
    row ok bar process "running (pid $barpid, up ${up:-?}s)"
else
    row crit bar process "NOT RUNNING — start it with sea-bar-supervisor.sh --restart"
fi
suppid=$(pgrep -f '[s]ea-bar-supervisor' 2>/dev/null | head -1)
[ -n "$suppid" ] && row ok bar supervisor "running (pid $suppid)" \
                 || row crit bar supervisor "not running — a crash will leave you with no bar"

# ---- crash history (the whole point of this script) ----
LOG="$STATE/sea-shell-supervisor.log"
if [ -f "$LOG" ]; then
    total=$(grep -c "bar exited" "$LOG" 2>/dev/null || echo 0)
    # rc=255 is the wayland-connection death that a fullscreen client teardown causes;
    # rc=143 is a deliberate TERM (a restart), which is not a fault.
    crashes=$(grep -c "rc=255" "$LOG" 2>/dev/null || echo 0)
    last=$(grep "bar exited" "$LOG" 2>/dev/null | tail -1)
    if [ "$crashes" -gt 0 ]; then
        row warn crashes "unexpected exits" "$crashes of $total (rc=255 = wayland connection lost)"
    else
        row ok crashes "unexpected exits" "none of $total recorded exits"
    fi
    [ -n "$last" ] && row ok crashes "most recent exit" "$last"
else
    row ok crashes log "no supervisor log yet"
fi

# ---- bluetooth battery reporting ----
# The bar already renders a device's battery when BlueZ offers one (modelData.batteryAvailable).
# It almost never does, because org.bluez.Battery1 is gated behind BlueZ's experimental flag —
# so the usual "sea-shell doesn't show my earbud battery" is a bluetoothd setting, not a missing
# feature. Say which, rather than leaving it a mystery.
if have bluetoothctl; then
    if grep -qiE '^\s*Experimental\s*=\s*true' /etc/bluetooth/main.conf 2>/dev/null; then
        row ok bluetooth "battery reporting" "BlueZ experimental on — battery % will show when a device reports it"
    else
        row warn bluetooth "battery reporting" "off — set Experimental = true in /etc/bluetooth/main.conf, then: systemctl restart bluetooth"
    fi
fi

# ---- disk ----
avail=$(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
usepct=$(df "$HOME" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
if [ -n "$usepct" ] && [ "$usepct" -ge 92 ]; then
    row crit disk "home free" "${avail:-?} left (${usepct}% used)"
elif [ -n "$usepct" ] && [ "$usepct" -ge 85 ]; then
    row warn disk "home free" "${avail:-?} left (${usepct}% used)"
else
    row ok disk "home free" "${avail:-?} left (${usepct:-?}% used)"
fi

exit 0
