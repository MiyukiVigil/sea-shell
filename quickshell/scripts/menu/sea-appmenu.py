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

THE ONE RULE THAT MATTERS: NOTHING OPENS BEHIND THE USER'S BACK.
------------------------------------------------------------------
Firefox will not say what is in a menu until that menu has been opened, and
opening it is a REAL open — the popup appears on screen.  An earlier version of
this file tried to get ahead of that by opening every top-level menu of every
backgrounded window in advance ("priming").  Firefox exports eight top-level
menus; at ~400ms an open that is over three seconds of menus flashing open one
after another, and the visibility check was made ONCE before that loop.  Switch
workspace while it ran — which is exactly what you do right after launching a
browser — and you watched all eight of your own menus pop open in your face.
That is the bug this file was rewritten to kill.

So the model is now strictly demand-driven: a lazily-built menu is opened only
on the click that needs it, one menu, the one you asked for, and the result is
remembered for the life of the window.  Speculative priming still exists but is
OFF by default, and when enabled it re-checks visibility before every single
open and aborts the instant its window could be looked at.

    --once            resolve the focused window now, print the JSON, exit
    --daemon          follow Hyprland focus events and keep the file current
    --invoke PATH     activate a menu item, e.g. --invoke 'File/Open'
    --submenu PATH    populate and read one lazily-built menu (Firefox, Electron)
    --doctor          say, for every open window, why it does or does not have a menu
    --forget [CLASS]  throw away remembered menus (all, or one app class)
    --setup           report what each installed app needs for the global menu
    --setup --apply   do it (optionally naming which app ids to touch)

Requires at-spi2-core (running session a11y bus) and python-gobject.
"""

import json
import os
import fcntl
import re
import select
import socket
import subprocess
import threading
import shutil
import sys
import tempfile
import time
import warnings

# at-spi2 renames methods between releases and shouts about the old ones. The
# daemon's stderr is a diagnostic channel the bar's supervisor logs; a screenful
# of deprecation notices per menu walk buries anything that actually went wrong.
warnings.filterwarnings("ignore", category=DeprecationWarning)

import gi
gi.require_version("Atspi", "2.0")
gi.require_version("Gio", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME",
                                    os.path.expanduser("~/.cache")), "sea-shell")
OUT = os.path.join(CACHE, "appmenu.json")
CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME",
                                   os.path.expanduser("~/.config")),
                    "sea-shell", "appmenu.json")


def CACHE_LOCK_DIR():
    os.makedirs(CACHE, exist_ok=True)
    return CACHE


# Menus deeper than this are not a menu bar any more, they are a tree view.
MAX_DEPTH = 4
# An app that shows more than this many top-level menus is misreporting; drawing
# forty of them across the bar would push everything else off it.
MAX_TOP = 16
MAX_ITEMS = 80
# Electron buries its menu bar under four nested Views panels, so the search has
# to go deeper than a GTK/Qt window ever needs.  Measured at exactly 6 from the
# application object; 10 leaves room without turning the walk into a crawl.
MAX_BAR_DEPTH = 10


# ------------------------------------------------------------------ config ----
#
# Two knobs, both about the one thing that can be user-visible: whether this is
# ever allowed to open an application's menu when the user did not ask for it.

DEFAULTS = {
    # Open backgrounded apps' lazy menus in advance so the first click is instant.
    # OFF: the cost is that the FIRST click on a Firefox menu flashes Firefox's own
    # popup for ~350ms. The benefit is that nothing ever opens unbidden. That trade
    # is not close — see the header.
    "prime": False,
    # When priming is on, never spend longer than this on one pass.
    "prime_budget_ms": 1500,
}


def config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONF) as fh:
            user = json.load(fh)
        if isinstance(user, dict):
            for k in DEFAULTS:
                if k in user:
                    cfg[k] = user[k]
    except Exception:
        pass
    return cfg


CFG = dict(DEFAULTS)


# ---------------------------------------------------------------- hyprland ----

def _hypr_sock():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if not sig:
        return None
    rt = os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%d" % os.getuid())
    p = os.path.join(rt, "hypr", sig, ".socket.sock")
    return p if os.path.exists(p) else None


def hyprctl(*args):
    """Ask Hyprland — over its own socket, not by spawning hyprctl(1).

    THIS IS MOST OF WHAT "SWITCHING WORKSPACES IS SLOW" WAS MADE OF. Every call here used
    to fork and exec a C program whose entire job is to make this same socket request, and
    a focus change makes several of them; `clients` on top of that serialises every window
    on the desktop. Tens of milliseconds each, before a single word has been said to the
    application whose menus we are actually after.

    Same request, same JSON, no process. The subprocess stays as the fallback for anything
    that cannot find the socket — a session that never exported the instance signature, or
    a compositor that is not Hyprland at all.
    """
    p = _hypr_sock()
    if p:
        c = None
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.settimeout(2)
            c.connect(p)
            c.sendall(("j/" + " ".join(args)).encode())
            buf = b""
            while True:
                chunk = c.recv(65536)
                if not chunk:
                    break
                buf += chunk
            if buf:
                return json.loads(buf)
        except Exception:
            pass
        finally:
            if c is not None:
                try:
                    c.close()
                except Exception:
                    pass
    try:
        out = subprocess.run(["hyprctl", "-j", *args],
                             capture_output=True, timeout=2)
        return json.loads(out.stdout or b"null")
    except Exception:
        return None


def focused(addr=None):
    """The focused window as (pid, class, workspace id, monitor name).

    THE EVENT KNOWS BEFORE hyprctl DOES. Hyprland announces a focus change on the socket
    and only afterwards updates what `hyprctl activewindow` reports — so asking the moment
    the event arrives hands back the window you just LEFT. The daemon then wrote a
    perfectly fresh snapshot full of the previous application's menus, nothing else
    happened, and the bar sat there showing VS Code's File/Edit over a terminal until the
    next focus change. That is the stale menu, and it was a race, not a missed event,
    which is why it came and went.
    #
    activewindowv2 carries the new window's ADDRESS, so when there is one the answer comes
    from that rather than from a query that has not caught up yet.
    """
    if addr:
        for c in (hyprctl("clients") or []):
            if not isinstance(c, dict):
                continue
            if (c.get("address") or "").lower() == addr.lower() and c.get("pid"):
                ws = c.get("workspace") or {}
                return {"pid": int(c["pid"]), "class": c.get("class") or "",
                        "ws": ws.get("id"), "monitor": c.get("monitor")}
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

    Prefers an application that actually has children: Chromium registers one
    stub application per process tree alongside the real one, and picking the
    stub is indistinguishable from "this app has no menus" from the outside.
    """
    desktop = Atspi.get_desktop(0)
    # Ancestors, nearest first. THE EXACT PID HAS TO WIN. Walking up /proc and
    # taking the first application found anywhere in that chain will happily
    # match a completely unrelated ancestor — an app launched from an editor's
    # built-in terminal has that editor as a forebear, and the editor is on the
    # bus too, so the window got the editor's (empty) menu bar and reported it as
    # its own. Rank instead: this process beats its parent, and an application
    # that actually describes its windows beats one that only registers.
    chain = [pid]
    p = pid
    for _ in range(4):
        try:
            with open("/proc/%d/stat" % p) as fh:
                p = int(fh.read().split(") ", 1)[1].split()[1])
        except Exception:
            break
        if p <= 1:
            break
        chain.append(p)
    rank = {q: i for i, q in enumerate(chain)}
    best = None
    best_key = None
    for i in range(desktop.get_child_count()):
        try:
            app = desktop.get_child_at_index(i)
            if app is None:
                continue
            r = rank.get(app.get_process_id())
            if r is None:
                continue
            key = (r, 0 if app.get_child_count() > 0 else 1)
        except Exception:
            continue
        if best_key is None or key < best_key:
            best, best_key = app, key
    return best


def toolkit(app):
    try:
        return app.get_toolkit_name() or ""
    except Exception:
        return ""


def is_stub_tree(app):
    """True when an application advertises windows it then refuses to describe.

    THE ELECTRON FAILURE, AND WHY IT LOOKED LIKE 'NO MENUS'.  Chromium decides at
    process START whether to build an accessibility tree.  Until it does, it still
    registers on the bus and still reports one `frame` per window with a child
    count of 1 — but `get_child_at_index(0)` on that frame returns None.  Every
    Electron app therefore arrived here looking exactly like an app that simply
    has no menu bar, and the bar said so, and there was nothing to act on.

    It is not fixable from outside the process: flipping org.a11y.Status
    ScreenReaderEnabled on a running Chromium does not retroactively build the
    tree (measured — twelve seconds, still None).  The app has to be started with
    --force-renderer-accessibility.  So the useful thing this can do is name the
    problem instead of hiding it, which is what `why`/`hint` in the snapshot are.
    """
    try:
        n = app.get_child_count()
    except Exception:
        return False
    if n <= 0:
        return False
    for i in range(min(n, 8)):
        try:
            f = app.get_child_at_index(i)
        except Exception:
            return False
        if f is None:
            continue
        try:
            if f.get_child_count() <= 0:
                continue
            # A frame that claims children but hands over none is the stub.
            for k in range(min(f.get_child_count(), 3)):
                if f.get_child_at_index(k) is not None:
                    return False
        except Exception:
            continue
    return True


def find_menubar(node, depth=0):
    """The first MENU_BAR anywhere in the application, breadth of 60, depth of 10.

    Searches EVERY frame, not just the first: Electron parents its menu bar to a
    different frame than the one carrying the page, so stopping at the first
    window found nothing.
    """
    try:
        if node.get_role() == Atspi.Role.MENU_BAR:
            return node
        if depth > MAX_BAR_DEPTH:
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


# Wrappers that carry no meaning of their own and only stand between a menu and
# its items. Qt models a menu as item "File" -> popup "" -> item "Open"; Chromium
# inserts unnamed panels/fillers in the same position. Collapsing them here means
# the rest of this file — and the QML — never has to know which toolkit it is
# looking at.
TRANSPARENT = (Atspi.Role.MENU, Atspi.Role.POPUP_MENU, Atspi.Role.PANEL,
               Atspi.Role.FILLER, Atspi.Role.REDUNDANT_OBJECT)

# What a top-level menu entry can be. GTK and Qt use MENU. Chromium's menu bar
# holds PUSH_BUTTONs whose first action is literally called "open" — treating
# those as ordinary leaf items made the bar draw "File" as something clickable
# that, when clicked, opened Electron's OWN menu next to ours.
MENUISH = (Atspi.Role.MENU, Atspi.Role.PUSH_BUTTON, Atspi.Role.TOGGLE_BUTTON)


