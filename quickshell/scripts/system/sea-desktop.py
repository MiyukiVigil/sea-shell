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
    --move ID --x F --y F           put one widget somewhere (fractions)
    --set ID [--ground bare|rule|panel] [--tone accent|frost|green|amber|red|plain]
            [--align left|centre|right] [--size small|medium|large]
    --resettle                      move whatever the new wallpaper covers
    --auto off|rescue|arrange       how hard the desktop follows the wallpaper
    --pin ID | --unpin ID           keep one widget where it is, or release it

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
    "media":   {"w": 0.22,  "h": 0.105},   # room for the visualiser under the track
    "system":  {"w": 0.205, "h": 0.19},    # room for three traces and five readings
    "launch":  {"w": 0.055, "h": 0.085},
}
# Which pre-solved zone list in wallquiet.json best matches each footprint.
ZONE_FOR = {"clock": "16x9", "weather": "16x9", "media": "24x6",
            "system": "10x10", "launch": "10x10"}
KINDS = ("clock", "weather", "media", "system")
SIZES = {"small": 0.75, "medium": 1.0, "large": 1.4}


AUTO_MODES = ("off", "rescue", "arrange")


def auto_arrange():
    """How hard the desktop follows the wallpaper.

    off      never move anything.
    rescue   move only what the new wallpaper has put something under, and only to the
             NEAREST clear spot. The default, and usually invisible — which is correct and
             also why it can look like nothing happened: if your widgets live in corners,
             most wallpapers never cover them.
    arrange  re-place every unpinned widget in the calmest space the new picture has. Visibly
             rearranges on every change. Some people want that; it is not the default because
             an arrangement that moves when it did not have to is not an arrangement.
    """
    try:
        with open(CONF) as fh:
            v = (json.load(fh) or {}).get("autoArrange", "rescue")
    except Exception:
        return "rescue"
    if v is True:
        return "rescue"
    if v is False:
        return "off"
    return v if v in AUTO_MODES else "rescue"


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
        json.dump({"v": 1, "autoArrange": auto_arrange(), "items": items}, fh, indent=2)
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


# ---------------------------------------------------------------- resettling ----
#
# WHEN THE WALLPAPER CHANGES, THE DESKTOP FOLLOWS IT. Placing a widget in the calm part of
# one picture says nothing about the next one, and the whole promise of measuring the
# wallpaper is that your clock is not sitting on somebody's face. So every wallpaper change
# re-checks what is on the desktop and moves only what is now covered.
#
# ONLY WHAT IS COVERED, AND ONLY AS FAR AS IT HAS TO. A widget that is still on quiet ground
# does not move at all, and one that must move goes to the NEAREST quiet spot rather than
# the best one — an arrangement that reshuffles itself completely every time you cycle a
# wallpaper is not an arrangement, it is a slideshow. Distance is the tie-breaker precisely
# because the position you chose is information the map does not have.
#
# AND ANYTHING YOU PINNED STAYS PUT. Dropping a widget with SHIFT held means "exactly here",
# which is also a statement that you have overruled the map; it would be rude to then move
# it on the next wallpaper. Pinning is how you say the thing the map cannot know.

BUSY_LIMIT = 0.30          # same threshold the QML nudge and the adaptive grounds use


def quiet_map():
    try:
        with open(QUIET) as fh:
            q = json.load(fh) or {}
        gw, gh, m = q.get("gw"), q.get("gh"), q.get("map")
        if not gw or not gh or not m or len(m) != gw * gh:
            return None
        return gw, gh, m
    except Exception:
        return None


def busy_at(q, x, y, w, h):
    gw, gh, m = q
    x0, y0 = max(0, int(x * gw)), max(0, int(y * gh))
    x1, y1 = min(gw, int((x + w) * gw) + 1), min(gh, int((y + h) * gh) + 1)
    if x1 <= x0 or y1 <= y0:
        return 0.0
    tot = n = 0
    for yy in range(y0, y1):
        row = yy * gw
        for xx in range(x0, x1):
            tot += m[row + xx]
            n += 1
    return (tot / n) / 255.0 if n else 0.0


def zone_for(q, it, others):
    """A pre-solved quiet rectangle for this widget, if one is free.

    sea-wallpaper-quiet.py already searched every position for a few common footprints and
    kept the calmest NON-OVERLAPPING handful. Reusing that is what makes arrange mode look
    composed rather than random: the widgets land in the spaces the picture actually has.
    """
    gw, gh, _ = q
    try:
        with open(QUIET) as fh:
            zones = (json.load(fh) or {}).get("zones") or {}
    except Exception:
        return None
    w, h = it.get("w", 0.1), it.get("h", 0.08)
    for z in zones.get(ZONE_FOR.get(it.get("kind"), "16x9"), []):
        nx, ny = clamp(z["x"] / gw, w), clamp(z["y"] / gh, h)
        if any(overlaps({"x": nx, "y": ny, "w": w, "h": h}, o) for o in others):
            continue
        return nx, ny
    return None


