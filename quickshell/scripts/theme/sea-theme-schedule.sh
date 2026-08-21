#!/bin/sh
# sea-shell — auto dark mode. When enabled, force dark inside the configured window
# (darkStart..darkEnd, may wrap past midnight) and light outside it. Only writes
# appearance.json when the mode actually flips, so the bar's file-watcher settles
# in one pass with no write loop. Run every minute by the bar.
cfg="$HOME/.config/sea-shell/appearance.json"
[ -f "$cfg" ] || exit 0
python3 - "$cfg" <<'PY'
import json, os, sys, datetime
cfg = sys.argv[1]
try: d = json.load(open(cfg))
except Exception: sys.exit(0)
# modeSource is the authority; autoDark is what a config written before it existed has.
# Without this a saved "follow the wallpaper" plus a stale autoDark=true would have the two
# sources overwriting each other once a minute.
src = d.get("modeSource") or ("clock" if d.get("autoDark") else "manual")
if src != "clock": sys.exit(0)
def mins(t, dv):
    try:
        h, m = str(t).split(":"); return (int(h) % 24) * 60 + (int(m) % 60)
    except Exception:
        return dv
start = mins(d.get("darkStart", "19:00"), 19 * 60)
end   = mins(d.get("darkEnd",   "07:00"),  7 * 60)
now = datetime.datetime.now(); cur = now.hour * 60 + now.minute
is_dark = (start <= cur < end) if start <= end else (cur >= start or cur < end)
want = "dark" if is_dark else "light"
if d.get("mode") != want:
    d["mode"] = want
    _t = cfg + ".tmp"
with open(_t, "w") as _fh: json.dump(d, _fh)
os.replace(_t, cfg)   # atomic: the bar watches this file and a torn read is a lost theme change
PY
