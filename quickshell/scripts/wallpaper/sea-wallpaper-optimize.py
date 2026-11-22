#!/usr/bin/env python3
"""sea-shell — the copy of a video wallpaper that is actually played.

    sea-wallpaper-optimize.py CLIP --size WxH --fps N            resolve (instant)
    sea-wallpaper-optimize.py CLIP --size WxH --fps N --build    encode, then print the copy

Wallpaper clips are made for the biggest screen anyone owns: 2560x1440 or 4K at 60fps, with
an audio track, at 16 Mbit/s. On a 1080p panel every frame was decoded at nearly twice the
pixels shown and then half of them were thrown away to reach 30fps. Encoding once, to the
panel's size and the frame cap, makes every later second of playback cheaper.

Resolve prints the path to play on the first line — the cached copy if there is one, else
the original — and "pending" on the second line when an encode would help. The bar plays
the original straight away and runs --build behind it, so a new clip is never waited on.

The original is never touched. Copies live in ~/.cache/sea-shell/wallvideo, keyed on the
clip's path, mtime and size, plus the target, and the least recently played are evicted past
CACHE_CAP bytes.
"""
import fcntl
import glob
import hashlib
import json
import os
import subprocess
import sys

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
                     "sea-shell", "wallvideo")
CACHE_CAP = 2 * 1024 ** 3


def probe(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height,avg_frame_rate,codec_name",
             "-show_entries", "format=nb_streams", "-of", "json", path],
            capture_output=True, text=True, timeout=20).stdout
        j = json.loads(out or "{}")
        s = (j.get("streams") or [{}])[0]
        num, _, den = (s.get("avg_frame_rate") or "0/1").partition("/")
        fps = float(num) / float(den or 1) if float(den or 1) else 0.0
        return {"w": int(s.get("width") or 0), "h": int(s.get("height") or 0), "fps": fps,
                "codec": s.get("codec_name") or "",
                "streams": int((j.get("format") or {}).get("nb_streams") or 1)}
    except Exception:
        return None


def cache_path(src, w, h, fps):
    st = os.stat(src)
    key = hashlib.sha1(f"{os.path.abspath(src)}\0{st.st_mtime_ns}\0{st.st_size}".encode()).hexdigest()[:16]
    return os.path.join(CACHE, f"{key}-{w}x{h}-{fps}.mp4")


def needs_encode(info, w, h, fps):
    """Already no bigger and no faster than the target, H.264, video only: play it as it is."""
    if not info or not info["w"]:
        return False
    if info["w"] * info["h"] > w * h * 1.05:
        return True
    if info["fps"] > fps + 0.5:
        return True
    return info["codec"] not in ("h264",) or info["streams"] > 1


def vaapi_node():
    """The render node of the GPU the compositor draws on — the same choice the bar makes."""
    card = ""
    aq = os.environ.get("AQ_DRM_DEVICES", "")
    if aq:
        card = os.path.basename(os.path.realpath(aq.split(":")[0]))
    else:
        for c in sorted(glob.glob("/sys/class/drm/card[0-9]*")):
            try:
                if open(os.path.join(c, "device", "boot_vga")).read().strip() == "1":
                    card = os.path.basename(c)
                    break
            except OSError:
                pass
    if not card:
        return ""
    try:
        drv = os.path.basename(os.readlink(f"/sys/class/drm/{card}/device/driver"))
        if drv == "nvidia":
            return ""
        nodes = sorted(n for n in os.listdir(f"/sys/class/drm/{card}/device/drm") if n.startswith("renderD"))
        return f"/dev/dri/{nodes[0]}" if nodes else ""
    except OSError:
        return ""


def encode(src, dst, w, h, fps):
    # Scale to COVER the panel and crop the overflow — the same framing the player's
    # PreserveAspectCrop would give, decided once here instead of every frame there.
    cover = (f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},fps={fps}")
    tmp = dst + ".part"
    base = ["ffmpeg", "-y", "-v", "error", "-nostdin"]
    tail = ["-an", "-movflags", "+faststart", "-f", "mp4", tmp]
    node = vaapi_node()
    tries = []
    if node:
        tries.append(base + ["-vaapi_device", node, "-i", src,
                             "-vf", cover + ",format=nv12,hwupload",
                             "-c:v", "h264_vaapi", "-qp", "22", "-g", str(fps * 2)] + tail)
    tries.append(base + ["-i", src, "-vf", cover, "-c:v", "libx264", "-preset", "veryfast",
                         "-crf", "22", "-pix_fmt", "yuv420p", "-g", str(fps * 2)] + tail)
    for cmd in tries:
        try:
            if subprocess.run(cmd, timeout=1800).returncode == 0 and os.path.getsize(tmp) > 0:
                os.replace(tmp, dst)
                return True
        except Exception:
            pass
    try:
        os.remove(tmp)
    except OSError:
        pass
    return False


def evict(keep):
    files = glob.glob(os.path.join(CACHE, "*.mp4"))
    files.sort(key=lambda f: os.stat(f).st_mtime, reverse=True)
    total = 0
    for f in files:
        total += os.path.getsize(f)
        if total > CACHE_CAP and f != keep:
            try:
                os.remove(f)
            except OSError:
                pass


def main(argv):
    args, opts = [], {}
    it = iter(argv)
    for a in it:
        if a in ("--size", "--fps"):
            opts[a] = next(it, "")
        elif not a.startswith("--"):
            args.append(a)
    build = "--build" in argv
    if not args or not os.path.isfile(args[0]):
        return 1
    src = os.path.abspath(args[0])
    try:
        w, h = (int(x) for x in opts.get("--size", "1920x1080").lower().split("x"))
        fps = max(1, min(240, int(opts.get("--fps", "30"))))
    except ValueError:
        return 2

    dst = cache_path(src, w, h, fps)
    if os.path.isfile(dst):
        os.utime(dst)                       # atime may be noatime-mounted; mtime marks use
        print(dst)
        return 0
    info = probe(src)
    if not needs_encode(info, w, h, fps):
        print(src)
        return 0
    if not build:
        print(src)
        print("pending")
        return 0

    os.makedirs(CACHE, exist_ok=True)
    # One encoder per target: a second request (another monitor, a quick re-pick) waits for
    # the first and then finds the finished copy instead of encoding it twice.
    with open(dst + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        if not os.path.isfile(dst) and not encode(src, dst, w, h, fps):
            print(src)
            return 0
    try:
        os.remove(dst + ".lock")
    except OSError:
        pass
    evict(dst)
    print(dst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
