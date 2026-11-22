#!/bin/sh
# sea-shell — Quick Window Layout & PiP Snapper (Hyprland 0.55+ Lua dispatch).
#
# Usage:
#   sea-win-layout.sh pip      toggle Picture-in-Picture (float + pin + bottom-right corner)
#   sea-win-layout.sh focus    toggle centered 75% x 82% floating focus window
#   sea-win-layout.sh split70  set dwindle split ratio to 0.70 (or back to 0.50)

ACTION="${1:-pip}"

python3 - "$ACTION" <<'PY'
import json, subprocess, sys

action = sys.argv[1]

def hypr(expr):
    subprocess.run(["hyprctl", "dispatch", expr], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

try:
    win = json.loads(subprocess.check_output(["hyprctl", "activewindow", "-j"], text=True, timeout=2))
    mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True, timeout=2))
except Exception:
    sys.exit(0)

if not win or not win.get("address"):
    sys.exit(0)

mon = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
if not mon:
    sys.exit(0)

scale = float(mon.get("scale") or 1.0)
mw = int(mon["width"] / scale)
mh = int(mon["height"] / scale)
mx = int(mon.get("x") or 0)
my = int(mon.get("y") or 0)

is_float = bool(win.get("floating"))
is_pinned = bool(win.get("pinned"))

if action == "pip":
    if is_pinned:
        hypr("hl.dsp.window.pin()")
        if is_float:
            hypr("hl.dsp.window.float({ action = 'toggle' })")
    else:
        if not is_float:
            hypr("hl.dsp.window.float({ action = 'toggle' })")
        pw = max(360, int(mw * 0.28))
        ph = max(202, int(pw * 9 / 16))
        px = mx + mw - pw - 20
        py = my + mh - ph - 20
        hypr(f"hl.dsp.window.resize({{ size = {{ exact = true, x = {pw}, y = {ph} }} }})")
        hypr(f"hl.dsp.window.move({{ pos = {{ exact = true, x = {px}, y = {py} }} }})")
        hypr("hl.dsp.window.pin()")
elif action == "focus":
    if is_float:
        if is_pinned:
            hypr("hl.dsp.window.pin()")
        hypr("hl.dsp.window.float({ action = 'toggle' })")
    else:
        hypr("hl.dsp.window.float({ action = 'toggle' })")
        fw = int(mw * 0.75)
        fh = int(mh * 0.82)
        hypr(f"hl.dsp.window.resize({{ size = {{ exact = true, x = {fw}, y = {fh} }} }})")
        hypr("hl.dsp.window.center()")
elif action == "split70":
    w = int((win.get("size") or [0, 0])[0])
    target = "0.5" if w > mw * 0.62 else "0.7"
    hypr(f"hl.dsp.layout_msg('splitratio exact {target}')")
PY
