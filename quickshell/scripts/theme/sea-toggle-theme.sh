#!/bin/sh
# sea-shell — flip the shell between dark and light (bound to a key). Turns the
# auto-schedule off so a manual pick sticks until you re-enable it in settings.
cfg="$HOME/.config/sea-shell/appearance.json"
mkdir -p "$HOME/.config/sea-shell"
python3 - "$cfg" <<'PY'
import json, os, sys
cfg = sys.argv[1]
try: d = json.load(open(cfg))
except Exception: d = {}
d["mode"] = "light" if d.get("mode", "dark") == "dark" else "dark"
d["autoDark"] = False
_t = cfg + ".tmp"
with open(_t, "w") as _fh: json.dump(d, _fh)
os.replace(_t, cfg)   # atomic: the bar watches this file and a torn read is a lost theme change
PY
