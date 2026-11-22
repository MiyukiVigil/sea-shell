#!/usr/bin/env python3
"""sea-shell — what is on the drives, how healthy they are, and clearing space.

  sea-disk.py info             one JSON object: health, temperature, wear, filesystem notes
  sea-disk.py scan             JSON lines, as each answer is ready: cleanable items, then the
                               home folder's breakdown and its biggest files
  sea-disk.py du PATH          one JSON object: what is inside a folder under home
  sea-disk.py clean ID...      JSON lines: how each item went, then what was really freed
  sea-disk.py clean-root ID... the same for the items that need root (run through pkexec)
  sea-disk.py trash PATH       move one file under home to the Trash

What can be deleted is decided here and only here. `clean` takes ids and works out the paths
itself, so nothing in the page can ever hand it a path to remove. The user's own files are
never deleted outright: they go to the Trash, and emptying it is a separate, visible choice.
"""
import heapq
import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.realpath(os.path.expanduser("~"))
CACHE = os.path.join(HOME, ".cache")
MB = 1024 ** 2
# Below this a row costs more attention than the space is worth.
MIN_ROW = 50 * MB
MIN_OTHER_CACHE = 200 * MB
MIN_BIG_FILE = 100 * MB
MIN_BUILD = 100 * MB
BIG_FILES = 8
FOLDER_ROWS = 12

# Folders a person never browses to. A file deep inside one is not theirs to throw away: one
# missing library breaks the whole environment, and the folder has its own row if it is big.
NOT_THEIR_FILES = {"node_modules", "__pycache__", "target", "venv", "site-packages", "vendor", "drive_c"}
# A folder only counts as a rebuildable build output if the file that rebuilds it sits next to
# it. A folder called `target` on its own could be anything.
BUILD_OUTPUTS = {
    "node_modules": ("package.json", "Node packages"),
    "target": ("Cargo.toml", "Rust build output"),
    ".venv": ("pyproject.toml", "Python environment"),
    "venv": ("requirements.txt", "Python environment"),
}
BUILD_OUTPUT_ALT_MARKERS = {".venv": ("requirements.txt", "uv.lock"), "venv": ("pyproject.toml",)}
# ~/.cache children that hold more than a cache: the clipboard history is the user's data, and
# the shell's own caches are rebuilt only at a visible cost the next time they are looked at.
KEEP_IN_CACHE = {"cliphist", "sea-shell", "sea-fm", "fontconfig", "fish", "thumbnails"}