def children(node, _depth=0):
    """Children, stepping through the unnamed wrappers toolkits put in the way."""
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
            name = c.get_name() or ""
        except Exception:
            continue
        # Bounded: an unnamed panel inside a menu is a wrapper, but the same role
        # nested forever is a web page, and Electron parks one of those next to
        # the menu bar.
        if role in TRANSPARENT and not name and _depth < 3:
            out.extend(children(c, _depth + 1))
        else:
            out.append(c)
    return out


def _action_name(ai, k):
    # get_action_name is deprecated in favour of get_name, but which one exists
    # depends on the at-spi2 version packaged; asking for the new one first keeps
    # the daemon's stderr clean without pinning a version.
    try:
        return Atspi.Action.get_name(ai, k) or ""
    except Exception:
        pass
    try:
        return Atspi.Action.get_action_name(ai, k) or ""
    except Exception:
        return ""


def action_index(node, *names):
    """The index of the first action with one of these names, or -1."""
    try:
        ai = node.get_action_iface()
        if ai is None:
            return -1
        for k in range(Atspi.Action.get_n_actions(ai)):
            if _action_name(ai, k).lower() in names:
                return k
    except Exception:
        pass
    return -1


def do(node, *names):
    """Fire the named action, falling back to action 0."""
    try:
        ai = node.get_action_iface()
        if ai is None or not Atspi.Action.get_n_actions(ai):
            return False
        k = action_index(node, *names) if names else -1
        return bool(Atspi.Action.do_action(ai, k if k >= 0 else 0))
    except Exception:
        return False


def has_popup(node):
    """Does this node say, in states, that something opens out of it?

    Chromium's NESTED submenus are the reason this exists. A top-level entry in its
    menu bar is a PUSH_BUTTON with an action called "open", which is easy to spot —
    but "File > Recent" inside the popup is an ordinary MENU_ITEM whose only action
    is "doDefault", identical in every way to "Quit" except for two state flags.
    Without checking them, a submenu was drawn as a command, and clicking it would
    have fired doDefault on a thing that does not do anything.
    """
    try:
        st = node.get_state_set()
        return bool(st.contains(Atspi.StateType.HAS_POPUP)) or \
            bool(st.contains(Atspi.StateType.EXPANDABLE))
    except Exception:
        return False


def opens_a_menu(node):
    """A childless node that is really a menu nobody has built yet.

    The test cannot be the action name alone. Gecko calls it "click" and Chromium
    calls it "open", and "click" is also what every ordinary button in every
    toolbar is called — so keying off the name made Firefox's eight unbuilt menus
    look like eight clickable commands, and the bar would have fired the first
    item of each instead of opening it.

    So role and state decide, and the action only has to exist:
      MENU with no children   — unbuilt by definition, whatever the toolkit
      BUTTON with an "open"   — Chromium's menu bar, which holds buttons
      anything HAS_POPUP      — Chromium's nested submenus, which are menu items
    """
    try:
        role = node.get_role()
        ai = node.get_action_iface()
        if ai is None or not Atspi.Action.get_n_actions(ai):
            return False
    except Exception:
        return False
    if role in (Atspi.Role.MENU, Atspi.Role.POPUP_MENU):
        return True
    if has_popup(node):
        return True
    if role in (Atspi.Role.PUSH_BUTTON, Atspi.Role.TOGGLE_BUTTON):
        return action_index(node, "open") >= 0
    return False


MODS = ("Control", "Ctrl", "Alt", "Shift", "Meta", "Super")

# Chromium does not expose an accelerator as an accelerator. It bakes it into the
# item's NAME — the accessible name of Electron's paste item is literally
# "Coller Ctrl+V" — so a global menu that prints the name prints the shortcut
# twice as wide and, worse, cannot invoke the item afterwards: the caller sends
# back the label it was shown ("Coller") and nothing in the tree is called that.
ACCEL = re.compile(
    r"\s+((?:(?:Ctrl|Control|Alt|Shift|Super|Meta|Cmd|Command)\+)+[^\s+]+)$")


def split_accel(name):
    """('Coller Ctrl+V') -> ('Coller', 'Ctrl+V'); anything else -> (name, '')."""
    name = name or ""
    m = ACCEL.search(name)
    if not m:
        return name, ""
    return name[:m.start()].rstrip(), m.group(1)


def name_matches(node, want):
    """Does this node answer to `want`, with or without its baked-in shortcut?"""
    try:
        raw = node.get_name() or ""
    except Exception:
        return False
    return raw == want or split_accel(raw)[0] == want


MOD_NAMES = {"control": "Ctrl", "ctrl": "Ctrl", "primary": "Ctrl",
             "alt": "Alt", "shift": "Shift", "meta": "Meta", "super": "Meta",
             "cmd": "Meta", "command": "Meta", "altgr": "AltGr"}
BRACKET = re.compile(r"<([^>]+)>")


def key_binding(node):
    """The accelerator, if there is one, in a form worth printing.

    AT-SPI does not return an accelerator. It returns a colon-joined bundle of
    everything the item can be reached by, and each field is itself a
    semicolon-joined pair of mnemonic and shortcut. Firefox's Undo is literally

        'U;<Alt>E:U;<Control>Z'

    — mnemonic U, the Alt-E path to the Edit menu, then finally Control-Z. Every
    previous attempt here matched on substrings and every one of them leaked a
    mnemonic into the bar ("U:Alt-E:U:Control-Z" was printed verbatim once, and
    "T:Ctrl-T" after the first fix), which is why the feature shipped with
    accelerators switched off entirely.

    So parse the structure instead of searching the text: take the LAST colon
    field, take what follows its last semicolon, and require that what remains
    be one or more <bracketed> modifiers followed by a key. Delete reports
    'D;<Alt>E:D;' — a menu path and no shortcut — and correctly yields nothing.
    A handful of toolkits use 'Control-Z' rather than '<Control>Z', so that form
    is accepted too, but only when every part before the last is a real modifier.
    Anything that does not fit is dropped rather than guessed at: a wrong
    shortcut printed beside a menu item is worse than a missing one.
    """
    try:
        ai = node.get_action_iface()
        if ai is None or not Atspi.Action.get_n_actions(ai):
            return ""
        raw = (Atspi.Action.get_key_binding(ai, 0) or "").strip()
    except Exception:
        return ""
    return parse_accel(raw)


def parse_accel(raw):
    if not raw:
        return ""
    field = raw.split(":")[-1]
    field = field.split(";")[-1].strip()
    if not field:
        return ""
    mods = BRACKET.findall(field)
    key = BRACKET.sub("", field).strip()
    if not mods:
        parts = [p for p in field.replace("-", "+").split("+") if p]
        if len(parts) < 2:
            return ""
        mods, key = parts[:-1], parts[-1]
    if not key or len(key) > 12:
        return ""
    out = []
    for mo in mods:
        norm = MOD_NAMES.get(mo.strip().lower())
        if norm is None:
            return ""                       # not a modifier => not a shortcut
        if norm not in out:
            out.append(norm)
    if not out:
        return ""
    out.append(key if len(key) > 1 else key.upper())
    return "+".join(out)


def enabled(node):
    try:
        s = node.get_state_set()
        return bool(s.contains(Atspi.StateType.ENABLED)) or \
            bool(s.contains(Atspi.StateType.SENSITIVE))
    except Exception:
        return True


def checked(node):
    """Tri-state: True/False for a checkable item, None for an ordinary one."""
    try:
        s = node.get_state_set()
        if s.contains(Atspi.StateType.CHECKED):
            return True
        if s.contains(Atspi.StateType.CHECKABLE):
            return False
    except Exception:
        pass
    return None


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
    label, baked = split_accel(name)
    if not label:
        return None
    kids = children(node) if depth < MAX_DEPTH else []
    entry = {"label": label, "enabled": enabled(node)}
    # AT-SPI's own binding first, the one Chromium baked into the name second.
    acc = key_binding(node) or baked
    if acc:
        entry["key"] = acc
    ck = checked(node)
    if ck is not None:
        entry["checked"] = ck
        # Same distinction the dbusmenu path makes, from the role instead of a property:
        # AT-SPI has a separate role for a radio item, and drawing it as a tick told the
        # user a set of mutually exclusive choices could all be on at once.
        try:
            if role == Atspi.Role.RADIO_MENU_ITEM:
                entry["radio"] = True
        except Exception:
            pass
    if kids:
        sub = [describe(c, depth + 1) for c in kids]
        entry["items"] = [s for s in sub if s]
    elif (role in MENUISH or has_popup(node)) and opens_a_menu(node):
        # A menu with nothing under it has not been built yet. At the top level
        # that is fixable — the bar asks for it with --submenu on the click that
        # needs it. Deeper than that it is not: Firefox only builds a nested
        # submenu while its PARENT is open and hovered, which is an interaction
        # AT-SPI cannot express. So `stub` means "there is more here and we
        # cannot reach it", and the bar draws it as unreachable rather than as
        # something that would fire the wrong action.
        entry["lazy" if depth == 0 else "stub"] = True
    return entry


def read_menus(app):
    """(menus, why, hint) for an application object."""
    bar = find_menubar(app)
    if bar is None:
        if toolkit(app) == "Chromium" and is_stub_tree(app):
            return ([], "chromium accessibility is off in this app",
                    "run it with --ozone-platform=x11 — under XWayland electron publishes "
                    "its whole menu to the registrar this daemon hosts, with nothing opened "
                    "and its own menu bar hidden. Put the flag in the app's flags file "
                    "(~/.config/code-flags.conf, ~/.config/obsidian/user-flags.conf) or on "
                    "the Exec line of a .desktop copy in ~/.local/share/applications. "
                    "--force-renderer-accessibility is the lesser fallback: it reads menus "
                    "by really opening them, which you can see")
        if toolkit(app) == "Chromium":
            # NOT a dead end, which is what this used to say. An Electron app with an HTML
            # titlebar exposes no menu bar to ACCESSIBILITY, but it still has a real
            # Menu.setApplicationMenu underneath, and under XWayland it hands that to the
            # registrar quite happily — Obsidian was written off on this line and works.
            return ([], "no menu bar over accessibility",
                    "run it with --ozone-platform=x11: the menu then arrives over the "
                    "registrar as data, whatever the titlebar looks like")
        return ([], "no menu bar exported", "")
    tops = children(bar)[:MAX_TOP]
    menus = [describe(t, 0) for t in tops]
    return ([m for m in menus if m and not m.get("sep")], "", "")


