#!/bin/sh
# sea-shell — AC / Battery automatic power-profile + internal panel refresh-rate switcher.
#
# Usage: sea-power-auto.sh battery | ac
#
# Only acts when `autoPowerBattery: true` in ~/.config/sea-shell/appearance.json
# AND Game Mode is NOT active. On battery: switches power profile to `power-saver`
# and drops the internal laptop panel (eDP-*) to 60 Hz (saving the prior mode).
# On AC: restores `balanced` and the saved refresh rate.

MODE="${1:-}"
[ "$MODE" = "battery" ] || [ "$MODE" = "ac" ] || exit 0

GM_STATE="${XDG_RUNTIME_DIR:-/tmp}/sea-gamemode.json"
SAVED_HZ="${XDG_RUNTIME_DIR:-/tmp}/sea-power-auto-monitor.json"

# Never fight Game Mode.
grep -q '"on"[[:space:]]*:[[:space:]]*true' "$GM_STATE" 2>/dev/null && exit 0

# Only act if user opted in.
enabled=$(python3 - <<'PY' 2>/dev/null
import json, os
try:
    j = json.load(open(os.path.expanduser("~/.config/sea-shell/appearance.json")))
    print("1" if j.get("autoPowerBattery", False) else "0")
except Exception:
    print("0")
PY
)
[ "$enabled" = "1" ] || exit 0

if ! hyprctl version >/dev/null 2>&1; then
    sig=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" 2>/dev/null | head -1)
    [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

if [ "$MODE" = "battery" ]; then
    powerprofilesctl set power-saver >/dev/null 2>&1 || true
    # Step internal laptop panel (eDP-*) down to 60 Hz if currently > 65 Hz
    python3 - "$SAVED_HZ" <<'PY' 2>/dev/null
import json, subprocess, sys
saved_path = sys.argv[1]
try:
    mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True, timeout=3))
except Exception:
    sys.exit(0)
for m in mons:
    name = m.get("name", "")
    if not name.startswith("eDP"):
        continue
    hz = float(m.get("refreshRate") or 0)
    w, h = int(m.get("width") or 0), int(m.get("height") or 0)
    x, y = int(m.get("x") or 0), int(m.get("y") or 0)
    scale = m.get("scale") or 1
    if hz > 65 and w > 0 and h > 0:
        with open(saved_path, "w") as f:
            json.dump({"name": name, "w": w, "h": h, "hz": round(hz, 2), "x": x, "y": y, "scale": scale}, f)
        lua = f'hl.monitor({{ output = "{name}", mode = "{w}x{h}@60", position = "{x}x{y}", scale = {scale} }})'
        subprocess.run(["hyprctl", "eval", lua], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    break
PY
else
    powerprofilesctl set balanced >/dev/null 2>&1 || true
    if [ -f "$SAVED_HZ" ]; then
        python3 - "$SAVED_HZ" <<'PY' 2>/dev/null
import json, os, subprocess, sys
saved_path = sys.argv[1]
try:
    d = json.load(open(saved_path))
    lua = f'hl.monitor({{ output = "{d["name"]}", mode = "{d["w"]}x{d["h"]}@{d["hz"]}", position = "{d["x"]}x{d["y"]}", scale = {d["scale"]} }})'
    subprocess.run(["hyprctl", "eval", lua], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    os.remove(saved_path)
except Exception:
    pass
PY
    fi
fi