# Paths are relative to home. Every row says what the deletion costs, because "safe" is not the
# whole story: a cleared download cache is safe, and then the next install takes twenty minutes.
USER_ITEMS = [
    {"id": "thumbnails", "title": "Picture previews", "tier": "safe", "icon": "image",
     "desc": "Files draws them again when you next open a folder.",
     "paths": [".cache/thumbnails"], "min": 5 * MB},
    {"id": "trash", "title": "Trash", "tier": "space", "icon": "delete",
     "desc": "Everything you already threw away. You can't get it back after this.",
     "paths": [".local/share/Trash/files", ".local/share/Trash/info", ".local/share/Trash/expunged"],
     "min": MB},
    {"id": "uv", "title": "Python packages (uv)", "tier": "space", "icon": "deployed_code",
     "desc": "Your environments keep working. New installs download again.",
     "paths": [".cache/uv"], "cmd": ["uv", "cache", "clean"], "tool": "uv"},
    {"id": "npm", "title": "Node packages (npm)", "tier": "space", "icon": "deployed_code",
     "desc": "Projects keep working. New installs download again.",
     "paths": [".npm/_cacache"], "cmd": ["npm", "cache", "clean", "--force"], "tool": "npm"},
    {"id": "cargo", "title": "Rust crates (cargo)", "tier": "space", "icon": "deployed_code",
     "desc": "Your next Rust build downloads what it needs again.",
     "paths": [".cargo/registry/cache", ".cargo/registry/src"]},
    {"id": "go", "title": "Go build cache", "tier": "space", "icon": "deployed_code",
     "desc": "Your next Go build takes longer.",
     "paths": [".cache/go-build"], "cmd": ["go", "clean", "-cache"], "tool": "go"},
    {"id": "pip", "title": "Python packages (pip)", "tier": "space", "icon": "deployed_code",
     "desc": "New installs download again.",
     "paths": [".cache/pip"]},
    {"id": "paru", "title": "AUR builds (paru)", "tier": "space", "icon": "deployed_code",
     "desc": "AUR updates download and build from scratch.",
     "paths": [".cache/paru"]},
    {"id": "models", "title": "Downloaded AI models", "tier": "space", "icon": "neurology",
     "desc": "Apps using them download them again, which can take a while. Your sign-in stays.",
     "paths": [".cache/huggingface/hub"]},
    {"id": "firefox", "title": "Firefox cache", "tier": "space", "icon": "public",
     "desc": "Sites load a little slower at first. Logins and history stay.",
     "paths": [".cache/mozilla"], "busy": ["firefox", "firefox-bin"], "busyName": "Firefox"},
    {"id": "zen", "title": "Zen cache", "tier": "space", "icon": "public",
     "desc": "Sites load a little slower at first. Logins and history stay.",
     "paths": [".cache/zen"], "busy": ["zen", "zen-bin"], "busyName": "Zen"},
    {"id": "chrome", "title": "Chrome cache", "tier": "space", "icon": "public",
     "desc": "Sites load a little slower at first. Logins and history stay.",
     "paths": [".cache/google-chrome"], "busy": ["chrome"], "busyName": "Chrome"},
    {"id": "chromium", "title": "Chromium cache", "tier": "space", "icon": "public",
     "desc": "Sites load a little slower at first. Logins and history stay.",
     "paths": [".cache/chromium"], "busy": ["chromium"], "busyName": "Chromium"},
    {"id": "brave", "title": "Brave cache", "tier": "space", "icon": "public",
     "desc": "Sites load a little slower at first. Logins and history stay.",
     "paths": [".cache/BraveSoftware"], "busy": ["brave"], "busyName": "Brave"},
    {"id": "gl", "title": "Graphics shaders", "tier": "space", "icon": "memory",
     "desc": "Games and apps may stutter briefly while these build again.",
     "paths": [".cache/mesa_shader_cache", ".cache/mesa_shader_cache_db", ".cache/nvidia"]},
    {"id": "steam", "title": "Steam game shaders", "tier": "space", "icon": "sports_esports",
     "desc": "Games may stutter or recompile shaders the next time they start.",
     "paths": [".local/share/Steam/steamapps/shadercache"],
     "busy": ["steam"], "busyName": "Steam"},
]
CLAIMED_IN_CACHE = {p.split("/")[1] for i in USER_ITEMS for p in i["paths"] if p.startswith(".cache/")}

# The only things ever run as root. Fixed argv lists: nothing from the command line reaches them
# except package names, and those are checked against pacman's own orphan list first.
ROOT_ITEMS = {
    "pkg-old": [["paccache", "-rk2"], ["paccache", "-ruk0"]],
    "pkg-rollback": [["paccache", "-rk1"]],
    "journal": [["journalctl", "--vacuum-time=14d"]],
}


def human(n):
    n = float(max(0, n))
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return ("%.0f %s" if unit in ("B", "KB") or n >= 100 else "%.1f %s") % (n, unit)
        n /= 1024
    return "%.1f TB" % n


def age(ts):
    days = max(0, (time.time() - ts) / 86400)
    if days < 1:
        return "today"
    if days < 2:
        return "yesterday"
    if days < 60:
        return "%d days ago" % days
    if days < 730:
        return "%d months ago" % (days / 30)
    return "%d years ago" % (days / 365)


def emit(**row):
    print(json.dumps(row), flush=True)