def is_xwayland(pid):
    for c in (hyprctl("clients") or []):
        if isinstance(c, dict) and c.get("pid") == pid:
            return bool(c.get("xwayland"))
    return False


def snapshot(addr=None):
    win = focused(addr)
    base = {"v": 2, "menus": [], "mode": "none"}
    if win is None:
        return base
    base.update({"pid": win["pid"], "class": win["class"],
                 "ws": win["ws"], "monitor": win["monitor"]})
    # THE EXPORT BEFORE THE WORKAROUND. If the application publishes its menu as data,
    # take it: the whole tree arrives in one call, nothing is opened, and none of the
    # lazy/stub machinery below is needed at all.
    dm = dbm_for_pid(win["pid"],
                     x11_active_window() if is_xwayland(win["pid"]) else None)
    if dm is not None:
        menus = dbm_menus(dm)
        if menus:
            base["menus"] = menus
            base["mode"] = "ready"
            base["source"] = "dbusmenu"
            base["app"] = dm[0]
            # REMEMBER THEM EVEN THOUGH WE DID NOT HAVE TO ASK.
            #
            # Memory used to be written only on the lazy path — the one that has to OPEN a
            # menu to find out what is in it — on the reasoning that the exported path costs
            # nothing so there is nothing to save. That is true right up until the export
            # stops working: Firefox exports its menu as data only while it can reach the
            # registrar, and a Firefox that comes back without registering falls through to
            # the accessibility walk with an empty memory, so every menu has to be opened for
            # real, once, with its own popup flashing on screen. Which is exactly what
            # "restart Firefox and it reads its menus again" is.
            #
            # A menu bar is a menu bar whichever way it arrived, so save it either way and
            # the fallback starts out already knowing.
            mem_remember_tree(win.get("class") or "", menus)
            return base
    app = app_for_pid(win["pid"])
    if app is None:
        base["why"] = "not on the accessibility bus"
        return base
    try:
        base["app"] = app.get_name() or ""
        base["toolkit"] = toolkit(app)
    except Exception:
        pass
    menus, why, hint = read_menus(app)
    if why:
        base["why"] = why
    if hint:
        base["hint"] = hint
    # Anything already read — primed off-screen, or opened once by the user — is folded
    # in here, so a menu whose contents are known arrives at the bar ready to draw.
    cached = PRIMED.get(win["pid"]) or {}
    for m in menus:
        if m.get("lazy") and cached.get(m["label"]):
            m["items"] = cached[m["label"]]
            m.pop("lazy", None)
    # Anything this application has ever been asked for, at any depth, put straight back
    # so the bar draws it with no round trip and no flash.
    fill_remembered(menus, mem_load().get(win.get("class") or "", {}))
    base["menus"] = menus
    # `mode` is what the bar gates on, and the distinction is not cosmetic.
    # "ready" costs nothing — Qt and GTK hand over the whole tree for free.
    # "lazy" means the labels are real but a menu must be opened once to be read,
    # and that open is visible to the user. It happens on the click that asks for
    # it and never otherwise.
    base["mode"] = ("ready" if menus and not any(m.get("lazy") for m in menus)
                    else "lazy" if menus else "none")
    if menus:
        base["source"] = "atspi"
    # A Gecko window with no export is one pref away from the good path, and there is
    # no way for the bar to say so on its own — it would just look like a slow menu.
    if toolkit(app) == "Gecko" and base.get("mode") == "lazy":
        base["hint"] = ("set widget.gtk.global-menu.enabled and "
                        "widget.gtk.global-menu.wayland.enabled to true in about:config "
                        "and restart firefox — its whole menu then arrives as data, with "
                        "nothing opened on screen")
    return base


# ----------------------------------------------------------------- priming ----
#
# OFF BY DEFAULT — see the header. What follows is what priming has to look like to
# be safe at all, for the people who turn it on: a window on a workspace nobody is
# looking at can have its menus opened and read unseen, but "nobody is looking at it"
# is a fact with a shelf life of one keystroke. So it is re-established before every
# single open, and the pass abandons itself the moment it stops being true.

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


def still_hidden(pid):
    """Is this pid's window STILL on no visible workspace and not focused?

    Called immediately before each open rather than once per app. hyprctl costs a
    couple of milliseconds; an open costs 400 and is seen by the user if this is
    wrong, so the ratio is not close.
    """
    f = focused()
    if f and f["pid"] == pid:
        return False
    vis = visible_workspaces()
    if not vis:
        return False          # cannot tell => assume it is on screen
    for c in (hyprctl("clients") or []):
        if isinstance(c, dict) and c.get("pid") == pid:
            ws = (c.get("workspace") or {}).get("id")
            if ws in vis:
                return False
    return True


def prime_app(app, pid, deadline, cls="", force=False):
    """Open each unbuilt top-level menu once, read it, close it. ~350ms each.

    Returns None if this app has no menu bar at all, so the caller can remember
    that and stop re-walking it on every focus event.

    THE POINT OF DOING THIS AT ALL is Electron. Firefox has a way out — it can
    publish its menu as data and then nothing is ever opened — but Chromium's
    dbusmenu server is X11-only, so on Wayland an Electron menu can only be read
    by really opening it, and that open IS visible (measured: the popup renders
    on screen for the whole ~350ms). Doing it here, against a window sitting on a
    workspace nobody is looking at, is the only way to pay that cost unseen.
    """
    bar = find_menubar(app)
    if bar is None:
        return None
    got = {}
    for t in children(bar)[:MAX_TOP]:
        if time.monotonic() > deadline:
            break
        # `force` is a user who ASKED for this, from the menu's own search card, having
        # been told it will flash. The hidden-window rule exists so the background sweep
        # never opens a menu in someone's face; it has no business overriding a request.
        if not force and not still_hidden(pid):
            break                             # someone is looking; stop at once
        try:
            if children(t):
                continue                      # already built, or an eager toolkit
            if not opens_a_menu(t):
                continue
            label = split_accel(t.get_name() or "")[0]
            if not label:
                continue
            before = set(popup_sig(x) for x in open_popups(app))
            do(t, "open", "click", "doDefault")
            time.sleep(0.3)
            kids = children(t)
            if not kids:
                # Chromium parents the popup to a frame of its own, not to the
                # button — reading the button's children found nothing, so every
                # primed Electron menu was stored empty and the whole pass was
                # wasted effort that the user still paid for in flashes.
                pop = find_open_popup(app, before)
                if pop is not None:
                    kids = children(pop)
            items = [i for i in (describe(c, 1) for c in kids) if i]
            if items:
                got[label] = items
                mem_save(cls, label, items)   # survive this window, and this session
            do(t, "close", "open", "click", "doDefault")
            time.sleep(0.1)
        except Exception:
            continue
    return got


def prime_all():
    """Read EVERY menu of the focused window once, remember them all, and say so.

    Search can only search what is known. An application that publishes its menu as data
    is entirely known the moment it is focused; one that builds each menu on first open —
    Firefox, anything Electron — is known only as far as you have happened to click, so
    searching it finds a fraction of it and gives no sign that the rest exists.

    This is the one-time payment that fixes that: every unbuilt menu is opened, read,
    remembered and closed. It IS visible — the application's own menus flash past, about a
    third of a second each — which is why it is a button someone presses rather than
    something done behind their back, and why it never has to happen twice.
    """
    win = focused()
    if win is None:
        return {"ok": False, "why": "nothing is focused"}
    cls = win.get("class") or ""
    # Already exported as data? Then there was never anything to open; just make sure the
    # whole tree is on disk so a later session that cannot reach the export starts knowing.
    dm = dbm_for_pid(win["pid"], x11_active_window() if is_xwayland(win["pid"]) else None)
    if dm is not None:
        menus = dbm_menus(dm)
        if menus:
            mem_remember_tree(cls, menus)
            return {"ok": True, "menus": len(menus), "opened": 0, "source": "dbusmenu"}
    app = app_for_pid(win["pid"])
    if app is None:
        return {"ok": False, "why": "not on the accessibility bus"}
    got = prime_app(app, int(win["pid"]), time.monotonic() + 30, cls, force=True)
    if got is None:
        return {"ok": False, "why": "this window has no menu bar"}
    menus, why, hint = read_menus(app)
    if menus:
        fill_remembered(menus, mem_load().get(cls, {}))
        mem_remember_tree(cls, menus)
    return {"ok": True, "menus": len(menus or []), "opened": len(got), "source": "atspi"}


def prime_hidden(budget=1):
    """Prime at most `budget` off-screen apps. Only ever called when cfg["prime"]."""
    deadline = time.monotonic() + (CFG.get("prime_budget_ms", 1500) / 1000.0)
    vis = visible_workspaces()
    if not vis:
        return
    done = 0
    for c in (hyprctl("clients") or []):
        if done >= budget or time.monotonic() > deadline:
            return
        if not isinstance(c, dict):
            continue
        pid = c.get("pid")
        ws = (c.get("workspace") or {}).get("id")
        if not pid or pid in PRIMED or ws in vis:
            continue
        if dbm_for_pid(int(pid)) is not None:
            PRIMED[int(pid)] = {}          # exports its menu; nothing to open
            continue
        app = app_for_pid(int(pid))
        if app is None:
            continue
        got = prime_app(app, int(pid), deadline, c.get("class") or "")
        # REMEMBER THE MISSES TOO. Storing only successes meant every window without
        # a menu bar — which is most of them — was re-walked on every focus event and
        # ate the budget, so the windows that DID have menus were never reached.
        PRIMED[int(pid)] = got if got is not None else {}
        done += 1


def forget_dead():
    """Drop cache for pids that no longer have a window.

    PRIMED grew for the life of the session and pids get reused, so a long
    session could serve one app's menu under another app's window.
    """
    if not PRIMED:
        return
    live = set()
    for c in (hyprctl("clients") or []):
        if isinstance(c, dict) and c.get("pid"):
            live.add(int(c["pid"]))
    if not live:
        return
    for pid in [p for p in PRIMED if p not in live]:
        PRIMED.pop(pid, None)


# ------------------------------------------------------------------ acting ----

def resolve(path, app=None, opening=False, opened=None):
    """Walk a 'File/Open' path down the focused app's menu bar.

    `opening` lets the walk BUILD the path as it goes, which is the only way to
    reach a nested item in Chromium: the item does not exist as an object until
    its popup is open, so resolving 'Edition/Copier' against a closed menu bar
    found 'Edition' and then nothing. Every node this opens is pushed onto
    `opened` so a failed walk can put back what it disturbed.
    """
    if app is None:
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
        kids = children(node)
        if not kids and opening and opens_a_menu(node):
            before = set(popup_sig(x) for x in open_popups(app))
            do(node, "open", "click", "doDefault")
            if opened is not None:
                opened.append(node)
            time.sleep(0.3)
            kids = children(node)
            if not kids:
                pop = find_open_popup(app, before)
                if pop is not None:
                    kids = children(pop)
        nxt = None
        for c in kids:
            if name_matches(c, want):
                nxt = c
                break
        if nxt is None:
            return None
        node = nxt
    return node


