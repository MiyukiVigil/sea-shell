#!/usr/bin/env python3
"""sea-setups — one desktop arrangement per set of displays.

A laptop is used two ways: on its own, and docked to a monitor with the lid shut or open. The
widgets, the dock and the bar that suit one rarely suit the other, and arranging them again
every time a cable goes in is the chore this removes. Each distinct set of enabled displays is a
"setup"; when the set changes, the arrangement you had is kept under the old setup and the one
you last had on the new setup comes back.

    sea-setups.py --switch     the displays changed (or the shell started): swap if needed
    sea-setups.py --list       print the known setups
    sea-setups.py --forget     drop every saved setup (the current arrangement is kept)

What a setup holds:
  * desktop.json, whole (the widgets and where they sit)
  * from appearance.json, only the placement keys in KEYS (bar edge and height, the dock)

A set of displays seen for the first time takes over the arrangement as it is, so nothing ever
changes under you the first time. Turned off with "displaySetups": false in appearance.json.
Displays are told apart by their description (make, model, serial), not by connector name,
because the same monitor can come up as HDMI-A-1 one day and DP-2 the next through a dock.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile

HOME = os.path.expanduser("~")
CFG_DIR = os.path.join(HOME, ".config", "sea-shell")
DESKTOP = os.path.join(CFG_DIR, "desktop.json")
APPEARANCE = os.path.join(CFG_DIR, "appearance.json")
SETUPS = os.path.join(CFG_DIR, "setups")
CURRENT = os.path.join(SETUPS, "current")
KEYS = ("edge", "height", "dock", "dockEdge", "dockMode", "dockZoom", "dockIcon")


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".setup-")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)


def displays():
    """The enabled displays as [(description, connector)], sorted, or None if Hyprland is not answering."""
    try:
        out = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True, timeout=4).stdout
        mons = json.loads(out)
    except Exception:
        return None
    got = [((m.get("description") or m.get("name") or "").strip(), m.get("name") or "")
           for m in mons if not m.get("disabled")]
    return sorted(got) if got else None


def key_of(ds):
    return hashlib.sha1("\n".join(d for d, _ in ds).encode()).hexdigest()[:12]


def label_of(ds):
    return " + ".join(c for _, c in ds)


def snapshot():
    ap = read_json(APPEARANCE, {})
    return {"desktop": read_json(DESKTOP, None),
            "appearance": {k: ap[k] for k in KEYS if k in ap}}


def apply(saved):
    if saved.get("desktop"):
        write_json(DESKTOP, saved["desktop"])
    keep = saved.get("appearance") or {}
    if keep:
        ap = read_json(APPEARANCE, {})
        if any(ap.get(k) != v for k, v in keep.items()):
            ap.update(keep)
            write_json(APPEARANCE, ap)


def notify(text):
    try:
        subprocess.Popen(["notify-send", "-a", "sea-shell", "-i", "video-display", "Display setup", text],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def switch():
    if read_json(APPEARANCE, {}).get("displaySetups") is False:
        print(json.dumps({"skipped": "off"}))
        return 0
    ds = displays()
    if not ds:
        print(json.dumps({"skipped": "no displays"}))
        return 0
    new = key_of(ds)
    try:
        with open(CURRENT) as fh:
            old = fh.read().strip()
    except OSError:
        old = ""
    if new == old:
        print(json.dumps({"setup": new, "changed": False}))
        return 0
    # keep what you had under the setup you are leaving
    if old:
        prev = read_json(os.path.join(SETUPS, old + ".json"), {})
        prev.update(snapshot())
        write_json(os.path.join(SETUPS, old + ".json"), prev)
    path = os.path.join(SETUPS, new + ".json")
    saved = read_json(path, None)
    restored = False
    if saved and old:
        apply(saved)
        restored = True
    else:
        saved = snapshot()
    saved["label"] = label_of(ds)
    saved["displays"] = [d for d, _ in ds]
    write_json(path, saved)
    os.makedirs(SETUPS, exist_ok=True)
    with open(CURRENT, "w") as fh:
        fh.write(new)
    if restored:
        notify("Restored your layout for " + saved["label"])
    print(json.dumps({"setup": new, "label": saved["label"], "changed": True, "restored": restored}))
    return 0


def main(argv):
    if "--switch" in argv:
        return switch()
    if "--list" in argv:
        cur = ""
        try:
            with open(CURRENT) as fh:
                cur = fh.read().strip()
        except OSError:
            pass
        out = []
        for name in sorted(os.listdir(SETUPS)) if os.path.isdir(SETUPS) else []:
            if name.endswith(".json"):
                j = read_json(os.path.join(SETUPS, name), {})
                out.append({"id": name[:-5], "label": j.get("label", ""), "current": name[:-5] == cur,
                            "widgets": len((j.get("desktop") or {}).get("items", []))})
        print(json.dumps(out, indent=2))
        return 0
    if "--forget" in argv:
        if os.path.isdir(SETUPS):
            for name in os.listdir(SETUPS):
                os.remove(os.path.join(SETUPS, name))
        print(json.dumps({"forgot": True}))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
