#!/usr/bin/env python3
"""sea-desktop — what is on the desktop.

Owns ~/.config/sea-shell/desktop.json, which Desktop.qml watches. Adding and removing
lives here rather than in QML for two reasons: there is one desktop but a surface per
monitor, and letting each of them write the same file is a race waiting to happen; and a
desktop you can arrange from a keybind or a script is more useful than one you can only
arrange with a mouse.

    --list                          print the arrangement
    --ensure                        create an empty arrangement if absent
    --add-clock | --add-weather | --add-media | --add-system | --add-calendar | --add-battery
    --add-notifications | --add-network | --add-quote | --add-photo | --add-ai
    --add-github | --add-pomodoro | --add-clipboard | --add-tide
                 [--x F --y F] [--size small|medium|large] [--face F] [--look card|glass|clear|classic]
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
             [--look card|glass|clear|classic] [--face dial|cookie|digital|stacked]
             [--src wallpapers|pictures|screenshots]  (photo: which folder it shows)
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

# Widgets come in macOS's three size classes, and each class is a different layout, not a
# different zoom: small is a square, medium is two smalls wide, large is two wide and two high.
# On a 1080p field these are about 170x170, 360x170 and 360x376.
FOOTPRINTS = {"small": {"w": 0.0885, "h": 0.17}, "medium": {"w": 0.1875, "h": 0.17},
              "large": {"w": 0.1875, "h": 0.376}}
DEFAULT_SIZE = {"clock": "small", "weather": "medium", "media": "medium", "system": "medium",
                "calendar": "medium", "battery": "small",
                "notifications": "medium", "network": "small", "quote": "medium", "photo": "small",
                "ai": "medium", "github": "medium", "pomodoro": "small", "clipboard": "medium",
                "tide": "medium"}
DEFAULTS = {
    "clock":   FOOTPRINTS["small"],
    "weather": FOOTPRINTS["medium"],
    "media":   FOOTPRINTS["medium"],
    "system":  FOOTPRINTS["medium"],
    "calendar": FOOTPRINTS["medium"],
    "battery": FOOTPRINTS["small"],
    "notifications": FOOTPRINTS["medium"],
    "network": FOOTPRINTS["small"],
    "quote":   FOOTPRINTS["medium"],
    "photo":   FOOTPRINTS["small"],
    "ai":      FOOTPRINTS["medium"],
    "github":  FOOTPRINTS["medium"],
    "pomodoro": FOOTPRINTS["small"],
    "clipboard": FOOTPRINTS["medium"],
    "tide":    FOOTPRINTS["medium"],
    "launch":  {"w": 0.055, "h": 0.085},
}
# Which pre-solved zone list in wallquiet.json best matches each footprint. Widgets with a size
# class use the zone solved for exactly that size; the older generic shapes remain for
# shortcuts and for a wallquiet.json written before the size zones existed.
ZONE_FOR = {"clock": "16x9", "weather": "16x9", "media": "16x9",
            "system": "10x10", "launch": "10x10"}


def zone_list(zones, kind, size=None):
    size = size or DEFAULT_SIZE.get(kind)
    if size and zones.get(size):
        return zones[size]
    return zones.get(ZONE_FOR.get(kind, "16x9"), [])
KINDS = ("clock", "weather", "media", "system", "calendar", "battery",
         "notifications", "network", "quote", "photo", "ai",
         "github", "pomodoro", "clipboard", "tide")
SIZES = {"small": 0.75, "medium": 1.0, "large": 1.4}


AUTO_MODES = ("off", "rescue", "arrange")
FOOTPRINTS_KINDS = KINDS


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
        for z in zone_list(q.get("zones") or {}, kind):
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
    # The step can walk past the last legal row. A widget whose top is below the
    # screen is not placed, it is missing.
    return 0.03, clamp(y, size["h"])


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
    """How busy the wallpaper is under a rectangle: the BUSIEST third of it, not the average.

    An average let a widget sit half over a face, because the other half was empty sky and
    the two cancelled out. A widget covering part of the subject is covering the subject.
    """
    gw, gh, m = q
    x0, y0 = max(0, int(x * gw)), max(0, int(y * gh))
    x1, y1 = min(gw, int((x + w) * gw) + 1), min(gh, int((y + h) * gh) + 1)
    if x1 > x0 and y1 > y0:
        cells = sorted((m[j * gw + i] for j in range(y0, y1) for i in range(x0, x1)), reverse=True)
        k = max(1, int(len(cells) * 0.3))
        return sum(cells[:k]) / k / 255.0
    return 0.0


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
    for z in zone_list(zones, it.get("kind"), it.get("size")):
        nx, ny = clamp(z["x"] / gw, w), clamp(z["y"] / gh, h)
        if any(overlaps({"x": nx, "y": ny, "w": w, "h": h}, o) for o in others):
            continue
        return nx, ny
    return None

# ---------------------------------------------------------------- composing ----
#
# ONE BLOCK, NOT FIVE SPOTS. Placing each widget in its own calmest cell found five good
# spots and no arrangement: the clock at one height, the weather at another, the system card
# halfway across the picture, nothing lined up with anything. A desktop reads as designed when
# its widgets share edges and gaps. So the unpinned widgets are laid out as one block of
# columns with even gutters, small widgets paired side by side into a medium-width row, and it
# is the BLOCK that is placed: slid over the quiet map, and put where the picture is calmest,
# with a lean towards the edges and corners a desktop's furniture belongs in.

ORDER = {"clock": 0, "weather": 1, "calendar": 2, "system": 3, "battery": 4, "media": 5,
         "network": 6, "notifications": 7, "photo": 8, "quote": 9}
GAP_X = 20 / 1920          # the gutter, about 20px each way on a 1080p field
GAP_Y = 20 / 1040
COL_W = FOOTPRINTS["medium"]["w"]


def block_layout(items, ncols):
    """Offsets inside the block for `items` in `ncols` columns: ({id: (dx, dy)}, w, h)."""
    rows, pending = [], None
    for it in sorted(items, key=lambda i: ORDER.get(i.get("kind"), 9)):
        w, h = it.get("w", COL_W), it.get("h", 0.17)
        if w < COL_W * 0.7 and it.get("kind") != "launch":
            if pending is None:
                pending = {"items": [it], "h": h}
                rows.append(pending)
            else:
                pending["items"].append(it); pending["h"] = max(pending["h"], h); pending = None
        else:
            rows.append({"items": [it], "h": h})
    total = sum(r["h"] for r in rows) + GAP_Y * max(0, len(rows) - 1)
    per = total / ncols
    cols, cur, used = [[]], 0, 0.0
    for r in rows:
        if cols[cur] and used + r["h"] > per + 1e-6 and cur < ncols - 1:
            cur += 1; cols.append([]); used = 0.0
        cols[cur].append(r); used += r["h"] + GAP_Y
    pos, bh = {}, 0.0
    for c, col in enumerate(cols):
        y = 0.0
        for r in col:
            x = c * (COL_W + GAP_X)
            for it in r["items"]:
                pos[id(it)] = (x, y)
                x += it.get("w", COL_W) + GAP_X
            y += r["h"] + GAP_Y
        bh = max(bh, y - GAP_Y)
    bw = len(cols) * COL_W + (len(cols) - 1) * GAP_X
    return pos, bw, bh


def compose(q, items):
    """Lay the unpinned widgets out as one block in the calmest place. Returns what moved."""
    free = [it for it in items if not it.get("pinned")]
    fixed = [it for it in items if it.get("pinned")]
    if not free:
        return []
    best = None
    for ncols in range(1, min(3, len(free)) + 1):
        pos, bw, bh = block_layout(free, ncols)
        if bw > 1 - 2 * MARGIN or bh > 1 - 2 * MARGIN:
            continue
        xs = [MARGIN + i * 0.01 for i in range(int((1 - 2 * MARGIN - bw) / 0.01) + 1)]
        ys = [MARGIN + i * 0.02 for i in range(int((1 - 2 * MARGIN - bh) / 0.02) + 1)]
        for bx in xs:
            for by in ys:
                rects = [{"x": bx + pos[id(it)][0], "y": by + pos[id(it)][1],
                          "w": it.get("w", COL_W), "h": it.get("h", 0.17)} for it in free]
                if any(overlaps(r, f) for r in rects for f in fixed):
                    continue
                busy = [busy_at(q, r["x"], r["y"], r["w"], r["h"]) for r in rects]
                score = sum(busy) / len(busy) + 0.6 * max(busy)
                # furniture belongs at the edges: distance from the nearest side, and less so
                # from the nearest top or bottom
                score += 0.18 * min(bx - MARGIN, 1 - MARGIN - bx - bw)
                score += 0.06 * min(by - MARGIN, 1 - MARGIN - by - bh)
                if best is None or score < best[0]:
                    best = (score, bx, by, pos)
    if best is None:
        return []
    _, bx, by, pos = best
    moved = []
    for it in free:
        nx, ny = round(bx + pos[id(it)][0], 4), round(by + pos[id(it)][1], 4)
        if abs(nx - it["x"]) > 1e-4 or abs(ny - it["y"]) > 1e-4:
            moved.append({"id": it.get("id"), "from": [it["x"], it["y"]], "to": [nx, ny]})
            it["x"], it["y"] = nx, ny
    return moved


# THE NUDGE, TUNED. Rescue moves only what the new picture covers, each widget on its own and
# only as far as it must, so a desktop you arranged keeps its character. Three things it used
# to get wrong, all of which left widgets looking dropped rather than placed:
#
#   * it measured only the rectangle under a widget, so a card could sit flush against a face
#     or a strand of hair and count as clear. Clearance is now measured with a margin round it.
#   * it accepted a spot at exactly the limit, so the next wallpaper with the subject a pixel
#     closer moved it again. A destination has to be comfortably clear, not just clear.
#   * it never lined anything up. A widget that has to move now snaps to a neighbour's edge
#     when one is close, so a rescued widget joins the arrangement instead of floating near it.
CLEAR_X, CLEAR_Y = 0.012, 0.02    # the margin a widget wants round it
SETTLE_LIMIT = BUSY_LIMIT - 0.05  # how clear a destination has to be
NEIGHBOUR_PAD = 0.01              # gap kept between widgets (under GAP_X, so a snap fits)


def busy_round(q, x, y, w, h):
    return busy_at(q, x - CLEAR_X, y - CLEAR_Y, w + 2 * CLEAR_X, h + 2 * CLEAR_Y)


def snap(q, it, nx, ny, others):
    """Line (nx, ny) up with a neighbour's edge if one is close and the spot stays clear."""
    w, h = it.get("w", 0.1), it.get("h", 0.08)
    xs, ys = [], []
    for o in others:
        ow, oh = o.get("w", 0.1), o.get("h", 0.08)
        xs += [o["x"], o["x"] + ow - w, o["x"] + ow + GAP_X, o["x"] - w - GAP_X]
        ys += [o["y"], o["y"] + oh - h, o["y"] + oh + GAP_Y, o["y"] - h - GAP_Y]
    def nearest(v, opts, reach):
        best = None
        for c in opts:
            if abs(c - v) <= reach and (best is None or abs(c - v) < abs(best - v)):
                best = c
        return best
    for sx, sy in ((nearest(nx, xs, 0.05), nearest(ny, ys, 0.1)),
                   (nearest(nx, xs, 0.05), None), (None, nearest(ny, ys, 0.1))):
        cx = clamp(sx, w) if sx is not None else nx
        cy = clamp(sy, h) if sy is not None else ny
        if (cx, cy) == (nx, ny):
            continue
        r = {"x": cx, "y": cy, "w": w, "h": h}
        if busy_round(q, cx, cy, w, h) <= SETTLE_LIMIT and \
                not any(overlaps(r, o, NEIGHBOUR_PAD) for o in others):
            return cx, cy
    return nx, ny