def invoke(path):
    """Fire a menu item, opening whatever has to be open to reach it.

    A dbusmenu Event needs nothing opened at all, so that is tried first.

    Activating an item closes its menus by itself, so `opened` only has to be
    unwound when the walk FAILS — otherwise the toggle would reopen what the
    application had already put away.
    """
    win = focused()
    if win is None:
        return False
    dm = dbm_for_pid(win["pid"], x11_active_window())
    if dm is not None and dbm_invoke(dm, path):
        return True
    app = app_for_pid(win["pid"])
    if app is None:
        return False
    opened = []
    node = resolve(path, app, opening=True, opened=opened)
    ok = do(node, "click", "doDefault", "press", "activate") if node else False
    if not ok:
        for n in reversed(opened):
            do(n, "close", "open", "click")
    return ok


def popup_sig(n):
    """What a popup contains, as something hashable.

    NOT id(). AT-SPI hands back a fresh Python wrapper on every call, so object
    identity never matches across two walks — which is why excluding "the popup we
    already had" silently excluded nothing and the nested submenu came back as its
    own parent.
    """
    try:
        names = []
        for i in range(min(n.get_child_count(), 6)):
            c = n.get_child_at_index(i)
            names.append((c.get_name() or "") if c is not None else "")
        return (n.get_child_count(), tuple(names))
    except Exception:
        return (0, ())


def open_popups(app):
    """Every menu popup currently on screen for this application, outermost first."""
    out = []

    def walk(n, depth=0):
        if depth > MAX_BAR_DEPTH:
            return
        try:
            if n.get_role() in (Atspi.Role.MENU, Atspi.Role.POPUP_MENU):
                st = n.get_state_set()
                if st.contains(Atspi.StateType.SHOWING) and n.get_child_count() > 0:
                    out.append(n)
            for i in range(min(n.get_child_count(), 40)):
                c = n.get_child_at_index(i)
                if c is not None:
                    walk(c, depth + 1)
        except Exception:
            return

    walk(app)
    return out


def find_open_popup(app, exclude):
    """The menu that was just opened, which is NOT parented to the item that opened it.

    GTK and Qt hang a popup off the item that opened it, so reading it back is
    simply reading that item's children. Chromium does not: the popup is its own
    object elsewhere in the application and the item stays childless, so it has to
    be gone and found. `exclude` is the set of popup signatures that were already
    on screen before the open, which is what keeps a nested submenu from resolving
    to the parent popup it came out of.
    """
    for n in open_popups(app):
        if popup_sig(n) not in exclude:
            return n
    return None


def submenu(path):
    """Open a lazily-built menu just far enough to read it, then close it again.

    This is the ONLY place that opens anything, and it runs on the click that asked
    for it. Firefox reports its top-level labels but no contents until the menu has
    been opened once; Electron does the same and additionally puts the popup somewhere
    other than under the button. Invoking the open action is the only way in, and it
    is a real open — the application's own menu appears on screen for as long as this
    takes. Measured at ~350ms. The entries stay readable afterwards, so the caller is
    expected to remember them and never ask twice.
    """
    win = focused()
    if win is None:
        return {"path": path, "items": [], "primed": False, "ok": False}
    dm = dbm_for_pid(win["pid"], x11_active_window())
    if dm is not None:
        items = dbm_submenu(dm, path)
        if items:
            return {"path": path, "items": items, "primed": False, "ok": True}
    app = app_for_pid(win["pid"])
    if app is None:
        return {"path": path, "items": [], "primed": False, "ok": False}
    # A nested path ("File/Recent") cannot be resolved against a closed menu bar:
    # in Chromium the inner item does not exist as an object until its parent popup
    # is open. So the walk is allowed to open as it descends, and whatever it opened
    # is closed again below.
    opened = []
    node = resolve(path, app, opening="/" in path, opened=opened)
    if node is None:
        for n in reversed(opened):
            do(n, "close", "open", "click", "doDefault")
        return {"path": path, "items": [], "primed": False, "ok": False}
    kids = children(node)
    items = []
    primed = False
    if kids:
        items = [i for i in (describe(c, 1) for c in kids) if i]
    elif opens_a_menu(node):
        try:
            before = set(popup_sig(x) for x in open_popups(app))
            do(node, "open", "click", "doDefault")
            primed = True
            time.sleep(0.35)
            kids = children(node)
            if not kids:
                # GTK and Qt hang the popup off the item that opened it. Chromium
                # does not — it builds a whole second frame for the popup and
                # leaves the item childless — so it has to be gone and found, and
                # told apart from the popup it came out of.
                pop = find_open_popup(app, before)
                if pop is not None:
                    kids = children(pop)
            # READ IT BEFORE CLOSING IT. These are live references into a popup
            # that the next line destroys; describing them afterwards returned a
            # list of Nones and looked exactly like "this menu is empty", which is
            # how Electron menus came back blank even once they were being found.
            items = [i for i in (describe(c, 1) for c in kids) if i]
            do(node, "close", "open", "click", "doDefault")   # toggle it shut again
        except Exception:
            pass
    for n in reversed(opened):
        do(n, "close", "open", "click", "doDefault")
    if items and win:
        PRIMED.setdefault(win["pid"], {})[path.split("/")[0]] = items
        mem_save(win.get("class") or "", path, items)
    return {"path": path, "items": items, "primed": primed, "ok": bool(items)}


# ------------------------------------------------------------------ doctor ----

def doctor():
    """Say, for every open window, why it does or does not have a menu."""
    rows = []
    for c in (hyprctl("clients") or []):
        if not isinstance(c, dict) or not c.get("pid"):
            continue
        pid = int(c["pid"])
        row = {"class": c.get("class") or "", "pid": pid,
               "title": (c.get("title") or "")[:50]}
        dm = dbm_for_pid(pid, None)
        if dm is not None:
            menus = dbm_menus(dm)
            if menus:
                row["toolkit"] = "dbusmenu"
                row["status"] = "%d menus (exported as data — nothing is opened)" % len(menus)
                row["menus"] = [m["label"] for m in menus]
                rows.append(row)
                continue
        app = app_for_pid(pid)
        if app is None:
            row["status"] = "not on the accessibility bus"
        else:
            row["toolkit"] = toolkit(app)
            menus, why, hint = read_menus(app)
            if menus:
                row["status"] = "%d menus (%s, over accessibility)" % (
                    len(menus),
                    "lazy" if any(m.get("lazy") for m in menus) else "ready")
                row["menus"] = [m["label"] for m in menus]
                if toolkit(app) == "Gecko":
                    row["hint"] = ("turn on widget.gtk.global-menu.enabled + "
                                   ".wayland.enabled in about:config for the export path")
            else:
                row["status"] = why or "no menus"
                if hint:
                    row["hint"] = hint
        rows.append(row)
    return rows



# --------------------------------------------------------------- dbusmenu ----
#
# THE RIGHT WAY, WHERE IT IS AVAILABLE, AND WHY IT IS WORTH TWO CODE PATHS.
#
# Everything above this line is a workaround. AT-SPI describes a menu by walking the
# widgets an application has actually built, which is why Firefox had to be made to
# OPEN each menu before it could be read, and why nested submenus were unreachable at
# any price — Gecko builds those only while their parent is open and hovered.
#
# com.canonical.dbusmenu is not a workaround. It is a menu export: the application
# publishes its whole menu as data, and a single GetLayout(0, -1, []) returns every
# level at once — labels, separators, accelerators as STRUCTURED lists rather than the
# colon-soup AT-SPI hands over, checkbox and radio state as real fields, and the
# submenus AT-SPI could never see. Nothing is opened. Nothing appears on screen. There
# is nothing to remember between runs because asking is free and the answer is always
# current.
#
# Firefox 138+ can do this: widget.gtk.global-menu.enabled (plus the .wayland one).
# It is OFF by default, so `--doctor` says so when it sees a Gecko window with no
# export, because turning it on is the single biggest improvement available here.
#
# WHAT THIS DOES NOT SOLVE. The usual objection is that DBusMenu is keyed by X11
# window id and Wayland has none — the header at the top of this file says exactly
# that, and it is why AT-SPI was chosen. It is still true, and the way around it is
# the same trick: ask the bus which PROCESS owns each connection and match that
# against the focused window's pid. Hyprland does not implement xdg_dbus_annotation_v1
# (the protocol that would tie a surface to a menu path), so where a process exports
# one menu path per window this cannot tell them apart and takes the first non-empty
# one. For Firefox every window's menu bar is the same bar, so that costs nothing
# visible. Electron does not export at all under Wayland — its dbusmenu server is
# global_menu_bar_x11.cc, X11 only — so it stays on AT-SPI.

_BUS = None
_PID_CACHE = {}          # bus name -> pid


def bus():
    global _BUS
    if _BUS is None:
        try:
            _BUS = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        except Exception:
            _BUS = False
    return _BUS or None


def dbus_call(name, path, iface, method, params, sig, timeout=2000):
    b = bus()
    if b is None:
        return None
    try:
        return b.call_sync(name, path, iface, method, GLib.Variant(sig, params),
                           None, Gio.DBusCallFlags.NONE, timeout, None).unpack()
    except Exception:
        return None


def name_gone(name):
    """True only when the bus positively says nobody owns this name.

    The distinction matters: a failed call and an absent owner both come back as None from
    dbus_call, and treating the first as the second throws away state that cannot be
    recovered. Anything other than a clear "false" is read as "still there".
    """
    r = dbus_call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus", "NameHasOwner", (name,), "(s)")
    if not r:
        return False                  # could not ask — assume it is still there
    try:
        return not bool(r[0])
    except Exception:
        return False


def owner_pid(name):
    if name in _PID_CACHE:
        return _PID_CACHE[name]
    r = dbus_call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus", "GetConnectionUnixProcessID", (name,), "(s)")
    pid = r[0] if r else None
    # NEGATIVE ANSWERS ARE NOT CACHED. A unique bus name is never reused, so a pid once
    # learned is true for ever and worth keeping — but "no owner" is a statement about this
    # instant, and it can be wrong: the call races an application that has registered and is
    # still settling, or simply fails. Caching that turned one unlucky moment into a
    # permanent verdict — the window's registration was written off for the life of the
    # daemon, and the app was demoted to the accessibility walk, which is the path that has
    # to OPEN each menu to read it. "Restart Firefox and it reads its menus again" is what
    # that looks like from the outside.
    if pid is not None:
        _PID_CACHE[name] = pid
    return pid


