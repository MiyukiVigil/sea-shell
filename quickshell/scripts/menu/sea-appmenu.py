#!/usr/bin/env python3
"""sea-appmenu — the focused window's menu bar, for the bar to draw.

WHY THIS EXISTS AND NOT DBUSMENU.  The usual global-menu plumbing is DBusMenu
plus com.canonical.AppMenu.Registrar, and the registrar keys every menu by an
**X11 window id**.  Under Wayland there is no such id.  KDE worked around it with
the org_kde_kwin_appmenu protocol, where a client ties its wl_surface to a DBus
path directly; Hyprland does not implement that protocol and neither does the
GTK equivalent (gtk_shell1.set_dbus_properties).  So there is no way to ask "what
is the menu of THIS surface".

Accessibility answers a different question that turns out to be the same one:
AT-SPI publishes each application's real menu bar, addressed by **process**, and
a process is something Hyprland will happily tell us about.  So the mapping is
focused window -> pid -> AT-SPI application -> menu bar, and no window id is ever
needed.

WHAT COMES OUT.  A JSON snapshot at $XDG_CACHE_HOME/sea-shell/appmenu.json,
rewritten on every focus change.  When the focused app has no menu bar the file
says so with an empty `menus` list — the bar is expected to fall back to what it
drew before, not to show an empty strip.  A global menu that appears as a blank
space for half the applications on the system is worse than no global menu.

    --once            resolve the focused window now, print the JSON, exit
    --daemon          follow Hyprland focus events and keep the file current
    --invoke PATH     activate a menu item, e.g. --invoke 'File/Open'
    --submenu PATH    populate and read one lazily-built submenu (Firefox)

Requires at-spi2-core (running session a11y bus) and python-gobject.
"""

import json
import os
import fcntl
import socket
import subprocess
import sys
import tempfile
import time

import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME",
                                    os.path.expanduser("~/.cache")), "sea-shell")
OUT = os.path.join(CACHE, "appmenu.json")


def CACHE_LOCK_DIR():
    os.makedirs(CACHE, exist_ok=True)
    return CACHE

# Menus deeper than this are not a menu bar any more, they are a tree view.
MAX_DEPTH = 4
# An app that shows more than this many top-level menus is misreporting; drawing
# forty of them across the bar would push everything else off it.
MAX_TOP = 16
MAX_ITEMS = 80


# ---------------------------------------------------------------- hyprland ----

def hyprctl(*args):
    try:
        out = subprocess.run(["hyprctl", "-j", *args],
                             capture_output=True, timeout=2)
        return json.loads(out.stdout or b"null")
    except Exception:
        return None


def focused():
    """The focused window as (pid, class, workspace id, monitor name)."""
    w = hyprctl("activewindow")
    if not isinstance(w, dict) or not w.get("pid"):
        return None
    ws = w.get("workspace") or {}
    return {
        "pid": int(w["pid"]),
        "class": w.get("class") or "",
        "ws": ws.get("id"),
        "monitor": w.get("monitor"),
    }


# ------------------------------------------------------------------- atspi ----

def app_for_pid(pid):
    """The AT-SPI application belonging to a pid.

    Electron and Firefox both run a process tree, and it is not always the pid
    Hyprland reports that owns the accessible objects, so walk up /proc as a
    fallback rather than giving up on the first miss.
    """
    desktop = Atspi.get_desktop(0)
    wanted = {pid}
    p = pid
    for _ in range(4):
        try:
            with open("/proc/%d/stat" % p) as fh:
                p = int(fh.read().split(") ", 1)[1].split()[1])
        except Exception:
            break
        if p <= 1:
            break
        wanted.add(p)
    for i in range(desktop.get_child_count()):
        try:
            app = desktop.get_child_at_index(i)
            if app is not None and app.get_process_id() in wanted:
                return app
        except Exception:
            continue
    return None


def find_menubar(node, depth=0):
    try:
        if node.get_role() == Atspi.Role.MENU_BAR:
            return node
        if depth > 6:
            return None
        for i in range(min(node.get_child_count(), 60)):
            c = node.get_child_at_index(i)
            if c is not None:
                r = find_menubar(c, depth + 1)
                if r is not None:
                    return r
    except Exception:
        pass
    return None


def children(node):
    """Children, stepping through the unnamed popup wrapper Qt puts in the way.

    Qt models a menu as  item "File" -> popup "" -> item "Open" , GTK as
    item "File" -> item "Open" .  Collapsing the wrapper here means the rest of
    this file — and the QML — never has to know which toolkit it is looking at.
    """
    out = []
    try:
        n = node.get_child_count()
    except Exception:
        return out
    for i in range(min(n, MAX_ITEMS)):
        try:
            c = node.get_child_at_index(i)
        except Exception:
            continue
        if c is None:
            continue
        try:
            role = c.get_role()
        except Exception:
            continue
        if role in (Atspi.Role.MENU, Atspi.Role.POPUP_MENU) and not (c.get_name() or ""):
            out.extend(children(c))
        else:
            out.append(c)
    return out