def output(argv, timeout=8):
    """A command's stdout, or "" if it is missing, fails or hangs. Daemons and tools come and go."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, "LC_ALL": "C"})
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def measure(path):
    """Bytes deleting this tree would really free.

    Plain `du` answers a different question. A hard link whose other name lives outside the tree
    (uv and pnpm link their caches into every environment) frees nothing when this name goes, so
    such a file only counts if all its links are in here.
    """
    total, links, stack = 0, {}, [path]
    while stack:
        try:
            entries = os.scandir(stack.pop())
        except OSError:
            continue
        with entries:
            for e in entries:
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                        continue
                    s = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if s.st_nlink <= 1:
                    total += s.st_blocks * 512
                else:
                    k = (s.st_dev, s.st_ino)
                    links.setdefault(k, [0, s.st_nlink, s.st_blocks * 512])[0] += 1
    return total + sum(b for seen, nlink, b in links.values() if seen >= nlink)


def running_names():
    names = set()
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                with open("/proc/%s/comm" % pid) as f:
                    names.add(f.read().strip())
            except OSError:
                pass
    return names


def in_home(path):
    """The real path if it is strictly inside home and reached without a symlink, else None."""
    if not os.path.isabs(path) or os.path.islink(path):
        return None
    real = os.path.realpath(path)
    return real if real.startswith(HOME + os.sep) else None


def other_cache_dirs():
    """Big ~/.cache children no named row covers. XDG says these are safe to lose; the list is
    still live, not hard-coded, because every machine grows different ones."""
    found = []
    try:
        entries = list(os.scandir(CACHE))
    except OSError:
        return found
    for e in entries:
        if e.name not in KEEP_IN_CACHE and e.name not in CLAIMED_IN_CACHE \
                and e.is_dir(follow_symlinks=False):
            found.append(e.name)
    return found


def build_output_item(path):
    """Row for a rebuildable folder, or None if this path is not one. Used for both the scan and
    the clean, so a path that stops qualifying between the two is refused."""
    real = in_home(path)
    if not real or not os.path.isdir(real):
        return None
    name, parent = os.path.basename(real), os.path.dirname(real)
    if name not in BUILD_OUTPUTS:
        return None
    marker, kind = BUILD_OUTPUTS[name]
    markers = (marker,) + BUILD_OUTPUT_ALT_MARKERS.get(name, ())
    if not any(os.path.exists(os.path.join(parent, m)) for m in markers):
        return None
    # A hidden parent means an app's own data (an extension, a runtime), not one of your projects.
    if any(part.startswith(".") for part in os.path.relpath(parent, HOME).split(os.sep)):
        return None
    return {"id": "build:" + real, "title": os.path.relpath(real, HOME), "tier": "space",
            "icon": "folder_code", "paths": [real], "kind": kind}


def paccache_estimate(*flags):
    m = re.search(r"disk space saved: ([\d.]+) (\w+)", output(["paccache", "-d", *flags], 30))
    if not m:
        return 0
    scale = {"B": 1, "KiB": 1024, "MiB": MB, "GiB": 1024 ** 3}.get(m.group(2), 0)
    return int(float(m.group(1)) * scale)


def package_rows():
    if not shutil.which("paccache"):
        return []
    keep2 = paccache_estimate("-k2") + paccache_estimate("-uk0")
    keep1 = paccache_estimate("-k1")
    return [
        {"id": "pkg-old", "title": "Old package downloads", "tier": "safe", "icon": "inventory_2",
         "desc": "Keeps the current version of each package and one before it.",
         "bytes": keep2, "admin": True},
        {"id": "pkg-rollback", "title": "Package rollback copies", "tier": "space",
         "icon": "inventory_2",
         "desc": "Keeps only the current version, so a bad update can't be undone from here.",
         "bytes": max(0, keep1 - keep2), "admin": True},
    ]


def orphan_names():
    return output(["pacman", "-Qdtq"]).split()


def orphan_row():
    names = orphan_names()
    if not names:
        return []
    bytes_, scale = 0, {"KiB": 1024, "MiB": MB, "GiB": 1024 ** 3, "B": 1}
    for m in re.finditer(r"Installed Size\s*:\s*([\d.]+) (\w+)", output(["pacman", "-Qi", *names])):
        bytes_ += int(float(m.group(1)) * scale.get(m.group(2), 0))
    return [{"id": "orphans:" + ",".join(names), "title": "Unused packages", "tier": "space",
             "icon": "extension_off", "admin": True, "bytes": bytes_, "min": MB,
             "desc": "Nothing depends on these, but you may use them directly: " + ", ".join(names) + "."}]


def journal_row():
    m = re.search(r"take up ([\d.]+)([KMGT])", output(["journalctl", "--disk-usage"]))
    if not m:
        return []
    bytes_ = int(float(m.group(1)) * 1024 ** "BKMGT".index(m.group(2)))
    return [{"id": "journal", "title": "System logs", "tier": "safe", "icon": "receipt_long",
             "desc": "Keeps the last two weeks.", "bytes": bytes_, "admin": True, "min": 100 * MB}]


def docker_size(text):
    m = re.match(r"([\d.]+)\s*([kMGT]?)B", text or "", re.I)
    return int(float(m.group(1)) * 1000 ** " KMGT".index(m.group(2).upper() or " ")) if m else 0


def docker_row():
    """Build cache and untagged images only. Stopped containers and volumes stay out of this for
    good: a stopped container may be somebody's database, and a volume certainly is."""
    if not shutil.which("docker"):
        return []
    usage = output(["docker", "system", "df", "--format", "{{json .}}"])
    bytes_ = 0
    for line in usage.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("Type") == "Build Cache":
            bytes_ += docker_size(row.get("Reclaimable"))
    for size in output(["docker", "images", "-f", "dangling=true", "--format", "{{.Size}}"]).split():
        bytes_ += docker_size(size)
    return [{"id": "docker", "title": "Docker build leftovers", "tier": "space", "icon": "deployed_code",
             "desc": "Your images, containers and their data all stay. The next build runs slower.",
             "bytes": bytes_}]