def dbm_paths(name):
    """The /com/canonical/menu/N objects this connection exports."""
    r = dbus_call(name, "/com/canonical/menu", "org.freedesktop.DBus.Introspectable",
                  "Introspect", (), "()")
    if not r:
        # some apps export the object directly with no parent node to introspect
        probe = dbus_call(name, "/com/canonical/menu/0",
                          "org.freedesktop.DBus.Introspectable", "Introspect", (), "()")
        return ["/com/canonical/menu/0"] if probe and "dbusmenu" in probe[0] else []
    out = []
    for chunk in r[0].split('<node name="')[1:]:
        kid = chunk.split('"', 1)[0]
        if kid:
            out.append("/com/canonical/menu/" + kid)
    return out


def dbm_for_pid(pid, xid=None):
    """(bus name, object path) of a menu exported by this process, or None."""
    # An X11 window that announced itself to the registrar is the exact, cheap answer.
    hit = registrar_menu(pid, xid)
    if hit is not None:
        return hit
    for attempt in (0, 1):
        names = dbus_call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                          "org.freedesktop.DBus", "ListNames", (), "()")
        if not names:
            return None
        # Well-known names first: they are few, and a process that exports a menu bar
        # almost always claims one. Falling through every ":1.x" would be a round trip per
        # connection on the session bus, on every focus change.
        ordered = [n for n in names[0] if not n.startswith(":")]
        for n in ordered:
            if owner_pid(n) != pid:
                continue
            for path in dbm_paths(n):
                lay = dbus_call(n, path, "com.canonical.dbusmenu", "GetLayout",
                                (0, 1, []), "(iias)")
                if lay and lay[1][2]:
                    return (n, path)
        # NOTHING MATCHED — which is also what a stale cache looks like. A well-known
        # name survives the application that owned it: restart Firefox and the name is
        # the same while the pid behind it is not, so a cached lookup quietly stopped
        # matching and the whole export path was skipped in favour of the slow one.
        if attempt == 0:
            _PID_CACHE.clear()
    return None


# GTK writes mnemonics into the label as underscores ("_File"); a doubled one is a
# literal underscore. Nothing downstream wants to render those.
def demnemonic(label):
    if "_" not in label:
        return label
    return label.replace("__", "\x00").replace("_", "").replace("\x00", "_")


DBM_MODS = {"control": "Ctrl", "ctrl": "Ctrl", "alt": "Alt", "shift": "Shift",
            "super": "Meta", "meta": "Meta"}


def dbm_accel(shortcut):
    """[["Control","Shift","P"]] -> "Ctrl+Shift+P". Already structured; no guessing."""
    try:
        if not shortcut or not shortcut[0]:
            return ""
        parts = []
        for k in shortcut[0]:
            parts.append(DBM_MODS.get(k.strip().lower(), k))
        return "+".join(parts)
    except Exception:
        return ""


def dbm_item(node, depth=0):
    """One (id, props, children) triple as the bar's own entry shape."""
    try:
        ident, props, kids = node
    except Exception:
        return None
    if props.get("visible", True) is False:
        return None
    if props.get("type") == "separator":
        return {"sep": True}
    label = demnemonic(props.get("label", "") or "")
    if not label:
        return None
    entry = {"label": label, "enabled": bool(props.get("enabled", True)), "id": int(ident)}
    acc = dbm_accel(props.get("shortcut"))
    if acc:
        entry["key"] = acc
    tog = props.get("toggle-type")
    if tog:
        entry["checked"] = (props.get("toggle-state", 0) == 1)
        # RADIO IS NOT A TICK. dbusmenu says which of the two it is and the bar was throwing
        # that away, so a group of mutually exclusive options — Firefox's text encoding,
        # LibreOffice's zoom — drew as a column of checkboxes that all looked independently
        # settable. One dot means "one of these"; a tick means "this is on".
        if str(tog).strip().lower() == "radio":
            entry["radio"] = True
    # The icon the application already chose for this item. Freedesktop name only: the
    # `icon-data` alternative is a raw PNG per item inlined into every snapshot, which is a
    # lot of bytes on a file the bar re-reads, for rows that are mostly iconless anyway.
    ico = props.get("icon-name")
    if ico:
        entry["icon"] = str(ico)
    if kids and depth < MAX_DEPTH:
        sub = [dbm_item(k, depth + 1) for k in kids]
        sub = [x for x in sub if x]
        if sub:
            entry["items"] = sub
    elif props.get("children-display") == "submenu":
        # Exported as a submenu but handed over empty — the application populates it
        # on AboutToShow. Asking is free and invisible, so it is asked for below.
        entry["stub"] = True
    return entry


def dbm_layout(name, path, ident=0, depth=-1):
    lay = dbus_call(name, path, "com.canonical.dbusmenu", "GetLayout",
                    (ident, depth, []), "(iias)", timeout=4000)
    return lay[1] if lay else None


def dbm_menus(target, prime=True):
    """The whole menu bar, every level. Nothing is opened, nothing appears on screen."""
    name, path = target
    root = dbm_layout(name, path)
    if root is None:
        return []
    if prime:
        # ASK EACH MENU, NOT JUST THE ROOT. Gecko hands the whole tree over at the root;
        # Electron answers the root with top-level labels and empty children, and fills a
        # menu in only when told it is ABOUT to be shown. AboutToShow is a data request —
        # it is what a panel sends before drawing, and no popup is mapped by it — so the
        # cost of asking every top-level menu once is a few milliseconds and no flicker.
        asked = False
        for kid in root[2]:
            try:
                ident, props, kids = kid
            except Exception:
                continue
            if kids or props.get("children-display") != "submenu":
                continue
            dbus_call(name, path, "com.canonical.dbusmenu", "AboutToShow",
                      (int(ident),), "(i)")
            asked = True
        if asked:
            time.sleep(0.05)
            root = dbm_layout(name, path) or root
    out = []
    for kid in root[2]:
        it = dbm_item(kid, 1)
        if it and not it.get("sep"):
            out.append(it)
    return out[:MAX_TOP]


def dbm_find(target, path):
    """The numeric id at the end of a 'File/Open' label path."""
    lay = dbus_call(target[0], target[1], "com.canonical.dbusmenu", "GetLayout",
                    (0, -1, []), "(iias)", timeout=4000)
    if not lay:
        return None
    node = lay[1]
    for want in path.split("/"):
        found = None
        for kid in node[2]:
            try:
                if demnemonic(kid[1].get("label", "") or "") == want:
                    found = kid
                    break
            except Exception:
                continue
        if found is None:
            return None
        node = found
    try:
        return int(node[0])
    except Exception:
        return None


def dbm_invoke(target, path):
    ident = dbm_find(target, path)
    if ident is None:
        return False
    # "clicked" with an empty variant is what every dbusmenu host sends.
    r = dbus_call(target[0], target[1], "com.canonical.dbusmenu", "Event",
                  (ident, "clicked", GLib.Variant("s", ""), int(time.time())), "(isvu)")
    return r is not None


def dbm_submenu(target, path):
    """Fill in a submenu that was exported empty. Still nothing on screen."""
    ident = dbm_find(target, path)
    if ident is None:
        return []
    dbus_call(target[0], target[1], "com.canonical.dbusmenu", "AboutToShow",
              (ident,), "(i)")
    lay = dbus_call(target[0], target[1], "com.canonical.dbusmenu", "GetLayout",
                    (ident, -1, []), "(iias)", timeout=4000)
    if not lay:
        return []
    out = [dbm_item(k, 1) for k in lay[1][2]]
    return [x for x in out if x]



# ---------------------------------------------------------------- memory ----
#
# READ ONCE, EVER — NOT ONCE PER FOCUS CHANGE.
#
# `--submenu` runs as its own short-lived process, so anything it learned died with it:
# the daemon never saw the result, and the bar's own copy was thrown away the moment
# focus moved to another window. The effect was that a menu was re-opened and re-read
# every single time you came back to the application, which is the "reading menu" flash
# that made the feature feel slow even though the read itself is only ~350ms.
#
# So it is written down, keyed by window CLASS rather than pid: the point is to survive
# the application being restarted, and a pid does not. What is remembered is structure —
# the labels and shortcuts of a menu — which for File/Edit/View/Help does not change
# between runs of the same program.
#
# THE HONEST LIMIT: menus whose CONTENTS are the data (History, Bookmarks, Recent) go
# stale, because a remembered list is a photograph. That is a real trade and it is the
# reason the dbusmenu path above exists — there, asking is free and always current, so
# none of this file is used at all. `--forget` throws it away.

REMEMBER = os.path.join(CACHE, "appmenu-remembered.json")
MAX_APPS = 24
_MEM = None


def mem_load():
    global _MEM
    if _MEM is None:
        try:
            with open(REMEMBER) as fh:
                j = json.load(fh)
            _MEM = j.get("apps", {}) if isinstance(j, dict) else {}
        except Exception:
            _MEM = {}
    return _MEM


def mem_save(cls, path, items):
    if not cls or not items:
        return
    m = mem_load()
    app = m.setdefault(cls, {})
    app[path] = items
    while len(m) > MAX_APPS:
        m.pop(next(iter(m)))
    try:
        os.makedirs(CACHE, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".remember-")
        with os.fdopen(fd, "w") as fh:
            json.dump({"v": 1, "apps": m}, fh)
        os.replace(tmp, REMEMBER)
    except Exception:
        pass


def mem_remember_tree(cls, menus, prefix=None, depth=0):
    """Store a whole menu tree under `cls`, the way the lazy path stores one menu at a time.

    Bounded: three levels is deeper than any menu bar anyone actually nests, and the point is
    to have the top of the tree ready rather than to mirror the application.
    """
    if not cls or not menus or depth > 2:
        return
    prefix = prefix or []
    m = mem_load()
    app = m.setdefault(cls, {})
    changed = False

    def walk(items, here, d):
        nonlocal changed
        if d > 2:
            return
        for it in items:
            if not isinstance(it, dict) or it.get("sep") or not it.get("label"):
                continue
            kids = it.get("items")
            if not kids:
                continue
            key = "/".join(here + [it["label"]])
            if app.get(key) != kids:
                app[key] = kids
                changed = True
            walk(kids, here + [it["label"]], d + 1)

    walk(menus, prefix, depth)
    if not changed:
        return
    while len(m) > MAX_APPS:
        m.pop(next(iter(m)))
    try:
        os.makedirs(CACHE, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".remember-")
        with os.fdopen(fd, "w") as fh:
            json.dump({"v": 1, "apps": m}, fh)
        os.replace(tmp, REMEMBER)
    except Exception:
        pass


