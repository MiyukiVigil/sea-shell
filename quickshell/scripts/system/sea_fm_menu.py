#!/usr/bin/env python3
"""sea_fm_menu — sea-fm's own menu bar, published for the shell's global menu.

WHY DBUSMENU AND NOT ACCESSIBILITY.  sea-appmenu reads most applications through
AT-SPI, because that is the only thing that answers for a GTK or Qt Widgets app
under Wayland.  sea-fm is neither: it is a Qt Quick window with no QMenuBar
anywhere in it, so there is no menu bar for the accessibility walk to find and
never will be.  What sea-appmenu tries FIRST, though, is the export — an
application that publishes com.canonical.dbusmenu hands over its whole tree as
data in one call, with nothing opened on screen and no lazy/stub machinery at
all.  That path is open to us because we are the ones deciding what to publish.

HOW IT IS FOUND.  The usual registrar keys menus by X11 window id, which does
not exist under Wayland, so the interesting question is how sea-appmenu maps a
focused window back to a menu.  It does it by pid, two ways, and this file
satisfies both:

  1. It registers with com.canonical.AppMenu.Registrar (sea-appmenu owns that
     name itself).  There is no window id to give, so the pid goes in that slot —
     the registrar's lookup falls back to matching the *owner pid* of whoever
     registered, so a made-up id costs nothing and the entry resolves correctly.
     This is the cheap path: one call, no scanning.
  2. Failing that, sea-appmenu walks the WELL-KNOWN names on the session bus
     looking for one owned by the focused pid that exports a menu.  It never
     falls through to unique ":1.x" names — that would be a round trip per
     connection on every focus change — so claiming a well-known name is not
     optional.  Hence org.seashell.SeaFM, or .p<pid> when a window already has it.

WHY A THREAD.  Answering a method call needs a GLib main loop running the context
the object was registered on.  Qt on Linux happens to pump the *default* GLib
context, so registering there does work today — but that is a property of Qt's
event dispatcher, not a promise (QT_NO_GLIB=1 turns it off), and a global menu
that silently stops answering is worse than one that was never there.  So the
service gets its own context on its own thread, the same shape sea-appmenu's
registrar uses.  Nothing is shared across that boundary except two things:

  - the model, republished as ONE immutable snapshot per change and read whole,
    so a call in flight sees either the old tree or the new one, never a half-
    rebuilt one;
  - activations, which travel back as a Qt signal.  Emitting a signal from a
    foreign thread to a QObject living on the main thread is a queued delivery,
    so the handler runs on Qt's thread and may touch QML freely.

WHO OWNS THE MENU.  Not this file.  The tree arrives from QML as JSON, because
that is where the commands, their shortcuts and — the part that actually matters
— the conditions under which they are enabled already live, as bindings.  This
file turns that into dbusmenu properties, hands out the integer ids the protocol
insists on, and reports which command a click landed on.  It knows nothing about
files.
"""

import json
import os
import threading

HAVE_GI = True
try:
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import GLib, Gio
except Exception:                                        # pragma: no cover
    HAVE_GI = False

from PySide6.QtCore import QObject, Signal, Slot


MENU_PATH = "/com/canonical/menu/0"
BUS_NAME = "org.seashell.SeaFM"
REG_NAME = "com.canonical.AppMenu.Registrar"
REG_PATH = "/com/canonical/AppMenu/Registrar"
REG_IFACE = "com.canonical.AppMenu.Registrar"

# The full interface, not the subset sea-appmenu happens to call. The point of
# exporting at all is that ANY dbusmenu host can draw this window's menus, and a
# host that asks for GetGroupProperties and gets an error draws nothing.
MENU_XML = """
<node>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg type="i" name="parentId" direction="in"/>
      <arg type="i" name="recursionDepth" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="u" name="revision" direction="out"/>
      <arg type="(ia{sv}av)" name="layout" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="a(ia{sv})" name="properties" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="name" direction="in"/>
      <arg type="v" name="value" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="eventId" direction="in"/>
      <arg type="v" name="data" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg type="a(isvu)" name="events" direction="in"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg type="i" name="id" direction="in"/>
      <arg type="b" name="needUpdate" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="ai" name="updatesNeeded" direction="out"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})" name="updatedProps" direction="out"/>
      <arg type="a(ias)" name="removedProps" direction="out"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u" name="revision" direction="out"/>
      <arg type="i" name="parent" direction="out"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i" name="id" direction="out"/>
      <arg type="u" name="timestamp" direction="out"/>
    </signal>
  </interface>
</node>
"""

# dbusmenu spells modifiers out in full, and hosts match on those exact words.
_MODS = {"ctrl": "Control", "control": "Control", "alt": "Alt",
         "shift": "Shift", "meta": "Super", "super": "Super"}

# Qt names some keys in ways no menu should show. The label side of a shortcut is
# purely cosmetic, so it is worth spelling them the way a keyboard does.
_KEYS = {"page_down": "Page_Down", "page_up": "Page_Up", "return": "Return",
         "del": "Delete", "esc": "Escape", "space": "Space"}


