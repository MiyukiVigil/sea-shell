#!/usr/bin/env python3
"""sea-shell — describe every wallpaper once, and remember it.

    sea-wallpaper-index.py [DIR]        # full TSV, for the picker
    sea-wallpaper-index.py --paths      # just the paths, one per line
    sea-wallpaper-index.py --paths --stills     # …stills only

Writes one TSV row per wallpaper to stdout, in name order:

    path <TAB> bytes <TAB> width <TAB> height <TAB> poster <TAB> ms <TAB> collection <TAB> mtime <TAB> full

`poster` is empty for stills — the file is its own preview — and a cached JPEG for
video and gif, which Qt's Image cannot decode. `ms` is the clip length in
milliseconds, 0 for anything that does not have one. `collection` is the
subfolder the wallpaper sits in, "" for the top level. `mtime` is unix seconds, which is
what the picker's "newest" sort orders by — the one sort that matters for a folder you
drop things into, and the one thing a name-ordered list can never tell you. `full` is a
native-resolution still of a moving wallpaper — the poster is a 1280px thumbnail, which is
right for the rail and visibly soft the moment anything shows it full-screen.

THIS FILE IS THE ONE DEFINITION OF "WHERE THE WALLPAPERS ARE".  It used to be three:
`~/Pictures/wallpapers` was hardcoded here, again in sea-wallpaper-cycle.sh, and a
third time by omission in wallpaper.qml, which ran this with no argument.  So the
folder could not be changed at all, and the three would have drifted the moment it
could.  The cycle script now asks this for the list (`--paths`), and the folder comes
from appearance.json's `wpDir` for both.

WHY THIS IS NOT INLINE IN wallpaper.qml.  It used to be: a `find` for the list, then
one `Process` per video *delegate* that shelled out to ffmpeg.  That was survivable
while the picker drew a static grid of every file at once, and stops being survivable
the moment delegates are recycled — a rail that reuses eight delegates across forty
wallpapers re-runs ffmpeg every time one scrolls back into view.  Worse, the picker
now needs each image's real aspect ratio *before* it can lay the rail out, and asking
Qt means asking after the image has loaded, which is after the layout it was needed
for.  So: one pass, up front, out of process.

Both the probe and the extraction are memoised in ~/.cache/sea-shell/wallindex.tsv,
keyed by path + mtime + size. Reopening the picker re-runs this and touches no
external tool at all; a folder of 4K clips would otherwise pay for ffprobe on every
single open, to learn nothing that changed.

Everything degrades rather than fails.  No ffprobe → 0×0, and the picker falls back
to 16:9.  No ffmpeg → no poster, and the picker draws a film placeholder.  Neither is
an error and neither stops the row being emitted: a wallpaper you cannot preview is
still a wallpaper you can pick.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

STILL = (".jpg", ".jpeg", ".png", ".webp", ".bmp", ".jxl")
MOTION = (".mp4", ".webm", ".gif", ".mkv", ".mov")

HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".cache", "sea-shell")
INDEX = os.path.join(CACHE, "wallindex.tsv")
THUMBS = os.path.join(CACHE, "wallthumbs")
CONF = os.path.join(HOME, ".config", "sea-shell", "appearance.json")

DEFAULT_DIR = os.path.join(HOME, "Pictures", "wallpapers")

# Wide enough to fill the picker's full-bleed preview on a 1440p panel without being
# so wide that a folder of clips costs hundreds of megabytes of cache. The rail scales
# the same file down; decoding one JPEG twice is cheaper than keeping two.
POSTER_WIDTH = 1280
SUFFIX = ".w%d.jpg" % POSTER_WIDTH

# The FREEZE frame is a different job from the poster and needs a different file. The poster
# is a thumbnail: the picker scales it down and 1280 is generous for that. The freeze frame
# REPLACES the playing video on the actual desktop, so anything below the panel's own
# resolution is visibly soft — a 1280 still upscaled onto a 1920 screen is exactly the "looks
# low res when paused" it produced. This one is extracted at the clip's native size.
FULL_SUFFIX = ".full.jpg"

# How deep the walk goes below the wallpaper folder. Deep enough for the way people
# actually file wallpapers (by series, by artist, by mood), shallow enough that
# pointing this at a home directory by mistake does not walk the entire disk.
MAX_DEPTH = 4

# An orphan poster is one whose wallpaper is not in the folder we just indexed — which
# is also what every poster looks like the moment you point wpDir somewhere else. So
# they are given a fortnight's grace before being swept, and only the dead NAMING
# SCHEME (posters written before POSTER_WIDTH existed, which nothing can ever read
# again) is removed on sight.
ORPHAN_GRACE = 14 * 86400


def conf():
    try:
        with open(CONF, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def wallpaper_dir(j):
    d = str(j.get("wpDir") or "").strip()
    d = os.path.expanduser(d) if d else DEFAULT_DIR
    return d if os.path.isdir(d) else DEFAULT_DIR


def run(argv, timeout=20):
    """stdout of a command, or "" for any failure at all — missing binary included."""
    try:
        out = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.decode("utf-8", "replace").strip() if out.returncode == 0 else ""


def probe(path):
    """(width, height, milliseconds). Zeros for whatever could not be measured.

    One ffprobe call for all three: the format-level duration is asked for alongside
    the stream dimensions, because spawning a second process per file to learn one
    number is the cost this whole cache exists to avoid.
    """
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
               "-show_entries", "stream=width,height:format=duration",
               "-of", "default=noprint_wrappers=1:nokey=1", path])
    fields = [x.strip() for x in out.splitlines() if x.strip()]
    w = h = ms = 0
    if len(fields) >= 2 and fields[0].isdigit() and fields[1].isdigit():
        w, h = int(fields[0]), int(fields[1])
    if len(fields) >= 3:
        try:
            # A still reports "N/A" here, which is the correct answer for it.
            ms = int(round(float(fields[2]) * 1000))
        except ValueError:
            ms = 0
    return w, h, ms


def poster_name(path, rel=""):
    """Posters are keyed by the wallpaper's own name, not its full path.

    Two wallpapers with the same basename in different collections would otherwise
    share one poster and show each other's picture, so the collection is folded into
    the key — but ONLY when there is one, which is what keeps every poster written
    before collections existed valid instead of re-extracting the whole folder.
    """
    if not rel:
        return os.path.basename(path) + SUFFIX
    return rel.replace(os.sep, "%") + "%" + os.path.basename(path) + SUFFIX


def full_name(path, rel=""):
    base = poster_name(path, rel)
    return base[:-len(SUFFIX)] + FULL_SUFFIX


def full_poster(path, rel=""):
    """A native-resolution still, for standing in on the desktop while the video is off."""
    target = os.path.join(THUMBS, full_name(path, rel))
    if os.path.isfile(target) and os.path.getsize(target) > 0:
        return target
    os.makedirs(THUMBS, exist_ok=True)
    # No scale filter at all — whatever the clip is, that is what the desktop gets. -q:v 2 so
    # a full-screen still is not a field of JPEG blocks; it costs a few hundred KB once.
    for seek in (["-ss", "1"], []):
        run(["ffmpeg", "-y", "-loglevel", "error"] + seek +
            ["-i", path, "-frames:v", "1", "-q:v", "2", target])
        if os.path.isfile(target) and os.path.getsize(target) > 0:
            return target
    return ""


def poster(path, rel=""):
    """A cached still for a moving wallpaper. Empty string if we could not make one."""
    target = os.path.join(THUMBS, poster_name(path, rel))
    if os.path.isfile(target) and os.path.getsize(target) > 0:
        return target
    os.makedirs(THUMBS, exist_ok=True)
    # Seek a second in first: a great many wallpaper clips open on black, and a black
    # poster is indistinguishable from a broken one. Very short clips have no second to
    # seek to, so fall back to frame zero rather than giving up.
    for seek in (["-ss", "1"], []):
        run(["ffmpeg", "-y", "-loglevel", "error"] + seek +
            ["-i", path, "-frames:v", "1", "-vf", "scale=%d:-2" % POSTER_WIDTH, target])
        if os.path.isfile(target) and os.path.getsize(target) > 0:
            return target
    return ""


def load_cache():
    """{(path, mtime, bytes): (w, h, poster, ms)} — anything malformed is simply dropped.

    Which is also the upgrade path: a cache written before `ms` existed has six fields,
    fails the length check, and is re-probed. Posters are keyed by filename on disk and
    survive, so the upgrade costs one ffprobe per file and no ffmpeg at all.
    """
    out = {}
    try:
        with open(INDEX, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) != 7:
                    continue
                try:
                    out[(f[0], int(f[1]), int(f[2]))] = (int(f[3]), int(f[4]), f[5], int(f[6]))
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def save_cache(rows):
    os.makedirs(CACHE, exist_ok=True)
    tmp = INDEX + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            for key, val in rows.items():
                fh.write("\t".join([key[0], str(key[1]), str(key[2]),
                                    str(val[0]), str(val[1]), val[2], str(val[3])]) + "\n")
        os.replace(tmp, INDEX)
    except OSError:
        pass


def sweep(keep):
    """Delete posters nothing will ever read again.

    The cache had grown to twice the size of the wallpaper folder: eleven of its
    twenty-two files were written under a naming scheme that predates POSTER_WIDTH and
    are unreachable by any code path, and the rest belonged to wallpapers that had been
    deleted. Nothing ever removed either — poster() only creates.
    """
    now = time.time()
    try:
        names = os.listdir(THUMBS)
    except OSError:
        return
    for name in names:
        target = os.path.join(THUMBS, name)
        if name in keep:
            continue
        try:
            dead_scheme = not name.endswith(SUFFIX)
            if not dead_scheme and now - os.path.getmtime(target) < ORPHAN_GRACE:
                continue
            os.remove(target)
        except OSError:
            pass


def walk(root):
    """Every wallpaper under `root`, as (path, collection), in collection then name order.

    A flat os.listdir was the other half of the folder being unconfigurable: even once
    you could point it somewhere, a wallpaper folder with any organisation in it showed
    up empty. Hidden directories are skipped — a wallpaper folder that happens to sit
    inside a git checkout should not index .git — and so is the poster cache, in case
    someone points wpDir at ~/.cache.
    """
    found = []
    root = os.path.abspath(root)
    for here, dirs, names in os.walk(root):
        rel = os.path.relpath(here, root)
        rel = "" if rel == "." else rel
        depth = 0 if not rel else rel.count(os.sep) + 1
        if depth >= MAX_DEPTH:
            dirs[:] = []
        else:
            dirs[:] = sorted((d for d in dirs
                              if not d.startswith(".")
                              and os.path.join(here, d) != THUMBS), key=str.lower)
        for name in sorted(names, key=str.lower):
            ext = os.path.splitext(name)[1].lower()
            if ext not in STILL and ext not in MOTION:
                continue
            found.append((os.path.join(here, name), rel))
    return found


def main():
    argv = sys.argv[1:]
    paths_only = "--paths" in argv
    stills_only = "--stills" in argv
    want_poster = "--poster" in argv
    want_full = "--fullposter" in argv
    positional = [a for a in argv if not a.startswith("--")]

    j = conf()

    # `--poster FILE` prints the still that stands in for a moving wallpaper, extracting
    # it if it is not cached yet. It exists so that the freeze path in
    # sea-wallpaper-apply.sh does not have to reimplement the poster naming scheme in
    # shell — which, with collections folded into the key, it would get wrong.
    if want_poster or want_full:
        if not positional:
            return 1
        target = os.path.abspath(positional[0])
        root = os.path.abspath(wallpaper_dir(j))
        rel = ""
        if target.startswith(root + os.sep):
            rel = os.path.dirname(os.path.relpath(target, root))
            rel = "" if rel == "." else rel
        if os.path.splitext(target)[1].lower() not in MOTION:
            print(target)                      # a still is its own poster
            return 0
        print(full_poster(target, rel) if want_full else poster(target, rel))
        return 0
    directory = positional[0] if positional else wallpaper_dir(j)
    if not j.get("wpRecursive", True):
        # Opting out still has to produce the same shape, so it is a depth-1 walk
        # rather than a second listing routine.
        entries = [(p, r) for p, r in walk(directory) if not r]
    else:
        entries = walk(directory)

    # `--paths` is what the cycle keybinds and the rotate daemon read. It must never
    # probe or extract: SUPER+N would otherwise pay for ffmpeg on a cold cache, and the
    # only thing a cycle needs to know is which files exist and in what order.
    if paths_only:
        for path, _rel in entries:
            if stills_only and os.path.splitext(path)[1].lower() in MOTION:
                continue
            print(path)
        return 0

    cache, fresh, keep = load_cache(), {}, set()
    for path, rel in entries:
        name = os.path.basename(path)
        ext = os.path.splitext(name)[1].lower()
        # A tab in a filename would split the row and desynchronise every column after
        # it. Rare enough to skip rather than escape, loud enough not to skip silently.
        if "\t" in path:
            print("skipped (tab in filename): %s" % name, file=sys.stderr)
            continue
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not st.st_size:
            continue

        key = (path, int(st.st_mtime), st.st_size)
        hit = cache.get(key)
        if hit is None:
            w, h, ms = probe(path)
            # ffprobe hands a still a duration too — a lone JPEG comes back as 40 ms of
            # single-frame "video". Only a moving wallpaper has a length worth reporting.
            hit = (w, h, poster(path, rel), ms) if ext in MOTION else (w, h, "", 0)
        fresh[key] = hit
        # The native-resolution still. Extracted in the same pass as the poster rather than on
        # demand: both are one ffmpeg call, the second one only happens once per file ever, and
        # the alternative is the picker pointing at a path that does not exist yet.
        full = full_poster(path, rel) if (ext in MOTION and hit[2]) else ""
        if hit[2]:
            keep.add(os.path.basename(hit[2]))
            # The freeze frame is not recorded in the index (nothing reads it from there),
            # so the sweep has to be told about it explicitly or it collects one every
            # fortnight and re-extracts it on the next fullscreen window.
            keep.add(full_name(path, rel))
        print("\t".join([path, str(key[2]), str(hit[0]), str(hit[1]),
                         hit[2], str(hit[3]), rel, str(key[1]), full]))

    save_cache(fresh)
    sweep(keep)
    return 0


if __name__ == "__main__":
    sys.exit(main())