def mem_forget(cls=None):
    global _MEM
    if cls:
        mem_load().pop(cls, None)
        try:
            os.makedirs(CACHE, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".remember-")
            with os.fdopen(fd, "w") as fh:
                json.dump({"v": 1, "apps": _MEM}, fh)
            os.replace(tmp, REMEMBER)
        except Exception:
            pass
        return
    _MEM = {}
    try:
        os.unlink(REMEMBER)
    except Exception:
        pass


def fill_remembered(menus, app_mem, prefix=None):
    """Put what we already know back into a freshly-walked menu bar."""
    prefix = prefix or []
    for m in menus:
        if not isinstance(m, dict) or m.get("sep") or not m.get("label"):
            continue
        here = prefix + [m["label"]]
        key = "/".join(here)
        if m.get("items"):
            fill_remembered(m["items"], app_mem, here)
        elif m.get("lazy") or m.get("stub"):
            got = app_mem.get(key)
            if got:
                m["items"] = got
                m.pop("lazy", None)
                m.pop("stub", None)
                fill_remembered(got, app_mem, here)



# ------------------------------------------------------------- registrar ----
#
# HOW ELECTRON GETS TO BE AS GOOD AS FIREFOX.
#
# Electron cannot publish its menu under Wayland — electron#34335, still open, and the
# reason KDE's own global menu is empty for Electron apps too. Its dbusmenu server is
# global_menu_bar_x11.cc: X11 only. So the accessibility path was the only way in, and it
# is a poor one — the menu has to be really opened to be read, the open is visible, and
# invoking an item opens it again.
#
# But "X11 only" is not "impossible", because XWayland is X11. Run an Electron app with
# --ozone-platform=x11 and that server is live. It then does exactly one thing before
# publishing anything: it looks for com.canonical.AppMenu.Registrar on the session bus,
# and if nobody answers, it gives up and draws its own menu bar instead. Nothing on a
# Hyprland desktop provides that service, which is why the whole approach looks dead from
# the outside — the missing piece is not in Electron, it is that no one is listening.
#
# So we listen. With the registrar up, an Electron window announces its menu the moment it
# maps, keyed by X11 window id, and everything follows: the entire tree in one call, real
# accelerators, nothing opened, nothing flashing — AND the application hides its own menu
# bar, because it now believes something else is drawing it. Which is true.
#
# If some other shell already owns the name, we do not fight it: we become a client of it
# instead and ask it the same question.

REG_NAME = "com.canonical.AppMenu.Registrar"
REG_PATH = "/com/canonical/AppMenu/Registrar"
REG_XML = """
<node><interface name='com.canonical.AppMenu.Registrar'>
  <method name='RegisterWindow'>
    <arg type='u' name='windowId' direction='in'/>
    <arg type='o' name='menuObjectPath' direction='in'/>
  </method>
  <method name='UnregisterWindow'>
    <arg type='u' name='windowId' direction='in'/>
  </method>
  <method name='GetMenuForWindow'>
    <arg type='u' name='windowId' direction='in'/>
    <arg type='s' name='service' direction='out'/>
    <arg type='o' name='menuObjectPath' direction='out'/>
  </method>
  <method name='GetMenus'>
    <arg type='a(uso)' name='menus' direction='out'/>
  </method>
</interface></node>"""

_REG = {}            # X11 window id -> (bus name that registered it, object path)
_REG_OWNED = False   # True once we hold the name ourselves
REG_STATE = os.path.join(CACHE, "appmenu-registered.json")


# A REGISTRATION HAS TO SURVIVE US, NOT THE OTHER WAY AROUND.
#
# An application announces its menu exactly once, when its window maps, and never again.
# So restarting the bar — which restarts this daemon — used to throw away every
# registration on the desktop and there was no way to ask for them back: every Electron
# window stayed menu-less until the user happened to restart it. The registrations are
# still perfectly valid though; what died was only our memory of them. The bus name that
# registered is alive exactly as long as the application is, so writing the table down and
# checking each entry's owner on the way back in is enough to pick up where we left off.

def reg_save():
    try:
        os.makedirs(CACHE, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".reg-")
        with os.fdopen(fd, "w") as fh:
            json.dump({"v": 1, "reg": {str(k): list(v) for k, v in _REG.items()}}, fh)
        os.replace(tmp, REG_STATE)
    except Exception:
        pass


def reg_load():
    try:
        with open(REG_STATE) as fh:
            j = json.load(fh)
    except Exception:
        return
    for k, v in (j.get("reg") or {}).items():
        try:
            wid, sender, path = int(k), v[0], v[1]
        except Exception:
            continue
        # Only if the connection that registered it is still on the bus — otherwise the
        # application is gone and the entry would serve a dead menu under a new window.
        if owner_pid(sender) is not None:
            _REG[wid] = (sender, path)


def _reg_call(conn, sender, path, iface, method, params, inv):
    try:
        if method == "RegisterWindow":
            wid, obj = params.unpack()
            _REG[int(wid)] = (sender, obj)
            reg_save()
            inv.return_value(None)
        elif method == "UnregisterWindow":
            wid, = params.unpack()
            _REG.pop(int(wid), None)
            reg_save()
            inv.return_value(None)
        elif method == "GetMenuForWindow":
            wid, = params.unpack()
            svc, obj = _REG.get(int(wid), ("", "/"))
            inv.return_value(GLib.Variant("(so)", (svc, obj)))
        elif method == "GetMenus":
            out = [(w, v[0], v[1]) for w, v in _REG.items()]
            inv.return_value(GLib.Variant("(a(uso))", (out,)))
        else:
            inv.return_value(None)
    except Exception:
        try:
            inv.return_value(None)
        except Exception:
            pass


def registrar_start():
    """Own the registrar on a thread of its own.

    It needs a running GLib main loop to answer method calls, and the daemon's own loop is
    a blocking read on Hyprland's socket, which pumps nothing. The connection is made
    INSIDE the thread with its own main context pushed as thread-default, so replies are
    dispatched there rather than on a context nobody is running.
    """
    def run():
        try:
            ctx = GLib.MainContext.new()
            ctx.push_thread_default()
            conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            node = Gio.DBusNodeInfo.new_for_xml(REG_XML)
            conn.register_object(REG_PATH, node.interfaces[0], _reg_call, None, None)

            def acquired(*_a):
                global _REG_OWNED
                _REG_OWNED = True
                reg_load()          # windows that registered with the previous daemon

            def lost(*_a):
                global _REG_OWNED
                _REG_OWNED = False

            Gio.bus_own_name_on_connection(
                conn, REG_NAME, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, acquired, lost)
            GLib.MainLoop.new(ctx, False).run()
        except Exception as e:
            sys.stderr.write("sea-appmenu: registrar failed: %s\n" % e)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    # Give the name acquisition a moment so the first snapshot can already use it.
    for _ in range(20):
        if _REG_OWNED:
            break
        time.sleep(0.02)


def x11_active_window():
    """The X11 id of the focused window, when the focused window IS an X11 one.

    Hyprland says whether a client is XWayland but not which X11 window it is, and the
    registrar keys everything by X11 id — so it has to be asked of X itself. _NET_ACTIVE_
    WINDOW is maintained by the compositor for exactly this and costs one round trip.
    """
    try:
        out = subprocess.run(["xprop", "-root", "_NET_ACTIVE_WINDOW"],
                             capture_output=True, timeout=1).stdout.decode()
        for tok in out.split():
            if tok.startswith("0x"):
                return int(tok, 16)
    except Exception:
        pass
    return None


def registrar_menu(pid, xid):
    """(service, path) for a window that registered a menu, or None.

    The X11 id is the exact answer and is tried first; the pid is the fallback for the
    case where xprop is unavailable, and is right except when one process owns several
    windows with different menus.
    """
    if _REG_OWNED:
        if xid is not None:
            hit = _REG.get(xid)
            # THE PID MUST MATCH. _NET_ACTIVE_WINDOW answers with the last X11 window that
            # had focus, and under a Wayland compositor most windows are not X11 at all —
            # so focusing a native Wayland app leaves that property pointing at whatever
            # XWayland window came before it. Trusting the id alone served VS Code's menus
            # under Dolphin's name: the strip looked merely stale, but it was worse than
            # that, because the menu was live and wired to the wrong window.
            if hit and owner_pid(hit[0]) == pid:
                return hit
        for wid, (sender, path) in list(_REG.items()):
            op = owner_pid(sender)
            if op is None:
                # NOT PROOF THAT THE APP IS GONE. This used to delete the registration on
                # the spot, and deleting is the one thing that cannot be undone: the
                # application had already told us where its menu lives and will not say so
                # again until it restarts. One timed-out bus call therefore demoted it to the
                # accessibility path — the path that has to OPEN each menu to read it — for
                # the rest of the session. That is "restart Firefox and it reads its menus
                # again", and it is why it came and went.
                #
                # NameHasOwner answers the actual question, and an ERROR from it is not a NO.
                if name_gone(sender):
                    _REG.pop(wid, None)
                    _PID_CACHE.pop(sender, None)
                    reg_save()
                continue
            if op == pid:
                return (sender, path)
        return None
    # Somebody else owns the registrar — ask them. That "somebody" is usually our own
    # daemon: --invoke, --submenu and --doctor each run as their own short-lived process
    # and hold none of the state the daemon does, so without this they would all conclude
    # that a perfectly well registered window has no menu.
    if xid is not None:
        r = dbus_call(REG_NAME, REG_PATH, REG_NAME, "GetMenuForWindow", (xid,), "(u)")
        if r and r[0] and r[1] and r[1] != "/":
            return (r[0], r[1])
    r = dbus_call(REG_NAME, REG_PATH, REG_NAME, "GetMenus", (), "()")
    if r:
        for wid, svc, path in r[0]:
            if svc and owner_pid(svc) == pid:
                return (svc, path)
    return None