def action_names(node):
    try:
        ai = node.get_action_iface()
        if ai is None:
            return []
        return [Atspi.Action.get_action_name(ai, k)
                for k in range(Atspi.Action.get_n_actions(ai))]
    except Exception:
        return []


MODS = ("Control", "Ctrl", "Alt", "Shift", "Meta", "Super")


def key_binding(node):
    """The accelerator, if there is one, in a form worth printing.

    AT-SPI returns a colon-joined bundle of different things — for Firefox's Undo it is
    literally "U:Alt-E:U:Control-Z": the mnemonic letter, the menu path to reach it, and
    only then the real shortcut. Printing the raw string put "U:Alt-E:U:Control-Z" in the
    menu, which is how this was found. The last field is the accelerator, and it is only
    an accelerator if it carries a modifier — Firefox reports a bare "n" for Settings,
    which is a mnemonic, not something anyone can press on its own.
    """
    try:
        ai = node.get_action_iface()
        if ai is None or not Atspi.Action.get_n_actions(ai):
            return ""
        raw = (Atspi.Action.get_key_binding(ai, 0) or "").strip().rstrip(";")
        if not raw:
            return ""
        last = raw.split(":")[-1].strip()
        if not any(m in last for m in MODS):
            return ""
        out = last.replace("Control", "Ctrl").replace("Super", "Meta")
        return "+".join(p for p in out.replace("-", "+").split("+") if p)
    except Exception:
        return ""


def enabled(node):
    try:
        s = node.get_state_set()
        return bool(s.contains(Atspi.StateType.ENABLED)) or \
            bool(s.contains(Atspi.StateType.SENSITIVE))
    except Exception:
        return True


def describe(node, depth):
    """One menu entry and, if it is cheap to reach, everything under it."""
    try:
        role = node.get_role()
        name = node.get_name() or ""
    except Exception:
        return None
    if role == Atspi.Role.SEPARATOR:
        return {"sep": True}
    if not name:
        return None
    kids = children(node) if depth < MAX_DEPTH else []
    entry = {"label": name, "enabled": enabled(node)}
    # No accelerators. AT-SPI hands them over as a colon-joined bundle of mnemonic, menu
    # path and shortcut ("T:Alt-F:T:Control-T"), and every rule for picking the shortcut
    # out of it was wrong on some app — the mnemonic leaked through as "T:Ctrl-T" in the
    # bar. The menu reads fine without them, and not asking for them is one fewer AT-SPI
    # round trip per item, which is most of what priming a menu costs.
    if kids:
        sub = [describe(c, depth + 1) for c in kids]
        entry["items"] = [s for s in sub if s]
    elif role == Atspi.Role.MENU:
        # A menu with nothing under it has not been built yet. At the top level
        # that is fixable — opening it once fills it in permanently. Deeper than
        # that it is not: Firefox only builds a nested submenu while its PARENT
        # is open and hovered, which is an interaction AT-SPI cannot express. So
        # `stub` means "there is more here and we cannot reach it", and the bar
        # is expected to draw it as unreachable rather than as an empty popup.
        entry["lazy" if depth == 0 else "stub"] = True
    return entry


def snapshot():
    win = focused()
    base = {"v": 1, "menus": [], "mode": "none"}
    if win is None:
        return base
    base.update({"pid": win["pid"], "class": win["class"],
                 "ws": win["ws"], "monitor": win["monitor"]})
    app = app_for_pid(win["pid"])
    if app is None:
        base["why"] = "not on the accessibility bus"
        return base
    try:
        base["app"] = app.get_name() or ""
    except Exception:
        pass
    bar = find_menubar(app)
    if bar is None:
        base["why"] = "no menu bar exported"
        return base
    tops = children(bar)[:MAX_TOP]
    menus = [describe(t, 0) for t in tops]
    menus = [m for m in menus if m and not m.get("sep")]
    # Anything primed off-screen earlier is folded in here, so a menu the daemon already
    # opened out of sight arrives at the bar as an ordinary ready-to-draw menu.
    cached = PRIMED.get(win["pid"]) or {}
    for m in menus:
        if m.get("lazy") and cached.get(m["label"]):
            m["items"] = cached[m["label"]]
            m.pop("lazy", None)
    base["menus"] = menus
    # `mode` is what the bar gates on, and the distinction is not cosmetic.
    # "ready" costs nothing — Qt and GTK hand over the whole tree for free.
    # "lazy" means the labels are real but every menu must be opened once to be
    # read, and opening it is visible to the user: the application's own menu
    # flashes on screen and, in Firefox's case, its menu bar stays revealed
    # afterwards. That is a price worth paying on purpose, not by accident.
    base["mode"] = ("lazy" if menus and all(m.get("lazy") for m in menus)
                    else "ready" if menus else "none")
    return base