def user_item_row(item, running):
    if item.get("tool") and not shutil.which(item["tool"]):
        return None
    bytes_ = sum(measure(os.path.join(HOME, p)) for p in item["paths"]
                 if not os.path.islink(os.path.join(HOME, p)))
    row = {k: item[k] for k in ("id", "title", "tier", "icon", "desc") if k in item}
    row.update(bytes=bytes_, min=item.get("min", MIN_ROW))
    if running & set(item.get("busy", ())):
        row["busy"] = "Close %s first." % item["busyName"]
    return row


def emit_item(row):
    if row["bytes"] >= row.pop("min", MIN_ROW):
        row["size"] = human(row["bytes"])
        emit(kind="item", **row)


def walk_home():
    """One pass over home for every slow question: the size of each top-level entry, the biggest
    files you could plausibly mean to delete, and the rebuildable project folders."""
    sizes, biggest, builds, links = [], [], [], {}

    def tree(root, visible):
        total, stack = 0, [(root, visible)]
        while stack:
            d, vis = stack.pop()
            try:
                entries = os.scandir(d)
            except OSError:
                continue
            with entries:
                for e in entries:
                    try:
                        if e.is_symlink():
                            continue
                        s = e.stat(follow_symlinks=False)
                        if e.is_dir(follow_symlinks=False):
                            # Another filesystem or subvolume has its own row, or none.
                            if s.st_dev != home_dev:
                                continue
                            if vis and e.name in BUILD_OUTPUTS and build_output_item(e.path):
                                builds.append(e.path)
                            stack.append((e.path, vis and not e.name.startswith(".")
                                          and e.name not in NOT_THEIR_FILES))
                            continue
                    except OSError:
                        continue
                    b = s.st_blocks * 512
                    if s.st_nlink > 1:
                        k = (s.st_dev, s.st_ino)
                        if k in links:
                            continue
                        links[k] = True
                    total += b
                    if vis and b >= MIN_BIG_FILE and not e.name.startswith("."):
                        heapq.heappush(biggest, (b, e.path, s.st_mtime))
                        if len(biggest) > BIG_FILES:
                            heapq.heappop(biggest)
        return total

    home_dev = os.stat(HOME).st_dev
    top_files = 0
    with os.scandir(HOME) as entries:
        for e in list(entries):
            try:
                if e.is_symlink():
                    continue
                vis = not e.name.startswith(".")
                if e.is_dir(follow_symlinks=False):
                    if e.stat(follow_symlinks=False).st_dev == home_dev:
                        sizes.append((tree(e.path, vis), e.name, e.path))
                else:
                    s = e.stat(follow_symlinks=False)
                    top_files += s.st_blocks * 512
                    if vis and s.st_blocks * 512 >= MIN_BIG_FILE:
                        heapq.heappush(biggest, (s.st_blocks * 512, e.path, s.st_mtime))
                        if len(biggest) > BIG_FILES:
                            heapq.heappop(biggest)
            except OSError:
                continue
    return sizes, top_files, sorted(biggest, reverse=True), builds