# -------------------------------------------------------------- setup ----
#
# WHAT EACH APPLICATION NEEDS, AND WHY IT CANNOT BE ONE SWITCH.
#
# Three different mechanisms, because three different toolkits:
#
#   Firefox   two prefs, then a restart. It publishes its menu natively after that and
#             needs nothing else, ever.
#   Electron  --ozone-platform=x11, so its dbusmenu server is live and it can answer the
#             registrar this daemon hosts. WHERE that flag goes is the whole difficulty —
#             see below.
#   Qt / GTK  nothing. They hand over their menus for free.
#
# THE FLAGS FILE TRAP. Arch's electron wrappers advertise ~/.config/electron-flags.conf,
# and writing --ozone-platform=x11 there looks like the obvious one-line answer. It is
# not: those wrappers splice flags in BEFORE the app path, electron rejects an unknown
# option in that position, and the application then FAILS TO START AT ALL. It was written
# there during development and would have stopped VS Code launching. So only files known
# to append after the app argument are ever written, and everything else gets a .desktop
# override, where the flag lands in "$@" and is safe.

FIREFOX_PREFS = ("widget.gtk.global-menu.enabled",
                 "widget.gtk.global-menu.wayland.enabled")

APP_DIRS = ["/usr/share/applications",
            os.path.expanduser("~/.local/share/applications")]


def desktop_entries():
    """Every visible application entry, user overrides winning over system ones."""
    found = {}
    for d in APP_DIRS:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".desktop"):
                continue
            ent = {}
            try:
                with open(os.path.join(d, fn), errors="replace") as fh:
                    insec = False
                    for ln in fh:
                        ln = ln.strip()
                        if ln.startswith("["):
                            insec = ln == "[Desktop Entry]"
                            continue
                        if not insec or "=" not in ln:
                            continue
                        k, _, v = ln.partition("=")
                        ent.setdefault(k.strip(), v.strip())
            except Exception:
                continue
            if ent.get("Type") != "Application":
                continue
            if ent.get("NoDisplay", "").lower() == "true":
                continue
            if ent.get("Hidden", "").lower() == "true":
                continue
            ent["_file"] = fn
            found[fn] = ent
    return found


def exec_binary(ent):
    """The executable an Exec= line actually runs, resolved on PATH."""
    ex = ent.get("Exec", "").strip()
    if not ex:
        return None
    tok = ex.split()[0]
    if tok.startswith("env"):                     # `env FOO=1 realbin ...`
        for t in ex.split()[1:]:
            if "=" not in t:
                tok = t
                break
    return shutil.which(tok) or (tok if os.path.isabs(tok) and os.path.exists(tok) else None)


# A flags file is only safe if the wrapper puts it AFTER the app argument. That is a
# property of the wrapper's exec line, so it is read rather than assumed — the electron
# wrappers put flags BEFORE the app path, and writing one there stops the app starting.
def wrapper_flags_file(path):
    try:
        with open(path, errors="replace") as fh:
            txt = fh.read(8192)
    except Exception:
        return None
    conf = None
    for tok in txt.replace('"', " ").replace("'", " ").split():
        if tok.endswith("-flags.conf") or tok.endswith("user-flags.conf"):
            conf = tok
            break
    if not conf:
        return None
    # IS THE FLAGS FILE SAFE TO WRITE? Only if nothing that looks like the APPLICATION
    # comes after it on the exec line. `exec code "$@" $FLAGS` is fine; the electron
    # wrappers do `exec electron "${flags[@]}" "${_RUNNAME}" "$@"`, where the flags land
    # before the app and electron rejects an unknown option in that position — the app then
    # does not start at all. Getting this wrong is not a cosmetic bug, so the rule is
    # positional and conservative: anything unrecognised counts as unsafe.
    # Three shapes have to be told apart, and only the middle one is dangerous:
    #
    #   exec /usr/share/code/bin/code "$@" $CODE_USER_FLAGS
    #        program IS the app; flags last          -> SAFE
    #   exec /usr/lib/electronNN/electron "${flags[@]}" "$@"
    #        generic runtime; the APP arrives in "$@" AFTER the flags   -> UNSAFE
    #   exec electron43 /usr/lib/obsidian/app.asar $OBSIDIAN_USER_FLAGS "$@"
    #        app named before the flags               -> SAFE
    #
    # So "$@" is not harmless filler: for a generic electron wrapper it IS the app path.
    # An earlier version of this rule ignored that and pronounced electron42-flags.conf
    # safe — the one file that stops every Electron app on the system from starting.
    def concrete_app(tok):
        t = tok.strip('"\'')
        low = t.lower()
        if ".asar" in low or low.endswith(".js") or "runname" in low:
            return True
        return t.startswith("/") and os.path.exists(t)

    for ln in txt.split("\n"):
        st = ln.strip()
        if not st.startswith("exec "):
            continue
        toks = st.split()[1:]
        fi = -1
        for i, t in enumerate(toks):
            if "flags" in t.lower() and ("$" in t or "{" in t):
                fi = i
                break
        if fi < 0:
            continue
        before, after = toks[1:fi], toks[fi + 1:]
        if not any(concrete_app(t) for t in before):
            # nothing has named the app yet, so anything app-shaped after the flags —
            # including a bare "$@" — means the flags land in front of it
            if any(concrete_app(t) or t.strip('"\'') == "$@" for t in after):
                return None
        conf = conf.replace("${XDG_CONFIG_HOME:-$HOME/.config}", "~/.config")
        conf = conf.replace("$XDG_CONFIG_HOME", "~/.config").replace("$HOME", "~")
        return conf
    return None


# Launchers that cannot be followed statically — Discord's execs a binary it downloads at
# runtime, through a shell variable — so discovery cannot see what they are. A short list
# beats silently omitting the apps most likely to need setting up.
KNOWN_ELECTRON = [
    {"id": "discord",         "label": "Discord",  "desktop": "discord.desktop"},
    {"id": "slack",           "label": "Slack",    "desktop": "slack.desktop"},
    {"id": "element-desktop", "label": "Element",  "desktop": "element-desktop.desktop"},
    {"id": "spotify",         "label": "Spotify",  "desktop": "spotify.desktop"},
]


ELECTRON_MARKS = ("chrome_crashpad_handler", "resources/app.asar", "chrome-sandbox",
                  "resources.pak", "libffmpeg.so", "snapshot_blob.bin")


def is_electron(binpath, depth=0):
    """Does this launcher end at an Electron binary?

    FOLLOW THE CHAIN. Almost none of these are the real binary: /usr/bin/code is a script
    that execs another script that finally execs /usr/share/code/code, and not one of the
    wrappers contains the word "electron" anywhere. Matching on the script text found
    Obsidian and missed VS Code and Discord entirely, which is worse than useless on a
    setup page — the two apps most likely to need it were the two it did not list.
    So a script is read for what it EXECS and the question asked again of that, and the
    answer only ever comes from artefacts sitting beside a real binary.
    """
    if not binpath or depth > 4:
        return False
    real = os.path.realpath(binpath)
    try:
        with open(real, "rb") as fh:
            head = fh.read(2)
    except Exception:
        return False
    if head == b"#!":
        try:
            with open(real, errors="replace") as fh:
                txt = fh.read(8192)
        except Exception:
            return False
        if "electron" in txt.lower():
            return True
        for ln in txt.split("\n"):
            t = ln.strip()
            if not t.startswith("exec "):
                continue
            for tok in t.split()[1:]:
                tok = tok.strip('"\'')
                if tok.startswith("-") or "=" in tok:
                    continue
                cand = tok
                if not os.path.isabs(cand):
                    cand = shutil.which(cand) or ""
                if cand and os.path.exists(cand) and os.path.realpath(cand) != real:
                    if is_electron(cand, depth + 1):
                        return True
                break
        return False
    d = os.path.dirname(real)
    return any(os.path.exists(os.path.join(d, m)) for m in ELECTRON_MARKS)


def discover_electron():
    """Every installed Electron app, with the safest place to put the flag."""
    out, seen, files = [], set(), set()
    entries = desktop_entries()
    for k in KNOWN_ELECTRON:
        ent = entries.get(k["desktop"])
        if not ent:
            continue
        binp = exec_binary(ent)
        if not binp:
            continue
        seen.add(binp)
        files.add(k["desktop"])
        app = dict(k)
        app["bin"] = binp
        conf = wrapper_flags_file(binp)
        if conf:
            app["flags"] = conf
        out.append(app)
    for fn, ent in entries.items():
        if fn in files:
            continue
        binp = exec_binary(ent)
        if not binp or binp in seen:
            continue
        if not is_electron(binp):
            continue
        seen.add(binp)
        app = {"id": fn[:-8], "bin": binp,
               "label": ent.get("Name") or fn[:-8], "desktop": fn}
        conf = wrapper_flags_file(binp)
        if conf:
            app["flags"] = conf
        out.append(app)
    return out
OZONE = "--ozone-platform=x11"
SETUP_MARK = "# sea-shell global menu"


def _exp(pth):
    return os.path.expanduser(pth)


def firefox_profiles():
    out = []
    for root in (_exp("~/.mozilla/firefox"), _exp("~/.config/mozilla/firefox")):
        if not os.path.isdir(root):
            continue
        for name in os.listdir(root):
            d = os.path.join(root, name)
            if os.path.isdir(d) and os.path.exists(os.path.join(d, "prefs.js")):
                out.append(d)
    return out


def firefox_state():
    profs = firefox_profiles()
    if not profs:
        return None
    done = []
    for d in profs:
        txt = ""
        for f in ("user.js", "prefs.js"):
            try:
                with open(os.path.join(d, f)) as fh:
                    txt += fh.read()
            except Exception:
                pass
        done.append(all(('"%s", true' % p) in txt or ("'%s', true" % p) in txt
                        for p in FIREFOX_PREFS))
    return {"id": "firefox", "label": "Firefox", "kind": "prefs",
            "profiles": profs, "ok": all(done) and bool(done),
            "how": "two prefs in about:config, then restart Firefox"}


def electron_state(app):
    if not (os.path.exists(app["bin"]) or shutil.which(app["bin"])):
        return None
    st = {"id": app["id"], "label": app["label"], "kind": "electron", "ok": False}
    if "flags" in app:
        st["how"] = "add %s to %s" % (OZONE, app["flags"])
        st["target"] = app["flags"]
        try:
            with open(_exp(app["flags"])) as fh:
                st["ok"] = OZONE in fh.read()
        except Exception:
            pass
    else:
        st["how"] = "add %s to a .desktop override" % OZONE
        st["target"] = "~/.local/share/applications/" + app["desktop"]
        try:
            with open(_exp(st["target"])) as fh:
                st["ok"] = OZONE in fh.read()
        except Exception:
            pass
    return st


def setup_check():
    out = []
    ff = firefox_state()
    if ff:
        out.append(ff)
    for a in discover_electron():
        st = electron_state(a)
        if st:
            out.append(st)
    out.sort(key=lambda x: (x.get("ok", False), x.get("label", "")))
    return out