# ----------------------------------------------------------------- priming ----
#
# Firefox will not tell anyone what is in a menu until that menu has been opened, and
# opening it is a real open: the popup appears on screen. There is no read-only way in —
# no DBusMenu export, no static description, and the nested submenus are built only while
# their parent is open and hovered, which is not an interaction AT-SPI can perform.
#
# So the opening cannot be avoided. What CAN be avoided is the user seeing it. A window on
# a workspace that is not currently displayed is still mapped and still answers AT-SPI, so
# its menus can be opened, read and closed with nobody looking at them. By the time that
# window is focused again the whole tree is known and clicking a menu is instant.
#
# Apps that were never backgrounded still fall back to opening on demand — that is what
# --submenu is for — but in practice everything gets backgrounded within a minute or two.

PRIMED = {}          # pid -> {label: [items]}  (also {} for "checked, nothing lazy")


def visible_workspaces():
    """Workspace ids currently on a monitor — including any open special workspace."""
    out = set()
    for m in (hyprctl("monitors") or []):
        if not isinstance(m, dict):
            continue
        aw = m.get("activeWorkspace") or {}
        if aw.get("id") is not None:
            out.add(aw["id"])
        sw = m.get("specialWorkspace") or {}
        if sw.get("id"):
            out.add(sw["id"])
    return out


def prime_app(app):
    """Open every unbuilt top-level menu once, read it, close it. ~350ms each."""
    bar = find_menubar(app)
    if bar is None:
        return None
    got = {}
    for t in children(bar)[:MAX_TOP]:
        try:
            if children(t):
                continue                      # already built, or an eager toolkit
            ai = t.get_action_iface()
            if ai is None or not Atspi.Action.get_n_actions(ai):
                continue
            label = t.get_name() or ""
            Atspi.Action.do_action(ai, 0)
            time.sleep(0.3)
            got[label] = [i for i in (describe(c, 1) for c in children(t)) if i]
            Atspi.Action.do_action(ai, 0)     # toggle shut
            time.sleep(0.1)
        except Exception:
            continue
    return got


def prime_hidden(budget=1):
    """Prime at most `budget` off-screen apps. Called after each focus event."""
    vis = visible_workspaces()
    done = 0
    for c in (hyprctl("clients") or []):
        if done >= budget:
            return
        if not isinstance(c, dict):
            continue
        pid = c.get("pid")
        ws = (c.get("workspace") or {}).get("id")
        if not pid or pid in PRIMED or ws in vis:
            continue
        app = app_for_pid(int(pid))
        if app is None:
            continue
        got = prime_app(app)
        if got is None:
            continue
        PRIMED[int(pid)] = got
        done += 1


# ------------------------------------------------------------------ acting ----

def resolve(path):
    """Walk a 'File/Open' path down the focused app's menu bar."""
    win = focused()
    if win is None:
        return None
    app = app_for_pid(win["pid"])
    if app is None:
        return None
    node = find_menubar(app)
    if node is None:
        return None
    for want in path.split("/"):
        nxt = None
        for c in children(node):
            if (c.get_name() or "") == want:
                nxt = c
                break
        if nxt is None:
            return None
        node = nxt
    return node


def invoke(path):
    node = resolve(path)
    if node is None:
        return False
    try:
        ai = node.get_action_iface()
        if ai is None or not Atspi.Action.get_n_actions(ai):
            return False
        return bool(Atspi.Action.do_action(ai, 0))
    except Exception:
        return False


