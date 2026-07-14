#!/bin/sh
# sea-shell — flip the shell between dark and light (bound to a key). Turns the
# auto-schedule off so a manual pick sticks until you re-enable it in settings.
cfg="$HOME/.config/sea-shell/appearance.json"
mkdir -p "$HOME/.config/sea-shell"
python3 - "$cfg" <<'PY'
import json, sys
cfg = sys.argv[1]
try: d = json.load(open(cfg))
except Exception: d = {}
d["mode"] = "light" if d.get("mode", "dark") == "dark" else "dark"
d["autoDark"] = False
json.dump(d, open(cfg, "w"))
PY