def _append_line(path, line):
    path = _exp(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    old = ""
    try:
        with open(path) as fh:
            old = fh.read()
    except Exception:
        pass
    if line in old:
        return False
    with open(path, "a") as fh:
        if old and not old.endswith("\n"):
            fh.write("\n")
        fh.write("%s\n%s\n" % (SETUP_MARK, line))
    return True


def setup_apply(only=None):
    """Do it. Returns a list of {id, changed, note}."""
    done = []
    for st in setup_check():
        if only and st["id"] not in only:
            continue
        if st.get("ok"):
            done.append({"id": st["id"], "changed": False, "note": "already set up"})
            continue
        try:
            if st["kind"] == "prefs":
                n = 0
                for d in st["profiles"]:
                    u = os.path.join(d, "user.js")
                    for pref in FIREFOX_PREFS:
                        if _append_line(u, 'user_pref("%s", true);' % pref):
                            n += 1
                done.append({"id": st["id"], "changed": n > 0,
                             "note": "restart Firefox to apply"})
            elif "flags" in [k for k in st if k] or st.get("target", "").endswith(".conf"):
                _append_line(st["target"], OZONE)
                done.append({"id": st["id"], "changed": True,
                             "note": "restart the app to apply"})
            else:
                # .desktop override: copy the system entry and add the flag after the
                # executable, before any %-placeholder (after a `--` it would become a
                # positional argument rather than a flag).
                name = os.path.basename(st["target"])
                src = "/usr/share/applications/" + name
                if not os.path.exists(src):
                    done.append({"id": st["id"], "changed": False,
                                 "note": "no system .desktop to copy"})
                    continue
                with open(src) as fh:
                    txt = fh.read()
                out_lines = []
                for ln in txt.split("\n"):
                    if ln.startswith("Exec=") and OZONE not in ln:
                        head, _, rest = ln[5:].partition(" ")
                        ln = "Exec=%s %s %s" % (head, OZONE, rest) if rest \
                            else "Exec=%s %s" % (head, OZONE)
                    out_lines.append(ln)
                dst = _exp(st["target"])
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "w") as fh:
                    fh.write("\n".join(out_lines))
                done.append({"id": st["id"], "changed": True,
                             "note": "restart the app from your launcher to apply"})
        except Exception as e:
            done.append({"id": st["id"], "changed": False, "note": "failed: %s" % e})
    return done


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
    # Up BEFORE the first snapshot and before any app is looked at: an Electron window
    # asks for the registrar once, when it maps, and never asks again. Miss that and the
    # app has already decided to draw its own menu bar for the life of the window.
    registrar_start()
    path = os.path.join(rt, "hypr", sig, ".socket2.sock")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
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
    sweep = 0
    # WHAT EACH WINDOW'S MENU LOOKED LIKE LAST TIME, keyed by pid.
    #
    # Building a snapshot means talking to the application — a DBusMenu GetLayout, or a walk
    # of an accessibility tree — and that is tens to hundreds of milliseconds. Paying it again
    # every time focus lands back on a window you were using a moment ago is what the delay
    # switching between two workspaces actually IS: not the compositor being slow, but the bar
    # having nothing to show until the app answers.
    #
    # A window's menu bar does not change while you are looking at something else, so the last
    # good read of THIS pid is published immediately and the fresh one replaces it if it turns
    # out to differ. Keyed by pid and checked against the class, so it can never serve one
    # application's menus under another's name — the failure this whole feature has been
    # bitten by twice.
    # The pid whose menus are currently in the file. "Did anything change?" is asked
    # against this rather than against the compositor's idea of focus.
    published = None
    snapcache = {}
    # address -> (pid, class), so the hot path never spawns a process.
    #
    # `hyprctl` is a fork+exec+socket round trip: 30-80ms, which is most of the delay you
    # feel switching workspaces. The event already carries the window's address, and the
    # address of a window that existed a moment ago has not changed — so remember what each
    # one resolved to and the cached menus can go up with no subprocess at all.
    addrmap = {}
    # Only focus-shaped events matter. A menu bar does not change because a
    # window moved, and re-walking an accessibility tree on every event would
    # make the daemon the most expensive thing on the desktop.
    # openwindow was missing, and it is the one that fires when you switch to an empty
    # workspace and start something: the app maps and takes focus, and if the only events
    # we listened for were the ones that had already gone past, nothing looked again.
    WANTED = ("activewindow>>", "activewindowv2>>", "workspace>>", "openwindow>>",
              "focusedmon>>", "closewindow>>", "activespecial>>", "movewindow>>")
    while True:
        # Config is re-read each pass so turning priming on or off takes effect
        # without a restart of the bar.
        CFG.update(config())
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            if os.getppid() != parent and parent != 1:
                return 0                      # the bar that started us is gone
            sweep += 1
            if sweep % 15 == 0:
                forget_dead()
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
            txt = line.decode("utf-8", "replace")
            if not txt.startswith(WANTED):
                continue
            addr = None
            if txt.startswith("activewindowv2>>"):
                a = txt.split(">>", 1)[1].strip()
                if a and a.lower() not in ("", ","):
                    addr = a if a.startswith("0x") else "0x" + a
            # AN ADDRESSLESS EVENT IS NOT YET AN ANSWER.
            #
            # A workspace switch, a monitor change or a window closing announces no address,
            # and for a few tens of milliseconds afterwards Hyprland still names the window
            # you just LEFT. Acting on that wrote the previous application's menus into the
            # bar and left them there until the settle pass corrected it — the "delay"
            # switching workspaces was never slowness, it was the wrong answer being shown
            # first and then replaced.
            #
            # But "it still says the old window" and "nothing actually changed" look
            # identical from here, and the honest response to both is to say nothing. The
            # activewindowv2 that carries the real address is usually a millisecond behind
            # this, and the settle pass below is the backstop when it is not. This used to
            # sleep 80ms waiting for that event, which put a floor under every switch; now
            # it just declines to answer and lets the next line do it.
            if addr is None:
                try:
                    e0 = focused(None)
                except Exception:
                    e0 = None
                if e0 is not None and e0.get("pid") == published:
                    if not select.select([s], [], [], 0.25)[0]:
                        again = snapshot()
                        if again.get("pid") != published:
                            retries = RETRY_LIMIT if again.get("menus") else 0
                            published = again.get("pid")
                            write(again)
                    continue
            # PUBLISH WHAT WE ALREADY KNOW, FIRST. Resolving the window is one cheap hyprctl
            # call; reading its menus is the expensive part. If this window has been read
            # before, its menus go up now and the fresh read below only has to confirm them.
            # When the resolve is wrong (the addressless race), the cache it finds is the one
            # already on screen, so publishing early is a no-op rather than a flicker.
            epid, ecls = None, None
            if addr is not None:
                m = addrmap.get(addr.lower())
                if m is not None:
                    epid, ecls = m
            if epid is None:
                try:
                    e = focused(addr)
                    if e is not None:
                        epid, ecls = e["pid"], e.get("class")
                except Exception:
                    pass
            if epid is not None:
                hit = snapcache.get(epid)
                if hit is not None and hit.get("class") == ecls:
                    write(hit)
            snap = snapshot(addr)
            published = snap.get("pid")
            if addr is not None and snap.get("pid"):
                addrmap[addr.lower()] = (snap["pid"], snap.get("class"))
                if len(addrmap) > 128:
                    addrmap.clear()
            if snap.get("menus") and snap.get("pid"):
                snapcache[snap["pid"]] = snap
                if len(snapcache) > 64:
                    live = set()
                    for c in (hyprctl("clients") or []):
                        if isinstance(c, dict) and c.get("pid"):
                            live.add(int(c["pid"]))
                    if live:
                        # Pids are reused. A cache entry outliving its window is the
                        # exact shape of "one app's menus under another app's name".
                        for dead in [q for q in list(snapcache) if q not in live]:
                            snapcache.pop(dead, None)
            # A new window gets a fresh allowance of second looks.
            retries = RETRY_LIMIT if snap.get("menus") else 0
            write(snap)
            # AND SETTLE. The address covers activewindowv2, but a workspace switch or a
            # window closing announces no address at all and those still race — w1 -> w2 ->
            # open an app is exactly that shape. So wait a quarter second for the compositor
            # to catch up, and if nothing else has happened by then, look again. A snapshot
            # costs ~15ms; this is the difference between a blink and a menu that stays
            # wrong until you happen to switch windows.
            if not select.select([s], [], [], 0.25)[0]:
                again = snapshot()
                if (again.get("pid") != snap.get("pid")
                        or len(again.get("menus") or []) != len(snap.get("menus") or [])):
                    retries = RETRY_LIMIT if again.get("menus") else 0
                    published = again.get("pid")
                    write(again)
            if not CFG.get("prime"):
                continue
            # COALESCE. Priming blocks, and a burst of focus events (which is what
            # a workspace switch is) would otherwise queue up one blocking pass per
            # event. Drain whatever arrived while we were not looking and prime once.
            if select.select([s], [], [], 0)[0]:
                continue
            try:
                prime_hidden()
            except Exception:
                pass
            write(snapshot())


def main(argv):
    Atspi.init()
    CFG.update(config())
    if "--daemon" in argv:
        return daemon()
    if "--invoke" in argv:
        print(json.dumps({"ok": invoke(argv[argv.index("--invoke") + 1])}))
        return 0
    if "--submenu" in argv:
        print(json.dumps(submenu(argv[argv.index("--submenu") + 1])))
        return 0
    if "--prime-all" in argv:
        print(json.dumps(prime_all()))
        return 0
    if "--forget" in argv:
        i = argv.index("--forget")
        mem_forget(argv[i + 1] if i + 1 < len(argv) and not argv[i + 1].startswith("-") else None)
        print(json.dumps({"ok": True}))
        return 0
    if "--setup" in argv:
        if "--apply" in argv:
            i = argv.index("--apply")
            only = [a for a in argv[i + 1:] if not a.startswith("-")] or None
            print(json.dumps({"applied": setup_apply(only)}))
        else:
            print(json.dumps({"apps": setup_check()}, indent=2))
        return 0
    if "--doctor" in argv:
        rows = doctor()
        if "--json" in argv:
            print(json.dumps(rows, indent=2))
        else:
            for r in rows:
                print("%-34s pid=%-7s %-10s %s" % (
                    r["class"][:34], r["pid"], r.get("toolkit", "-"), r["status"]))
                if r.get("menus"):
                    print("      " + "  ".join(r["menus"]))
                if r.get("hint"):
                    print("      hint: " + r["hint"])
        return 0
    snap = snapshot()
    if "--write" in argv:
        write(snap)
    print(json.dumps(snap, indent=2 if "--pretty" in argv else None))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
