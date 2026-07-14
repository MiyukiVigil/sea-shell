#!/bin/sh
# sea-shell — flip the night-light (hyprsunset) on/off, persisted in appearance.json
# (bound to the Control Center tile). Turns off "follow dark mode" so a manual pick sticks.
cfg="$HOME/.config/sea-shell/appearance.json"
mkdir -p "$HOME/.config/sea-shell"
python3 - "$cfg" <<'PY'
import json, sys
cfg = sys.argv[1]
try: d = json.load(open(cfg))
except Exception: d = {}
d["night"] = not d.get("night", False)
d["nightAuto"] = False
json.dump(d, open(cfg, "w"))
PY
