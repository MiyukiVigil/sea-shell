#!/usr/bin/env python3
"""sea-wallpaper-quiet — where on this wallpaper is it safe to put something.

Produces a coarse map of how much is going on in each part of the current wallpaper, so
desktop widgets and shortcuts can be kept off the subject instead of landing on a
character's face. Written to $XDG_CACHE_HOME/sea-shell/wallquiet.json on every wallpaper
change.

A MOVING WALLPAPER IS READ AS A PICTURE. Nothing here decodes video. The wallpaper index
already extracts a native-resolution still for every clip (`--fullposter`), because the
picker needed one to stand in while the video is off, and that frame is the input. One
frame is also the right amount: the subject of a looping wallpaper does not wander far,
and a map that changed every frame could not be used to place anything.

HOW IT DECIDES, and what was tried and thrown away — measured against a real twelve-
wallpaper library with the results rendered and looked at, not scored:

  v1  centre-surround detail + chroma.  10/12. Failed catastrophically on two: it put the
      box ON THE CHARACTER'S FACE. Cel-shaded skin is the SMOOTHEST region in the frame,
      so a detail map reads a face as empty. That is the exact failure this exists to
      prevent, so 10/12 was not 83% right, it was wrong.

  v2  added a skin-hue term.  Worse. Anime skin hue also matches every warm background in
      the library; the map saturated everywhere and broke four that v1 got right.

  v3  v1 plus morphological CLOSING of the grid.  11/12, and what this file does. A smooth
      face is a HOLE INSIDE A BUSY OBJECT, not open space, and closing fills holes smaller
      than the structuring element while leaving genuine open space untouched.

  v4  v3 plus |L - median L|, to catch a flat black silhouette.  Fixed that one and broke
      three others: a dark strip under a bright sky is legitimately open space. Rejected.

v3's known miss is a solid black silhouette on a white page — no detail, no chroma, so it
reads as empty. Which is why the map is advice and not a decision: 11/12 is good enough to
suggest and not good enough to overrule anyone. Whatever draws on this must let the user
put a widget wherever they like.

Cost: ImageMagick and the standard library. No numpy, no OpenCV, no model. 207-459ms per
wallpaper, median 280ms.
"""

import json
import os
import subprocess
import sys
import tempfile

GW, GH = 96, 54                  # the grid, 16:9
CLOSE_R = 4                      # structuring element; see v3 above

HOME = os.path.expanduser("~")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(HOME, ".cache")),
                     "sea-shell")
OUT = os.path.join(CACHE, "wallquiet.json")
CONF = os.path.join(HOME, ".config", "sea-shell", "appearance.json")
MOTION = (".mp4", ".mkv", ".webm", ".mov", ".avi", ".gif")


def sibling(name):
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), name)


def current_wallpaper():
    for path, key in ((CONF, "wallpaper"),):
        try:
            with open(path) as fh:
                v = (json.load(fh) or {}).get(key) or ""
            if v:
                return os.path.expanduser(v)
        except Exception:
            pass
    try:
        with open(os.path.join(HOME, ".config", "sea-shell", "wallpaper")) as fh:
            return os.path.expanduser(fh.read().strip())
    except Exception:
        return ""


def still_for(path):
    """The picture to measure. For a clip, the frame the indexer already extracted."""
    if not path or not os.path.exists(path):
        return ""
    if os.path.splitext(path)[1].lower() not in MOTION:
        return path
    idx = sibling("sea-wallpaper-index.py")
    if not os.path.exists(idx):
        return ""
    try:
        out = subprocess.run([sys.executable, idx, "--fullposter", path],
                             capture_output=True, timeout=30)
        cand = (out.stdout or b"").decode("utf-8", "replace").strip().splitlines()
        cand = cand[-1] if cand else ""
        return cand if cand and os.path.exists(cand) else ""
    except Exception:
        return ""


def grid(cmd):
    out = subprocess.run(cmd, capture_output=True, timeout=60).stdout
    if len(out) < GW * GH:
        raise RuntimeError("magick returned %d bytes, wanted %d" % (len(out), GW * GH))
    b = out[-GW * GH:]
    return [b[i] / 255.0 for i in range(GW * GH)]


def _win(m, x, y, r, fn):
    v = []
    for dy in range(-r, r + 1):
        yy = y + dy
        if yy < 0 or yy >= GH:
            continue
        row = yy * GW
        for dx in range(-r, r + 1):
            xx = x + dx
            if 0 <= xx < GW:
                v.append(m[row + xx])
    return fn(v)


def morph(m, r, fn):
    return [_win(m, x, y, r, fn) for y in range(GH) for x in range(GW)]


def lab_grid(img, blur=0):
    cmd = ["magick", img, "-resize", "480x270!"] + (["-blur", "0x%d" % blur] if blur else []) + \
          ["-resize", "%dx%d!" % (GW, GH), "-colorspace", "Lab", "-depth", "8", "rgb:-"]
    out = subprocess.run(cmd, capture_output=True, timeout=60).stdout
    if len(out) < GW * GH * 3:
        return None
    return [out[i * 3:i * 3 + 3] for i in range(GW * GH)]


def surround(img):
    """How far each cell's colour is from the colour of the wide area around it, 0..1."""
    a, b = lab_grid(img), lab_grid(img, 40)
    if a is None or b is None:
        return [0.0] * (GW * GH)
    d = [((a[i][0] - b[i][0]) ** 2 + 1.6 * (a[i][1] - b[i][1]) ** 2 + 1.6 * (a[i][2] - b[i][2]) ** 2) ** 0.5
         for i in range(GW * GH)]
    top = sorted(d)[int(len(d) * 0.97)] or 1.0
    return [min(1.0, v / top) for v in d]