def submenu(path):
    """Open a lazily-built menu just far enough to read it, then close it again.

    Firefox reports its top-level labels but no contents until the menu has been
    opened once. Invoking the open action is the only way in, and it is a real
    open — the browser's own menu appears on screen for as long as this takes.
    Measured at ~350ms per menu; the entries stay readable afterwards, so the
    caller is expected to remember them and never ask twice.

    The close is a second invocation of the same action, which is a toggle. It
    puts the popup away but does NOT re-hide Firefox's menu bar — that stays
    revealed for the life of the window and there is no way in from here: the
    View > Toolbars > Menu Bar item lives inside a nested submenu that only
    builds while its parent is open and hovered, which AT-SPI cannot do.
    """
    node = resolve(path)
    if node is None:
        return {"path": path, "items": [], "primed": False}
    kids = children(node)
    primed = False
    if not kids:
        try:
            ai = node.get_action_iface()
            if ai is not None and Atspi.Action.get_n_actions(ai):
                Atspi.Action.do_action(ai, 0)
                primed = True
                time.sleep(0.35)
                kids = children(node)
                Atspi.Action.do_action(ai, 0)      # toggle it shut again
        except Exception:
            pass
    items = [describe(c, 1) for c in kids]
    return {"path": path, "items": [i for i in items if i], "primed": primed}


# ------------------------------------------------------------------ output ----

def write(obj):
    os.makedirs(CACHE, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".appmenu-")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh)
        os.replace(tmp, OUT)          # atomic: the bar never reads half a file
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def daemon():
    # ONE DAEMON, EVER. The bar owns this process, but a bar that is killed rather than
    # asked to quit leaves its child orphaned to init — and the next bar starts another.
    # Two daemons rewriting the same snapshot is not merely wasteful: they interleave, so
    # the bar can read a menu belonging to whichever one lost the race. flock is held for
    # the life of the process and released by the kernel however this exits, which a
    # pidfile written by hand is not.
    lock = open(os.path.join(CACHE_LOCK_DIR(), "appmenu.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.stderr.write("sea-appmenu: another daemon holds the lock; exiting\n")
        return 0
    globals()["_LOCK"] = lock          # keep it open, or the lock goes with it

    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    rt = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    if not sig:
        sys.stderr.write("sea-appmenu: no HYPRLAND_INSTANCE_SIGNATURE\n")
        return 1
    path = os.path.join(rt, "hypr", sig, ".socket2.sock")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    write(snapshot())
    # Whatever is already sitting on another workspace can be read right now, unseen.
    try:
        prime_hidden(budget=4)
    except Exception:
        pass
    write(snapshot())
    # DIE WITH THE BAR. Quickshell's Process does not reliably take its children down, so a
    # bar that is killed rather than asked to quit leaves this reparented to init — and the
    # orphan still holds the lock above, which means the NEXT bar's daemon starts, finds the
    # lock taken, exits, and gets revived on a timer for ever. Watching for reparenting is
    # what makes a restart hand over cleanly instead of deadlocking on a corpse.
    parent = os.getppid()
    # A SNAPSHOT PER FOCUS EVENT IS NOT ENOUGH. An application's menu bar can arrive well
    # after its window does — kdenlive shows a welcome dialog first and only builds the real
    # window (and its menu bar) when you dismiss it, which is not a focus change and so
    # produced no second look. The bar sat on "this app has no menus" for the rest of the
    # session while a menu bar was plainly visible on screen, which is how this was found.
    # So while the focused window reports nothing, keep asking for a while, then stop: an
    # app that has no menu bar after half a minute does not have one.
    retries = 0
    RETRY_LIMIT = 7
    s.settimeout(4.0)
    buf = b""
    # Only focus-shaped events matter. A menu bar does not change because a
    # window moved, and re-walking an accessibility tree on every event would
    # make the daemon the most expensive thing on the desktop.
    WANTED = ("activewindow>>", "activewindowv2>>", "workspace>>",
              "focusedmon>>", "closewindow>>", "activespecial>>")
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            if os.getppid() != parent and parent != 1:
                return 0                      # the bar that started us is gone
            if retries < RETRY_LIMIT:
                snap = snapshot()
                retries += 1
                if snap.get("menus"):
                    retries = RETRY_LIMIT     # found them; stop asking
                write(snap)
            continue
        if not chunk:
            return 0
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.decode("utf-8", "replace").startswith(WANTED):
                snap = snapshot()
                # A new window gets a fresh allowance of second looks.
                retries = RETRY_LIMIT if snap.get("menus") else 0
                write(snap)
                # Then use the quiet moment to build whatever is off-screen. Doing this
                # after the write means the bar is already correct before we go blocking.
                try:
                    prime_hidden()
                except Exception:
                    pass
                write(snapshot())


def main(argv):
    Atspi.init()
    if "--daemon" in argv:
        return daemon()
    if "--invoke" in argv:
        print(json.dumps({"ok": invoke(argv[argv.index("--invoke") + 1])}))
        return 0
    if "--submenu" in argv:
        print(json.dumps(submenu(argv[argv.index("--submenu") + 1])))
        return 0
    snap = snapshot()
    if "--write" in argv:
        write(snap)
    print(json.dumps(snap, indent=2 if "--pretty" in argv else None))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
