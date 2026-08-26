#!/usr/bin/env python3
"""sea-shell — which application opens what.

    sea-defaults.py --get                     every role and what currently answers it
    sea-defaults.py --list <role>             the installed applications that could
    sea-defaults.py --set <role> <entry.desktop>
    sea-defaults.py --terminal-argv [cwd]     the chosen terminal, ready to exec

THERE ARE TWO REGISTRIES HERE AND ONLY ONE OF THEM IS A STANDARD.

Everything a file has a type for — a web page, a folder, a PDF — is answered by
the freedesktop MIME machinery: associations live in mimeapps.list and are read
by every toolkit on the machine, so setting one here changes what Firefox's
"open containing folder" does as much as what this shell does. That is written
through `xdg-mime`, which knows the file's precedence rules, rather than by
editing it and hoping.

A TERMINAL IS NOT A MIME TYPE. Nothing in the spec says which terminal is yours;
every desktop invented its own answer (GNOME has a GSetting, KDE has a config
key, and most window managers have an environment variable). So that one is kept
in sea-shell's own defaults.json, and the scripts that open a terminal ask here
first and fall back to whatever is installed — which is what they did before.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "sea-shell"
DEFAULTS_FILE = CONFIG_DIR / "defaults.json"

# The roles the shell offers, the MIME types each one owns, and how to describe
# it. A role with no mimes is one the standard has no opinion about.
ROLES = {
    "browser": {
        "label": "Web browser",
        "icon": "public",
        "mimes": ["x-scheme-handler/http", "x-scheme-handler/https", "text/html"],
        "note": "Links, and anything that opens one.",
    },
    "filemanager": {
        "label": "File manager",
        "icon": "folder",
        "mimes": ["inode/directory"],
        "note": "Folders, and “show in files” from other applications.",
    },
    "terminal": {
        "label": "Terminal",
        "icon": "terminal",
        "mimes": [],
        "categories": ["TerminalEmulator"],
        "note": "“Open in terminal”, and the shell's own command actions.",
    },
    "editor": {
        "label": "Text editor",
        "icon": "edit_note",
        "mimes": ["text/plain"],
        "note": "Plain text and source files.",
    },
    "image": {
        "label": "Images",
        "icon": "image",
        "mimes": ["image/png", "image/jpeg", "image/webp", "image/gif"],
        "note": "",
    },
    "video": {
        "label": "Video",
        "icon": "movie",
        "mimes": ["video/mp4", "video/x-matroska", "video/webm"],
        "note": "",
    },
    "audio": {
        "label": "Music",
        "icon": "music_note",
        "mimes": ["audio/mpeg", "audio/flac", "audio/x-vorbis+ogg", "audio/x-wav"],
        "note": "",
    },
    "pdf": {
        "label": "Documents",
        "icon": "picture_as_pdf",
        "mimes": ["application/pdf"],
        "note": "",
    },
}

ROLE_ORDER = ["browser", "filemanager", "terminal", "editor",
              "image", "video", "audio", "pdf"]


# ---------------------------------------------------------------------------
# desktop entries
# ---------------------------------------------------------------------------

def _app_dirs():
    dirs = [Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")]
    raw = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    dirs += [Path(d) for d in raw.split(":") if d]
    return [d / "applications" for d in dirs]


def _parse_entry(path):
    """The [Desktop Entry] group only. Later groups are actions, not the app."""
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            in_main = False
            for line in fh:
                line = line.strip()
                if line.startswith("["):
                    in_main = line == "[Desktop Entry]"
                    continue
                if not in_main or "=" not in line or line.startswith("#"):
                    continue
                k, v = line.split("=", 1)
                # Localised keys (Name[de]) are ignored: the shell is English and
                # taking whichever happened to be last would be worse than that.
                if "[" not in k:
                    data[k.strip()] = v.strip()
    except OSError:
        return None
    if data.get("Type", "Application") != "Application":
        return None
    if data.get("NoDisplay", "").lower() == "true":
        return None
    if data.get("Hidden", "").lower() == "true":
        return None
    if not data.get("Name") or not data.get("Exec"):
        return None
    return data


def all_entries():
    """id -> parsed entry, earlier directories winning, as the spec requires."""
    found = {}
    for base in _app_dirs():
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*.desktop")):
            try:
                ident = str(f.relative_to(base)).replace("/", "-")
            except ValueError:
                ident = f.name
            if ident in found:
                continue
            ent = _parse_entry(f)
            if ent:
                ent["_id"] = ident
                ent["_path"] = str(f)
                found[ident] = ent
    return found


def _split_list(v):
    return [x for x in (v or "").split(";") if x]


def candidates(role):
    """Applications that say they can do this job."""
    spec = ROLES.get(role)
    if not spec:
        return []
    want_mimes = set(spec.get("mimes") or [])
    want_cats = set(spec.get("categories") or [])
    out = []
    for ent in all_entries().values():
        mimes = set(_split_list(ent.get("MimeType")))
        cats = set(_split_list(ent.get("Categories")))
        if (want_mimes and mimes & want_mimes) or (want_cats and cats & want_cats):
            out.append({
                "id": ent["_id"],
                "name": ent.get("Name", ent["_id"]),
                "icon": ent.get("Icon", ""),
                "comment": ent.get("Comment", ""),
            })
    # A terminal that declares nothing is still a terminal. Several do not carry
    # the category at all, so the well-known ones are offered when they exist.
    if role == "terminal":
        have = {c["id"] for c in out}
        for ent in all_entries().values():
            if ent["_id"] in have:
                continue
            exe = Path(_first_word(ent.get("Exec", ""))).name
            if exe in KNOWN_TERMINALS:
                out.append({
                    "id": ent["_id"],
                    "name": ent.get("Name", ent["_id"]),
                    "icon": ent.get("Icon", ""),
                    "comment": ent.get("Comment", ""),
                })
    out.sort(key=lambda c: c["name"].lower())
    return out


KNOWN_TERMINALS = [
    "kitty", "alacritty", "foot", "ghostty", "wezterm", "konsole",
    "gnome-terminal", "xfce4-terminal", "tilix", "terminator",
    "urxvt", "st", "xterm",
]


def _first_word(exec_line):
    exec_line = re.sub(r"%[fFuUdDnNickvm]", "", exec_line or "").strip()
    parts = exec_line.split()
    return parts[0] if parts else ""


# ---------------------------------------------------------------------------
# reading and writing the answer
# ---------------------------------------------------------------------------

def _load_own():
    try:
        return json.loads(DEFAULTS_FILE.read_text())
    except Exception:
        return {}


def _save_own(d):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = DEFAULTS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(d, indent=2))
    os.replace(tmp, DEFAULTS_FILE)      # the shell watches this file


# ---------------------------------------------------------------------------
# "open containing folder" is a D-Bus call, not a MIME lookup
# ---------------------------------------------------------------------------
#
# Setting inode/directory makes `xdg-open /some/folder` right, and that is what
# most of the desktop uses. But "reveal this file" asks for a folder opened with
# one item SELECTED, which a MIME handler cannot express, so Firefox, Chromium,
# Steam and most Electron applications call org.freedesktop.FileManager1 instead.
# That name belongs to whichever file manager shipped a D-Bus service file — on a
# machine with GNOME's packages installed, Nautilus — and it is claimed whatever
# the MIME database says. So choosing sea-fm here has to claim it too, or "open
# containing folder" keeps opening something else.
#
# $XDG_DATA_HOME/dbus-1/services is searched BEFORE the system directories, so
# this shadows their file rather than touching it; removing ours puts whichever
# of them was answering back.

FM1_NAME = "org.freedesktop.FileManager1"
FM1_DIR = Path(os.environ.get("XDG_DATA_HOME")
               or Path.home() / ".local" / "share") / "dbus-1" / "services"
FM1_FILE = FM1_DIR / (FM1_NAME + ".service")
FM1_STAMP = "# written by sea-shell (sea-defaults.py) — safe to delete\n"


def _is_sea_fm(entry):
    return "sea-fm" in (entry.get("Exec", "") or "")


def install_filemanager1_service(entry):
    argv = _exec_words(entry.get("Exec", ""))
    if not argv:
        return False, "that entry has no Exec line"
    try:
        FM1_DIR.mkdir(parents=True, exist_ok=True)
        FM1_FILE.write_text(FM1_STAMP
                            + "[D-BUS Service]\n"
                            + "Name=%s\n" % FM1_NAME
                            + "Exec=%s\n" % " ".join(argv))
        return True, ""
    except OSError as exc:
        return False, str(exc)


def uninstall_filemanager1_service():
    """Only ever removes OUR file, never Nautilus's or Dolphin's."""
    try:
        if not FM1_FILE.read_text().startswith(FM1_STAMP):
            return True, ""             # somebody else's; leave it alone
    except OSError:
        return True, ""                 # nothing there
    try:
        FM1_FILE.unlink()
        return True, ""
    except OSError as exc:
        return False, str(exc)


def _bus_rescan():
    """Tell the session bus to re-read its service files.

    IT DOES NOT NOTICE ON ITS OWN. dbus-broker indexes the activatable services
    at startup, so a service file written now is not seen until the next login —
    which means choosing sea-fm appeared to do nothing at all until you rebooted,
    and the old file manager kept answering. Best effort: if this fails the file
    is still correct and takes effect next session.
    """
    try:
        subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", "org.freedesktop.DBus",
             "--object-path", "/org/freedesktop/DBus",
             "--method", "org.freedesktop.DBus.ReloadConfig"],
            capture_output=True, timeout=10)
    except Exception:
        pass


def _exec_words(exec_line):
    """The Exec line with the field codes stripped — %u, %F and friends mean
    nothing to a D-Bus service, which is started with no arguments at all."""
    out = []
    for w in (exec_line or "").split():
        if re.fullmatch(r"%[fFuUdDnNickvm]", w):
            continue
        out.append(w)
    return out


def current(role):
    spec = ROLES.get(role) or {}
    mimes = spec.get("mimes") or []
    if mimes:
        try:
            out = subprocess.run(["xdg-mime", "query", "default", mimes[0]],
                                 capture_output=True, text=True, timeout=10)
            got = (out.stdout or "").strip()
            if got:
                return got
        except Exception:
            pass
        return ""
    return str(_load_own().get(role) or "")


def set_default(role, entry_id):
    spec = ROLES.get(role)
    if not spec or not entry_id:
        return False, "unknown role"
    known = all_entries()
    if entry_id not in known:
        return False, f"no such application: {entry_id}"

    mimes = spec.get("mimes") or []
    if mimes:
        if shutil.which("xdg-mime") is None:
            return False, "xdg-mime is not installed"
        try:
            subprocess.run(["xdg-mime", "default", entry_id] + mimes,
                           capture_output=True, text=True, timeout=20, check=True)
        except subprocess.CalledProcessError as exc:
            return False, (exc.stderr or "xdg-mime refused it").strip().splitlines()[0]
        except Exception as exc:
            return False, str(exc)
        # The browser has a second registry of its own that predates MIME
        # handlers, and some applications still ask that one instead.
        if role == "browser" and shutil.which("xdg-settings"):
            subprocess.run(["xdg-settings", "set", "default-web-browser", entry_id],
                           capture_output=True, timeout=20)

    # Choosing a file manager is also choosing who answers reveal requests.
    if role == "filemanager":
        if _is_sea_fm(known[entry_id]):
            ok2, msg2 = install_filemanager1_service(known[entry_id])
        else:
            ok2, msg2 = uninstall_filemanager1_service()
        if not ok2:
            return False, msg2
        _bus_rescan()

    # Recorded either way: the shell reads its own file for the terminal, and for
    # everything else it is a note of what was chosen HERE, so the settings page
    # can show the choice even where the desktop database is slow to agree.
    own = _load_own()
    own[role] = entry_id
    _save_own(own)
    return True, ""


# ---------------------------------------------------------------------------
# the terminal, for the scripts that need to open one
# ---------------------------------------------------------------------------

# How to tell each terminal to start somewhere, and to run something. There is no
# agreement on either flag, which is the whole reason this table exists.
TERM_CWD = {
    "kitty": ["--directory", "{cwd}"],
    "wezterm": ["start", "--cwd", "{cwd}"],
    "gnome-terminal": ["--working-directory={cwd}"],
    "alacritty": ["--working-directory", "{cwd}"],
    "foot": ["--working-directory", "{cwd}"],
    "ghostty": ["--working-directory", "{cwd}"],
    "konsole": ["--workdir", "{cwd}"],
    "xfce4-terminal": ["--working-directory={cwd}"],
    "tilix": ["--working-directory={cwd}"],
    "terminator": ["--working-directory={cwd}"],
}
TERM_EXEC = {"gnome-terminal": ["--"], "tilix": ["-e"], "wezterm": ["start", "--"]}


def terminal_argv(cwd=None, inner=None):
    """The chosen terminal if it is installed, else the first one that is."""
    order = []
    chosen = str(_load_own().get("terminal") or "")
    if chosen:
        ent = all_entries().get(chosen)
        if ent:
            exe = Path(_first_word(ent.get("Exec", ""))).name
            if exe:
                order.append(exe)
    order += [t for t in KNOWN_TERMINALS if t not in order]

    for term in order:
        if shutil.which(term) is None:
            continue
        if inner:
            return [term] + TERM_EXEC.get(term, ["-e"]) + list(inner)
        if cwd and term in TERM_CWD:
            return [term] + [a.format(cwd=str(cwd)) for a in TERM_CWD[term]]
        return [term]
    return []


# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2

    if args[0] == "--roles":
        print(json.dumps([dict(ROLES[r], role=r) for r in ROLE_ORDER]))
        return 0

    if args[0] == "--get":
        out = []
        known = all_entries()
        for r in ROLE_ORDER:
            cur = current(r)
            ent = known.get(cur)
            out.append({
                "role": r,
                "label": ROLES[r]["label"],
                "icon": ROLES[r]["icon"],
                "note": ROLES[r].get("note", ""),
                "current": cur,
                "currentName": ent.get("Name", "") if ent else "",
                "currentIcon": ent.get("Icon", "") if ent else "",
            })
        print(json.dumps(out))
        return 0

    if args[0] == "--all":
        # Everything the settings page needs in one call. Scanning the desktop
        # directories is the expensive part and it is the same scan for every
        # role, so doing it once beats eight processes doing it eight times.
        known = all_entries()
        roles = []
        cands = {}
        for r in ROLE_ORDER:
            cur = current(r)
            ent = known.get(cur)
            roles.append({
                "role": r,
                "label": ROLES[r]["label"],
                "icon": ROLES[r]["icon"],
                "note": ROLES[r].get("note", ""),
                "current": cur,
                "currentName": ent.get("Name", "") if ent else "",
                "currentIcon": ent.get("Icon", "") if ent else "",
                "standard": bool(ROLES[r].get("mimes")),
            })
            cands[r] = candidates(r)
        print(json.dumps({"roles": roles, "candidates": cands}))
        return 0

    if args[0] == "--list" and len(args) >= 2:
        print(json.dumps(candidates(args[1])))
        return 0

    if args[0] == "--set" and len(args) >= 3:
        ok, msg = set_default(args[1], args[2])
        print(json.dumps({"ok": ok, "error": msg}))
        return 0 if ok else 1

    if args[0] == "--terminal-argv":
        cwd = args[1] if len(args) > 1 else None
        print(json.dumps(terminal_argv(cwd=cwd)))
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