def folder_payload(path, rows, loose=0):
    rows = sorted(rows, reverse=True)
    total = sum(r[0] for r in rows) + loose
    shown = [{"name": name, "path": p, "bytes": b, "size": human(b), "isDir": isdir,
              "pct": round(100 * b / total, 1) if total else 0}
             for b, name, p, isdir in rows[:FOLDER_ROWS]]
    rest = total - sum(r["bytes"] for r in shown)
    if rest >= MB:
        shown.append({"name": "Everything else", "path": "", "bytes": rest, "size": human(rest),
                      "isDir": False, "pct": round(100 * rest / total, 1) if total else 0})
    return {"kind": "folder", "path": path, "total": total, "totalSize": human(total), "rows": shown}


def cmd_scan():
    os.nice(10)
    running = running_names()
    for row in package_rows() + journal_row() + docker_row() + orphan_row():
        emit_item(row)
    for item in USER_ITEMS:
        row = user_item_row(item, running)
        if row:
            emit_item(row)
    for name in other_cache_dirs():
        bytes_ = measure(os.path.join(CACHE, name))
        if bytes_ >= MIN_OTHER_CACHE:
            emit_item({"id": "cache:" + name, "title": name + " cache", "tier": "space",
                       "icon": "folder_zip", "bytes": bytes_, "min": MIN_OTHER_CACHE,
                       "desc": "Kept by an app, which should make it again. Close that app first."})
    sizes, top_files, biggest, builds = walk_home()
    for path in builds:
        item = build_output_item(path)
        if item:
            bytes_ = measure(path)
            if bytes_ >= MIN_BUILD:
                try:
                    changed = age(os.stat(path).st_mtime)
                except OSError:
                    changed = "a while ago"
                emit_item({**{k: item[k] for k in ("id", "title", "tier", "icon")},
                           "bytes": bytes_, "min": MIN_BUILD,
                           "desc": "%s, changed %s. The project needs a rebuild or install to run again."
                                   % (item["kind"], changed)})
    emit(**folder_payload(HOME, [(b, n, p, True) for b, n, p in sizes], top_files))
    for b, path, mtime in biggest:
        emit(kind="file", path=path, name=os.path.basename(path),
             where=os.path.dirname(os.path.relpath(path, HOME)) or "Home",
             bytes=b, size=human(b), age=age(mtime))
    emit(kind="done")


def cmd_du(path):
    real = HOME if os.path.realpath(path) == HOME else in_home(path)
    if not real or not os.path.isdir(real):
        emit(kind="folder", path=path, total=0, totalSize="0 B", rows=[], error="Can't look inside that.")
        return
    dev, rows = os.stat(real).st_dev, []
    with os.scandir(real) as entries:
        for e in list(entries):
            try:
                if e.is_symlink():
                    continue
                s = e.stat(follow_symlinks=False)
                if e.is_dir(follow_symlinks=False):
                    if s.st_dev == dev:
                        rows.append((measure(e.path), e.name, e.path, True))
                else:
                    rows.append((s.st_blocks * 512, e.name, e.path, False))
            except OSError:
                continue
    emit(**folder_payload(real, rows))