def resettle(mode="rescue"):
    """Move what the new wallpaper covers. Returns what moved."""
    q = quiet_map()
    items = load()
    if q is None or not items or mode == "off":
        return []
    gw, gh, _ = q
    moved = []
    for i, it in enumerate(items):
        if it.get("pinned"):
            continue
        w, h = it.get("w", 0.1), it.get("h", 0.08)
        here = busy_at(q, it["x"], it["y"], w, h)
        if mode == "rescue" and here <= BUSY_LIMIT:
            continue
        others = [o for k, o in enumerate(items) if k != i]
        # Every position on the grid, nearest first. 5184 candidates is nothing, and
        # sorting by distance is what makes this a nudge rather than a re-layout.
        cands = []
        for gy in range(gh):
            for gx in range(gw):
                nx, ny = clamp(gx / gw, w), clamp(gy / gh, h)
                d = (nx - it["x"]) ** 2 + (ny - it["y"]) ** 2
                cands.append((d, nx, ny))
        if mode == "arrange":
            # Sorting every cell by calmness does NOT work here, and it is worth saying why:
            # on a typical wallpaper thousands of cells tie at the same rounded score, the
            # distance tie-break then wins, and the widget stays exactly where it was — an
            # "arrange" mode that provably never moves anything. So arrange uses the composed
            # zones the map already solved: a handful of genuinely separated quiet rectangles
            # per footprint, which is a LAYOUT rather than an argmin.
            placed = zone_for(q, it, others)
            if placed is None:
                cands.sort()
            else:
                nx, ny = placed
                if abs(nx - it["x"]) > 1e-4 or abs(ny - it["y"]) > 1e-4:
                    moved.append({"id": it.get("id"), "from": [it["x"], it["y"]],
                                  "to": [nx, ny]})
                    it["x"], it["y"] = round(nx, 4), round(ny, 4)
                continue
        else:
            cands.sort()
        for _, nx, ny in cands:
            if busy_at(q, nx, ny, w, h) > BUSY_LIMIT:
                continue
            if any(overlaps({"x": nx, "y": ny, "w": w, "h": h}, o) for o in others):
                continue
            if abs(nx - it["x"]) < 1e-4 and abs(ny - it["y"]) < 1e-4:
                break                                    # already the right place
            moved.append({"id": it.get("id"), "from": [it["x"], it["y"]], "to": [nx, ny]})
            it["x"], it["y"] = round(nx, 4), round(ny, 4)
            break
    if moved:
        save(items)
    return moved


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
    if "--move" in argv:
        wid = arg(argv, "--move")
        items = load()
        for it in items:
            if it.get("id") != wid:
                continue
            try:
                it["x"] = round(float(arg(argv, "--x", it["x"])), 4)
                it["y"] = round(float(arg(argv, "--y", it["y"])), 4)
            except ValueError:
                return 2
            if "--pin" in argv or "--unpin" in argv:
                it["pinned"] = "--pin" in argv
        save(items)
        print(json.dumps({"moved": wid}))
        return 0
    if "--set" in argv:
        wid = arg(argv, "--set")
        items = load()
        hit = False
        for it in items:
            if it.get("id") != wid:
                continue
            hit = True
            for key in ("ground", "tone", "align"):
                v = arg(argv, "--" + key)
                if v:
                    it[key] = v
            sz = arg(argv, "--size")
            if sz in SIZES:
                # Geometry has ONE home. Size changes the footprint here rather than being a
                # font multiplier in QML, so the placement search, the overlap test and what
                # is drawn are all reasoning about the same rectangle.
                base = DEFAULTS.get(it.get("kind"), DEFAULTS["clock"])
                it["w"] = round(base["w"] * SIZES[sz], 4)
                it["h"] = round(base["h"] * SIZES[sz], 4)
                it["size"] = sz
        if not hit:
            sys.stderr.write("sea-desktop: no such widget: %s\n" % wid)
            return 1
        save(items)
        print(json.dumps({"set": wid}))
        return 0
    if "--auto" in argv:
        want = (arg(argv, "--auto") or "").lower()
        if want == "on":
            want = "rescue"
        if want not in AUTO_MODES:
            sys.stderr.write("sea-desktop: --auto takes %s\n" % " | ".join(AUTO_MODES))
            return 2
        try:
            with open(CONF) as fh:
                j = json.load(fh) or {}
        except Exception:
            j = {"v": 1, "items": []}
        j["autoArrange"] = want
        os.makedirs(os.path.dirname(CONF), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CONF), prefix=".desktop-")
        with os.fdopen(fd, "w") as fh:
            json.dump(j, fh, indent=2)
        os.replace(tmp, CONF)
        print("auto-arrange %s" % want)
        return 0
    if "--pin" in argv or "--unpin" in argv:
        want = "--pin" in argv
        wid = arg(argv, "--pin" if want else "--unpin")
        items = load()
        for it in items:
            if it.get("id") == wid:
                it["pinned"] = want
        save(items)
        print("%s %s" % ("pinned" if want else "unpinned", wid))
        return 0
    if "--resettle" in argv:
        mode = arg(argv, "--mode") or auto_arrange()
        print(json.dumps({"mode": mode, "moved": resettle(mode)}))
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
