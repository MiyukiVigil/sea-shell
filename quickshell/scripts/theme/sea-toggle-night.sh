#!/bin/sh
# sea-shell — flip the night-light (hyprsunset) on/off, persisted in appearance.json
# (bound to the Control Center tile). Turns off "follow dark mode" so a manual pick sticks.
cfg="$HOME/.config/sea-shell/appearance.json"
mkdir -p "$HOME/.config/sea-shell"
python3 - "$cfg" <<'PY'
import json, os, sys
cfg = sys.argv[1]
try: d = json.load(open(cfg))
except Exception: d = {}
d["night"] = not d.get("night", False)
d["nightAuto"] = False
_t = cfg + ".tmp"
with open(_t, "w") as _fh: json.dump(d, _fh)
os.replace(_t, cfg)   # atomic: the bar watches this file and a torn read is a lost theme change
PY