def clear_dir(path):
    """Empty a folder but keep it: apps often assume their cache folder exists. Symlinks are
    removed, never followed. Returns True if nothing is left."""
    if os.path.islink(path) or not os.path.isdir(path):
        return True
    with os.scandir(path) as entries:
        for e in list(entries):
            try:
                if e.is_dir(follow_symlinks=False):
                    shutil.rmtree(e.path, ignore_errors=True)
                else:
                    os.unlink(e.path)
            except OSError:
                pass
    try:
        return not os.listdir(path)
    except OSError:
        return False


def resolve_user_item(item_id):
    """id -> what to delete, or None. The only door from an id to a path."""
    for item in USER_ITEMS:
        if item["id"] == item_id:
            return item
    if item_id.startswith("cache:"):
        name = item_id[6:]
        if name in other_cache_dirs():
            return {"id": item_id, "paths": [os.path.join(".cache", name)]}
    if item_id.startswith("build:"):
        item = build_output_item(item_id[6:])
        if item:
            return {"id": item_id, "paths": item["paths"], "wholeDir": True}
    return None


def clean_user_item(item_id, running):
    if item_id == "docker":
        ok = bool(output(["docker", "builder", "prune", "-f"], 600))
        output(["docker", "image", "prune", "-f"], 600)
        return ("done", "") if ok else ("failed", "Docker didn't answer. Is it running?")
    item = resolve_user_item(item_id)
    if not item:
        return "failed", "Not something this page can clear."
    if running & set(item.get("busy", ())):
        return "skipped", "Close %s first." % item["busyName"]
    if item.get("cmd"):
        if item.get("tool") and not shutil.which(item["tool"]):
            return "failed", "%s isn't installed." % item["tool"]
        try:
            r = subprocess.run(item["cmd"], capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as e:
            return "failed", str(e)
        if r.returncode != 0:
            return "failed", (r.stderr.strip().splitlines() or ["It stopped with an error."])[-1]
        return "done", ""
    complete = True
    for rel in item["paths"]:
        path = os.path.join(HOME, rel)
        if item.get("wholeDir"):
            shutil.rmtree(path, ignore_errors=True)
            complete = complete and not os.path.exists(path)
        else:
            complete = clear_dir(path) and complete
    return ("done", "") if complete else ("partial", "Some files were in use and stayed.")


def free_bytes():
    """Free space across home and root, counted once if they share a filesystem. The device is
    the only safe key: btrfs gives every subvolume its own st_dev and f_fsid, so those would
    count one drive twice and report twice what was freed."""
    seen, total = set(), 0
    for path in (HOME, "/"):
        source = output(["findmnt", "-n", "-o", "SOURCE", "--target", path]).strip().split("[")[0]
        if source not in seen or not source:
            seen.add(source)
            s = os.statvfs(path)
            total += s.f_bavail * s.f_frsize
    return total


def root_commands(item_id):
    """The argv lists for one root item, or None if it is not on the list."""
    if item_id in ROOT_ITEMS:
        return ROOT_ITEMS[item_id]
    if item_id.startswith("orphans:"):
        wanted, orphans = item_id[8:].split(","), orphan_names()
        if all(n in orphans for n in wanted):
            return [["pacman", "-Rns", "--noconfirm", *wanted]]
    return None


def is_root_item(item_id):
    return item_id in ROOT_ITEMS or item_id.startswith("orphans:")


def cmd_clean_root(ids):
    for item_id in ids:
        commands = root_commands(item_id)
        if commands is None:
            emit(kind="progress", id=item_id, state="failed", note="Not something this page can clear.")
            continue
        state, note = "done", ""
        for argv in commands:
            try:
                r = subprocess.run(argv, capture_output=True, text=True, timeout=900)
            except (OSError, subprocess.SubprocessError) as e:
                state, note = "failed", str(e)
                break
            if r.returncode != 0:
                state = "failed"
                note = ((r.stderr or r.stdout).strip().splitlines() or ["It stopped with an error."])[-1]
                break
        emit(kind="progress", id=item_id, state=state, note=note)


def cmd_clean(ids):
    user_ids = [i for i in ids if not is_root_item(i)]
    root_ids = [i for i in ids if is_root_item(i)]
    os.sync()
    before = free_bytes()
    running = running_names()
    for item_id in user_ids:
        emit(kind="progress", id=item_id, state="working", note="")
        state, note = clean_user_item(item_id, running)
        emit(kind="progress", id=item_id, state=state, note=note)
    # Root goes last so a dismissed password dialog costs only the rows that needed it. One pkexec
    # for the whole batch: one question, however many items were ticked.
    if root_ids:
        for item_id in root_ids:
            emit(kind="progress", id=item_id, state="working", note="")
        reported = set()
        try:
            p = subprocess.Popen(["pkexec", sys.executable, os.path.abspath(__file__), "clean-root", *root_ids],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            for line in p.stdout:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                reported.add(row.get("id"))
                print(line.strip(), flush=True)
            cancelled = p.wait() in (126, 127)
        except OSError:
            cancelled = True
        for item_id in root_ids:
            if item_id not in reported:
                emit(kind="progress", id=item_id, state="skipped",
                     note="Needs your password, so it was left alone." if cancelled else "It stopped without finishing.")
    # What the filesystem now says, not a sum of estimates: compression and shared data make the
    # estimates a ceiling. The sync makes btrfs commit, or the space would still look taken.
    os.sync()
    freed = max(0, free_bytes() - before)
    emit(kind="result", freed=freed, size=human(freed))


def cmd_trash(path):
    real = in_home(path)
    if not real or not os.path.isfile(real):
        emit(kind="trash", path=path, ok=False, note="That file is gone or isn't in your home folder.")
        return
    r = subprocess.run(["gio", "trash", "--", real], capture_output=True, text=True)
    emit(kind="trash", path=path, ok=r.returncode == 0,
         note="" if r.returncode == 0 else (r.stderr.strip() or "Couldn't move it to the Trash."))


# ---------- health ----------

def busctl(*args):
    out = output(["busctl", "--json=short", "--allow-interactive-authorization=no", *args], 4)
    try:
        return json.loads(out)
    except ValueError:
        return None


def udisks_drive_path(dev):
    m = re.search(r"Drive:\s+'(/org/freedesktop/UDisks2/drives/[^']+)'",
                  output(["udisksctl", "info", "-b", "/dev/" + dev], 4))
    return m.group(1) if m and not m.group(1).endswith("/") else None


def prop(drive, iface, name):
    r = busctl("get-property", "org.freedesktop.UDisks2", drive, "org.freedesktop.UDisks2." + iface, name)
    return r.get("data") if isinstance(r, dict) else None


def sensor_temp(dev):
    base = "/sys/block/%s/device" % dev
    try:
        for name in os.listdir(base):
            if name.startswith("hwmon"):
                with open(os.path.join(base, name, "temp1_input")) as f:
                    return round(int(f.read()) / 1000)
    except (OSError, ValueError):
        pass
    return None


def boot_io(dev):
    try:
        with open("/sys/block/%s/stat" % dev) as f:
            fields = f.read().split()
        return int(fields[2]) * 512, int(fields[6]) * 512
    except (OSError, ValueError, IndexError):
        return None, None


def drive_health(dev):
    """Everything here comes from udisks, which reads SMART as root on our behalf, so seeing your
    own drive's health never needs a password. Any field the drive doesn't report is just absent."""
    h = {"status": "unknown"}
    temp = sensor_temp(dev)
    drive = udisks_drive_path(dev)
    if drive and dev.startswith("nvme"):
        warnings = prop(drive, "NVMe.Controller", "SmartCriticalWarning")
        hours = prop(drive, "NVMe.Controller", "SmartPowerOnHours")
        kelvin = prop(drive, "NVMe.Controller", "SmartTemperature")
        if temp is None and kelvin:
            temp = round(kelvin - 273.15)
        if hours:
            h["hours"] = hours
        r = busctl("call", "org.freedesktop.UDisks2", drive, "org.freedesktop.UDisks2.NVMe.Controller",
                   "SmartGetAttributes", "a{sv}", "0")
        attrs = {}
        if isinstance(r, dict) and r.get("data"):
            attrs = {k: v.get("data") for k, v in r["data"][0].items()}
        if "percent_used" in attrs:
            h["wear"] = attrs["percent_used"]
        if attrs.get("total_data_written") is not None:
            h["written"] = human(attrs["total_data_written"])
        if attrs.get("total_data_read") is not None:
            h["read"] = human(attrs["total_data_read"])
        if attrs.get("unsafe_shutdowns") is not None:
            h["unsafe"] = attrs["unsafe_shutdowns"]
        errors = attrs.get("media_errors") or 0
        h["errors"] = errors
        spare_low = attrs.get("avail_spare", 100) <= attrs.get("spare_thresh", 0)
        if warnings is not None or attrs:
            h["status"] = "bad" if warnings or spare_low else \
                          "warn" if errors or attrs.get("percent_used", 0) >= 90 else "good"
    elif drive and prop(drive, "Drive.Ata", "SmartEnabled"):
        seconds = prop(drive, "Drive.Ata", "SmartPowerOnSeconds")
        kelvin = prop(drive, "Drive.Ata", "SmartTemperature")
        bad = prop(drive, "Drive.Ata", "SmartNumBadSectors") or 0
        if temp is None and kelvin:
            temp = round(kelvin - 273.15)
        if seconds:
            h["hours"] = seconds // 3600
        h["errors"] = bad
        h["status"] = "bad" if prop(drive, "Drive.Ata", "SmartFailing") else "warn" if bad else "good"
    if temp is not None:
        h["temp"] = temp
    read, written = boot_io(dev)
    if read is not None:
        h["bootRead"], h["bootWritten"] = human(read), human(written)
    return h


def filesystem_notes():
    """device -> plain words for how its filesystem is set up. Subvolumes share one set of options."""
    notes = {}
    try:
        mounts = json.loads(output(["findmnt", "-J", "-n", "-l", "-o", "SOURCE,FSTYPE,OPTIONS"])).get("filesystems", [])
    except ValueError:
        return notes
    for m in mounts:
        src = (m.get("source") or "").split("[")[0]
        if not src.startswith("/dev/") or src in notes:
            continue
        opts = (m.get("options") or "").split(",")
        words = [m.get("fstype") or ""]
        for o in opts:
            if o.startswith("compress"):
                words.append(o.split("=")[-1].split(":")[0] + " compression")
            if o.startswith("discard"):
                words.append("TRIM on")
        notes[src.replace("/dev/", "")] = ", ".join(w for w in words if w)
    return notes


def cmd_info():
    drives = {}
    for dev in sorted(os.listdir("/sys/block")):
        if not dev.startswith(("loop", "zram", "ram", "sr", "dm-")):
            drives[dev] = drive_health(dev)
            try:
                with open("/sys/block/%s/queue/rotational" % dev) as f:
                    drives[dev]["kind"] = "Hard disk" if f.read().strip() == "1" else "SSD"
            except OSError:
                pass
    print(json.dumps({"drives": drives, "fs": filesystem_notes()}), flush=True)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    command, rest = args[0], args[1:]
    if command == "info":
        cmd_info()
    elif command == "scan":
        cmd_scan()
    elif command == "du" and len(rest) == 1:
        cmd_du(rest[0])
    elif command == "clean":
        cmd_clean(rest)
    elif command == "clean-root":
        cmd_clean_root(rest)
    elif command == "trash" and len(rest) == 1:
        cmd_trash(rest[0])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