def importance(img):
    # centre-surround: detail that differs from its own neighbourhood
    cs = grid(["magick", img, "-colorspace", "Gray", "-resize", "480x270!",
               "(", "+clone", "-blur", "0x12", ")",
               "-compose", "difference", "-composite", "-auto-level",
               "-resize", "%dx%d!" % (GW, GH), "-depth", "8", "gray:-"])
    # chroma: a character is usually more colourful than the sky behind them
    ch = grid(["magick", img, "-colorspace", "HCL", "-channel", "G", "-separate",
               "+channel", "-resize", "%dx%d!" % (GW, GH), "-depth", "8", "gray:-"])
    # COLOUR AGAINST ITS SURROUNDINGS. Detail and chroma both miss the commonest anime
    # wallpaper: a pale, smoothly shaded character on a pale ground. Her face has almost no
    # edges and almost no colour, so it scored as calm as the sky and widgets sat on it. What
    # she does have is a colour that differs from the wide area around her. A large, even
    # region (sea, sky, sand) matches its own surroundings and stays calm, which a single
    # "background colour" could not manage: it called the sea busy because it is not sky.
    rg = surround(img)
    m = [0.45 * cs[i] + 0.15 * ch[i] + 0.40 * rg[i] for i in range(GW * GH)]
    m = morph(morph(m, CLOSE_R, max), CLOSE_R, min)      # close: fill holes in a subject
    return [_win(m, x, y, 1, lambda v: sum(v) / len(v))  # soften
            for y in range(GH) for x in range(GW)]


def integral(m):
    I = [[0.0] * (GW + 1) for _ in range(GH + 1)]
    for y in range(GH):
        run = 0.0
        for x in range(GW):
            run += m[y * GW + x]
            I[y + 1][x + 1] = I[y][x + 1] + run
    return I


def mean(I, x, y, w, h):
    return (I[y + h][x + w] - I[y][x + w] - I[y + h][x] + I[y][x]) / (w * h)


def quietest(I, w, h, n=4, pad=1):
    """The n calmest non-overlapping places a w×h thing could sit, in grid cells.

    Four lookups per candidate — the summed-area table is what makes searching every
    position affordable in a language with no arrays worth the name.
    """
    cands = []
    for y in range(GH - h + 1):
        for x in range(GW - w + 1):
            cands.append((mean(I, x, y, w, h), x, y))
    cands.sort()
    out = []
    for s, x, y in cands:
        if all(not (x < o["x"] + w + pad and o["x"] < x + w + pad and
                    y < o["y"] + h + pad and o["y"] < y + h + pad) for o in out):
            out.append({"x": x, "y": y, "w": w, "h": h, "score": round(s, 4)})
            if len(out) == n:
                break
    return out


def write(obj):
    # LAST CHANGE WINS, NOT LAST TO FINISH. Each wallpaper change measures in the background,
    # so changing twice quickly races two of these, and the slower one used to land last and
    # describe a wallpaper that was no longer on screen; the desktop then judged its widgets
    # against the wrong picture. A result for anything but the current wallpaper is dropped.
    cur = current_wallpaper()
    if obj.get("wallpaper") and cur and os.path.realpath(obj["wallpaper"]) != os.path.realpath(cur):
        return
    os.makedirs(CACHE, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".wallquiet-")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh)
        os.replace(tmp, OUT)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def main(argv):
    wp = ""
    if "--wallpaper" in argv:
        wp = os.path.expanduser(argv[argv.index("--wallpaper") + 1])
    elif argv and not argv[0].startswith("-"):
        wp = os.path.expanduser(argv[0])
    else:
        wp = current_wallpaper()

    base = {"v": 1, "gw": GW, "gh": GH, "wallpaper": wp}
    still = still_for(wp)
    if not still:
        base["why"] = "no still to measure"
        base["map"] = []
        write(base)
        print(json.dumps({k: base[k] for k in ("v", "why")}))
        return 0

    m = importance(still)
    I = integral(m)
    base["still"] = still
    # 0-255 ints: this is read by QML on every drag, and 5184 floats of JSON is a file the
    # bar would have to re-parse for a precision the map does not have.
    base["map"] = [max(0, min(255, int(round(v * 255)))) for v in m]
    base["mean"] = round(mean(I, 0, 0, GW, GH), 4)
    # HOW LIGHT the picture is under each cell, 0-255. A widget with no tile of its own (the
    # "clear" look, a bare clock) draws its text straight on the photo; this is what tells it
    # whether that text should be dark or light.
    base["luma"] = [max(0, min(255, int(round(v * 255)))) for v in
                    grid(["magick", still, "-colorspace", "Gray", "-resize", "%dx%d!" % (GW, GH),
                          "-depth", "8", "gray:-"])]
    # A few common widget footprints, pre-solved. 16x9 cells is roughly a 320x180 card on a
    # 1920x1080 screen; the others are a wide strip and a small square.
    base["zones"] = {
        "16x9": quietest(I, 16, 9),
        "24x6": quietest(I, 24, 6),
        "10x10": quietest(I, 10, 10),
        # the widget size classes themselves (sea-desktop.py FOOTPRINTS on this 96x54 grid)
        "small": quietest(I, 9, 9),
        "medium": quietest(I, 18, 9),
        "large": quietest(I, 18, 20),
    }
    write(base)
    print(json.dumps({"wallpaper": wp, "still": still, "mean": base["mean"],
                      "best": base["zones"]["16x9"][:1]}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
