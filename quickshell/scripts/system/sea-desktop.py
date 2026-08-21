#!/usr/bin/env python3
"""sea-desktop — what is on the desktop.

Owns ~/.config/sea-shell/desktop.json, which Desktop.qml watches. Adding and removing
lives here rather than in QML for two reasons: there is one desktop but a surface per
monitor, and letting each of them write the same file is a race waiting to happen; and a
desktop you can arrange from a keybind or a script is more useful than one you can only
arrange with a mouse.

    --list                          print the arrangement
    --ensure                        create an empty arrangement if absent
    --add-clock | --add-weather | --add-media | --add-system
                                    add a widget
    --add-entry ID [--label L] [--icon I]
                                    add a shortcut to an installed application
    --add-app EXEC [--label L] [--icon I]
                                    add a shortcut
    --remove ID                     remove one item
    --clear                         remove everything (kept in desktop.json.bak)
    --restore                       put desktop.json.bak back

New items are placed in the calmest spot the wallpaper has left — sea-wallpaper-quiet.py
has already worked that out and cached it — and failing that, top-left. Positions are
FRACTIONS of the screen, never pixels; see the note in Desktop.qml.
"""

import json
import os
import sys
import tempfile

HOME = os.path.expanduser("~")
CONF = os.path.join(HOME, ".config", "sea-shell", "desktop.json")
QUIET = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(HOME, ".cache")),
                     "sea-shell", "wallquiet.json")

DEFAULTS = {
    "clock":   {"w": 0.17,  "h": 0.11},
    "weather": {"w": 0.15,  "h": 0.10},
    "media":   {"w": 0.22,  "h": 0.075},
    "system":  {"w": 0.13,  "h": 0.12},
    "launch":  {"w": 0.055, "h": 0.085},
}
# Which pre-solved zone list in wallquiet.json best matches each footprint.
ZONE_FOR = {"clock": "16x9", "weather": "16x9", "media": "24x6",
            "system": "10x10", "launch": "10x10"}
KINDS = ("clock", "weather", "media", "system")


def load():
    try:
        with open(CONF) as fh:
            j = json.load(fh) or {}
        items = j.get("items")
        return items if isinstance(items, list) else []
    except Exception:
        return []


def save(items, allow_empty=False):
    """Write the arrangement, keeping the previous one alongside it.

    EMPTYING IS A DELIBERATE ACT. An arrangement went to zero items once during
    development and nothing in the logs could say which caller did it — which is the point:
    whatever the cause, the result was a desktop that silently forgot everything on it. So
    writing an empty list now requires asking (--clear), and every write leaves the previous
    arrangement in desktop.json.bak, so even a wipe is one `mv` away from undone.
    """
    if not items and not allow_empty and os.path.exists(CONF) and load():
        sys.stderr.write("sea-desktop: refusing to empty the arrangement; use --clear\n")
        return False
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    if os.path.exists(CONF):
        try:
            with open(CONF) as src, open(CONF + ".bak", "w") as dst:
                dst.write(src.read())
        except Exception:
            pass
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CONF), prefix=".desktop-")
    with os.fdopen(fd, "w") as fh:
        json.dump({"v": 1, "items": items}, fh, indent=2)
    os.replace(tmp, CONF)
    return True


def overlaps(a, b, pad=0.01):
    return not (a["x"] + a["w"] + pad <= b["x"] or b["x"] + b["w"] + pad <= a["x"] or
                a["y"] + a["h"] + pad <= b["y"] or b["y"] + b["h"] + pad <= a["y"])


# Nothing is placed hard against a screen edge. The quiet map will happily hand back
# column 0 — the edge of a wallpaper is often its emptiest part — and a shortcut sitting
# flush against the bezel reads as clipped rather than as placed.
MARGIN = 0.02


def clamp(v, size):
    return max(MARGIN, min(1 - size - MARGIN, v))


def place(kind, items):
    """The calmest free spot, in fractions. Falls back to a tidy top-left column."""
    size = DEFAULTS.get(kind, DEFAULTS["clock"])
    try:
        with open(QUIET) as fh:
            q = json.load(fh) or {}
        gw, gh = q.get("gw") or 96, q.get("gh") or 54
        for z in (q.get("zones") or {}).get(ZONE_FOR.get(kind, "16x9"), []):
            cand = {"x": clamp(z["x"] / gw, size["w"]),
                    "y": clamp(z["y"] / gh, size["h"]),
                    "w": size["w"], "h": size["h"]}
            if not any(overlaps(cand, o) for o in items):
                return cand["x"], cand["y"]
    except Exception:
        pass
    y = 0.06
    while any(overlaps({"x": 0.03, "y": y, "w": size["w"], "h": size["h"]}, o)
              for o in items) and y < 0.85:
        y += size["h"] + 0.02
    return 0.03, y


def next_id(items, kind):
    n = 1
    used = {i.get("id") for i in items}
    while "%s%d" % (kind, n) in used:
        n += 1
    return "%s%d" % (kind, n)


def add(kind, extra=None):
    items = load()
    x, y = place(kind, items)
    size = DEFAULTS.get(kind, DEFAULTS["clock"])
    it = {"id": next_id(items, kind), "kind": kind,
          "x": round(x, 4), "y": round(y, 4), "w": size["w"], "h": size["h"]}
    it.update(extra or {})
    items.append(it)
    save(items)
    return it


def arg(argv, name, default=""):
    return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) \
        else default


def main(argv):
    if "--list" in argv or not argv:
        print(json.dumps({"items": load()}, indent=2))
        return 0
    if "--ensure" in argv:
        # A FileView cannot watch a path that has never existed, so an empty desktop still
        # needs a file. Without it the surface reads "no arrangement" once at startup and
        # never notices the first thing you add.
        if not os.path.exists(CONF):
            save([], allow_empty=True)
            print("created %s" % CONF)
        else:
            print("exists")
        return 0
    if "--clear" in argv:
        save([], allow_empty=True)
        print("cleared (previous arrangement kept in %s.bak)" % os.path.basename(CONF))
        return 0
    if "--restore" in argv:
        try:
            with open(CONF + ".bak") as fh:
                items = (json.load(fh) or {}).get("items") or []
            save(items, allow_empty=True)
            print("restored %d items" % len(items))
        except Exception as e:
            sys.stderr.write("sea-desktop: nothing to restore (%s)\n" % e)
            return 1
        return 0
    if "--remove" in argv:
        want = arg(argv, "--remove")
        items = [i for i in load() if i.get("id") != want]
        save(items)
        print("removed %s" % want)
        return 0
    for k in KINDS:
        if "--add-" + k in argv:
            print(json.dumps(add(k)))
            return 0
    if "--add-entry" in argv:
        eid = arg(argv, "--add-entry")
        if not eid:
            sys.stderr.write("sea-desktop: --add-entry needs a .desktop id\n")
            return 2
        print(json.dumps(add("launch", {
            "entry": eid,
            "label": arg(argv, "--label") or eid,
            "icon": arg(argv, "--icon") or eid,
        })))
        return 0
    if "--add-app" in argv:
        ex = arg(argv, "--add-app")
        if not ex:
            sys.stderr.write("sea-desktop: --add-app needs a command\n")
            return 2
        label = arg(argv, "--label") or os.path.basename(ex.split()[0])
        icon = arg(argv, "--icon") or ex.split()[0]
        print(json.dumps(add("launch", {"exec": ex, "label": label, "icon": icon})))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