def accel_parts(seq):
    """'Ctrl+Shift+N' -> ['Control', 'Shift', 'N'], the shape dbusmenu wants."""
    out = []
    for tok in str(seq).split("+"):
        tok = tok.strip()
        if not tok:
            # A trailing empty token is the '+' key itself, as in Ctrl++.
            out.append("plus")
            continue
        low = tok.lower()
        if low in _MODS:
            out.append(_MODS[low])
        elif low in _KEYS:
            out.append(_KEYS[low])
        else:
            out.append(tok if len(tok) > 1 else tok.upper())
    return out


class AppMenu(QObject):
    """The window's menu bar as a DBus export.

    Call `start()` once, push a tree with `setMenu()` whenever it changes, and
    connect to `triggered` — which fires on the Qt thread with the `cmd` string
    of whatever was clicked.
    """

    triggered = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._nodes = {0: {"props": {}, "kids": []}}   # published snapshot
        self._cmds = {}                                # id -> command string
        self._revision = 1
        self._conn = None
        self._name = ""
        self._owned = threading.Event()
        self._registered = False
        self._reg_id = os.getpid()

    # ------------------------------------------------------------ lifecycle --

    @property
    def busName(self):
        return self._name

    def start(self):
        """Own a name and export the object. False if there is nothing to do it with."""
        if not HAVE_GI:
            return False
        threading.Thread(target=self._run, name="sea-fm-menu", daemon=True).start()
        # The first setMenu() usually lands within a frame or two of this, and a
        # push that arrives before the connection exists is simply kept as the
        # snapshot — so there is no need to block on acquisition here beyond
        # giving it the moment it takes, which keeps startup honest in the log.
        self._owned.wait(0.6)
        return self._conn is not None

    def _run(self):
        try:
            ctx = GLib.MainContext.new()
            ctx.push_thread_default()
            conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            info = Gio.DBusNodeInfo.new_for_xml(MENU_XML)
            conn.register_object_with_closures2(
                MENU_PATH, info.interfaces[0], self._call, self._get, None)
            self._conn = conn

            def acquired(_c, name, *_a):
                self._name = name
                self._owned.set()
                self._register_window()

            def lost(_c, _name, *_a):
                self._owned.clear()

            # DO_NOT_QUEUE, then fall back to a pid-suffixed name. Queueing would
            # mean a second window sits behind the first holding no name at all,
            # and sea-appmenu only ever looks at well-known names — so that window
            # would have no menu until the first one closed.
            Gio.bus_own_name_on_connection(
                conn, BUS_NAME, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, acquired,
                lambda *_a: self._own_fallback(conn, acquired, lost))
            GLib.MainLoop.new(ctx, False).run()
        except Exception as exc:                          # pragma: no cover
            import sys
            sys.stderr.write("sea-fm: menu export failed: %s\n" % exc)

    def _own_fallback(self, conn, acquired, lost):
        alt = "%s.p%d" % (BUS_NAME, os.getpid())
        if self._name == alt:
            return
        Gio.bus_own_name_on_connection(
            conn, alt, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, acquired, lost)

    def _register_window(self):
        """Tell the registrar, if one is listening. Best effort by design.

        There is no window id under Wayland, so the pid goes in that slot; the
        registrar resolves by owner pid anyway. If nobody owns the registrar name
        this call fails and nothing is lost — the name scan still finds us.
        """
        try:
            self._conn.call_sync(
                REG_NAME, REG_PATH, REG_IFACE, "RegisterWindow",
                GLib.Variant("(uo)", (self._reg_id, MENU_PATH)),
                None, Gio.DBusCallFlags.NONE, 1500, None)
            self._registered = True
        except Exception:
            self._registered = False

    def stop(self):
        if self._conn is None or not self._registered:
            return
        try:
            self._conn.call_sync(
                REG_NAME, REG_PATH, REG_IFACE, "UnregisterWindow",
                GLib.Variant("(u)", (self._reg_id,)),
                None, Gio.DBusCallFlags.NONE, 500, None)
        except Exception:
            pass

    # ---------------------------------------------------------------- model --

    @Slot(str)
    def setMenu(self, spec_json):
        """Replace the tree. `spec_json` is a JSON array of top-level menus."""
        try:
            spec = json.loads(spec_json)
        except Exception:
            return
        if not isinstance(spec, list):
            return
        nodes, cmds = self._build(spec)
        # ONE assignment each, and the reader takes its own reference first, so a
        # GetLayout running on the other thread can never see half a rebuild.
        self._nodes = nodes
        self._cmds = cmds
        self._revision += 1
        self._emit_layout_updated()

    def _build(self, spec):
        nodes = {}
        cmds = {}
        counter = [0]

        def walk(items):
            kids = []
            for it in items:
                if not isinstance(it, dict):
                    continue
                counter[0] += 1
                ident = counter[0]
                props = {}
                if it.get("sep"):
                    props["type"] = ("s", "separator")
                    nodes[ident] = {"props": props, "kids": []}
                    kids.append(ident)
                    continue
                props["label"] = ("s", str(it.get("label", "")))
                props["enabled"] = ("b", bool(it.get("enabled", True)))
                props["visible"] = ("b", bool(it.get("visible", True)))
                if it.get("key"):
                    props["shortcut"] = ("aas", [accel_parts(it["key"])])
                if it.get("icon"):
                    props["icon-name"] = ("s", str(it["icon"]))
                if it.get("radio"):
                    props["toggle-type"] = ("s", "radio")
                    props["toggle-state"] = ("i", 1 if it.get("checked") else 0)
                elif it.get("check"):
                    props["toggle-type"] = ("s", "checkmark")
                    props["toggle-state"] = ("i", 1 if it.get("checked") else 0)
                nodes[ident] = {"props": props, "kids": []}
                kids.append(ident)
                sub = it.get("items")
                if isinstance(sub, list) and sub:
                    props["children-display"] = ("s", "submenu")
                    nodes[ident]["kids"] = walk(sub)
                elif it.get("cmd"):
                    cmds[ident] = str(it["cmd"])
            return kids

        root = walk(spec)
        nodes[0] = {"props": {"children-display": ("s", "submenu")}, "kids": root}
        return nodes, cmds

    # ------------------------------------------------------------ dbus side --

    def _props(self, node, wanted):
        out = {}
        for key, (sig, val) in node["props"].items():
            if wanted and key not in wanted:
                continue
            out[key] = GLib.Variant(sig, val)
        return out

    def _layout(self, nodes, ident, depth, wanted):
        node = nodes.get(ident)
        if node is None:
            return None
        kids = []
        if depth != 0:
            deeper = -1 if depth < 0 else depth - 1
            for kid in node["kids"]:
                sub = self._layout(nodes, kid, deeper, wanted)
                if sub is not None:
                    kids.append(GLib.Variant("(ia{sv}av)", sub))
        return (ident, self._props(node, wanted), kids)

    def _emit_layout_updated(self):
        conn = self._conn
        if conn is None:
            return
        try:
            conn.emit_signal(None, MENU_PATH, "com.canonical.dbusmenu",
                             "LayoutUpdated",
                             GLib.Variant("(ui)", (self._revision, 0)))
        except Exception:
            pass

    def _get(self, _conn, _sender, _path, _iface, name, *_a):
        if name == "Version":
            return GLib.Variant("u", 3)
        if name == "Status":
            return GLib.Variant("s", "normal")
        if name == "TextDirection":
            return GLib.Variant("s", "ltr")
        if name == "IconThemePath":
            return GLib.Variant("as", [])
        return None

    def _call(self, _conn, _sender, _path, _iface, method, params, inv):
        try:
            nodes = self._nodes                 # take the snapshot once
            if method == "GetLayout":
                parent, depth, names = params.unpack()
                lay = self._layout(nodes, int(parent), int(depth), set(names))
                if lay is None:
                    lay = (int(parent), {}, [])
                inv.return_value(GLib.Variant("(u(ia{sv}av))",
                                              (self._revision, lay)))
            elif method == "GetGroupProperties":
                ids, names = params.unpack()
                wanted = set(names)
                # An empty id list means "every item", which is what a host asks
                # when it wants to refresh states without re-reading the layout.
                todo = [int(i) for i in ids] if ids else list(nodes.keys())
                out = [(i, self._props(nodes[i], wanted))
                       for i in todo if i in nodes]
                inv.return_value(GLib.Variant("(a(ia{sv}))", (out,)))
            elif method == "GetProperty":
                ident, name = params.unpack()
                node = nodes.get(int(ident))
                got = (node or {"props": {}})["props"].get(name)
                inv.return_value(GLib.Variant(
                    "(v)", (GLib.Variant(got[0], got[1]) if got
                            else GLib.Variant("s", ""),)))
            elif method == "Event":
                ident, event_id, _data, _ts = params.unpack()
                self._fire(int(ident), event_id)
                inv.return_value(None)
            elif method == "EventGroup":
                events, = params.unpack()
                for ev in events:
                    try:
                        self._fire(int(ev[0]), ev[1])
                    except Exception:
                        pass
                inv.return_value(GLib.Variant("(ai)", ([],)))
            elif method == "AboutToShow":
                # Everything is published up front, so there is never anything to
                # fetch: false means "already current", and saves the host a round
                # trip it would otherwise make before every menu it draws.
                inv.return_value(GLib.Variant("(b)", (False,)))
            elif method == "AboutToShowGroup":
                inv.return_value(GLib.Variant("(aiai)", ([], [])))
            else:
                inv.return_value(None)
        except Exception as exc:
            try:
                inv.return_error_literal(Gio.dbus_error_quark(), 0, str(exc))
            except Exception:
                pass

    def _fire(self, ident, event_id):
        if event_id != "clicked":
            return
        cmd = self._cmds.get(ident)
        if cmd:
            # Queued: the receiver lives on the Qt thread, so the handler runs
            # there and can touch QML directly.
            self.triggered.emit(cmd)