def resettle(mode="rescue"):
    """Follow the wallpaper. Returns what moved.

    rescue   the tuned nudge above, per widget.
    arrange  every unpinned widget to a pre-solved quiet zone.
    tidy     compose(): one aligned block in the calmest place (on request, not automatic).
    """
    q = quiet_map()
    items = load()
    if q is None or not items or mode == "off":
        return []
    if mode == "tidy":
        moved = compose(q, items)
        if moved:
            save(items)
        return moved
    gw, gh, _ = q
    moved = []
    for i, it in enumerate(items):
        if it.get("pinned"):
            continue
        w, h = it.get("w", 0.1), it.get("h", 0.08)
        others = [o for k, o in enumerate(items) if k != i]
        if mode == "rescue" and busy_round(q, it["x"], it["y"], w, h) <= BUSY_LIMIT:
            continue
        if mode == "arrange":
            # Sorting every cell by calmness does NOT work here: on a typical wallpaper
            # thousands of cells tie at the same rounded score, the distance tie-break then
            # wins, and nothing ever moves. The zones the map already solved are a LAYOUT
            # rather than an argmin.
            placed = zone_for(q, it, others)
            if placed is not None:
                nx, ny = placed
                if abs(nx - it["x"]) > 1e-4 or abs(ny - it["y"]) > 1e-4:
                    moved.append({"id": it.get("id"), "from": [it["x"], it["y"]], "to": [nx, ny]})
                    it["x"], it["y"] = round(nx, 4), round(ny, 4)
                continue
        # Every position on the grid, nearest first: a nudge, not a re-layout.
        cands = []
        for gy in range(gh):
            for gx in range(gw):
                nx, ny = clamp(gx / gw, w), clamp(gy / gh, h)
                cands.append(((nx - it["x"]) ** 2 + (ny - it["y"]) ** 2, nx, ny))
        cands.sort()
        for _, nx, ny in cands:
            if busy_round(q, nx, ny, w, h) > SETTLE_LIMIT:
                continue
            if any(overlaps({"x": nx, "y": ny, "w": w, "h": h}, o, NEIGHBOUR_PAD) for o in others):
                continue
            nx, ny = snap(q, it, nx, ny, others)
            if abs(nx - it["x"]) < 1e-4 and abs(ny - it["y"]) < 1e-4:
                break
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
    if kind in DEFAULT_SIZE:
        it["size"] = DEFAULT_SIZE[kind]
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
            for key in ("ground", "tone", "align", "look", "face", "src"):
                v = arg(argv, "--" + key)
                if v:
                    it[key] = v
            sz = arg(argv, "--size")
            if sz in SIZES:
                # Geometry has ONE home. Size changes the footprint here rather than being a
                # font multiplier in QML, so the placement search, the overlap test and what
                # is drawn are all reasoning about the same rectangle. A widget's size is its
                # size class; anything else (a shortcut) still scales.
                if it.get("kind") in FOOTPRINTS_KINDS:
                    base = FOOTPRINTS[sz]
                    it["w"], it["h"] = base["w"], base["h"]
                else:
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
    if "--tidy" in argv:
        print(json.dumps({"moved": resettle("tidy")}))
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
        before = load()
        items = [i for i in before if i.get("id") != want]
        if len(items) == len(before):
            sys.stderr.write("sea-desktop: no item %s\n" % want)
            return 1
        # Removing one named item is as deliberate as --clear, so it may leave the desktop
        # empty: without this, the last widget refused to go and said "removed" anyway.
        save(items, allow_empty=True)
        print("removed %s" % want)
        return 0
    for k in KINDS:
        if "--add-" + k in argv:
            # The widget gallery drops a widget where it was let go: --x/--y are the CENTRE
            # of the drop as fractions of the field, and --size/--face/--look carry what was
            # picked. Without them it is placed in the calmest free spot, as before.
            extra = {}
            sz = arg(argv, "--size")
            if sz in FOOTPRINTS:
                extra.update({"size": sz, "w": FOOTPRINTS[sz]["w"], "h": FOOTPRINTS[sz]["h"]})
            for key in ("face", "look", "src"):
                v = arg(argv, "--" + key)
                if v:
                    extra[key] = v
            if "--x" in argv and "--y" in argv:
                w = extra.get("w", DEFAULTS[k]["w"])
                h = extra.get("h", DEFAULTS[k]["h"])
                try:
                    extra["x"] = round(clamp(float(arg(argv, "--x")) - w / 2, w), 4)
                    extra["y"] = round(clamp(float(arg(argv, "--y")) - h / 2, h), 4)
                except ValueError:
                    pass
            print(json.dumps(add(k, extra)))
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
