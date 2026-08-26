#!/usr/bin/env python3
"""sea_fm_fm1 — sea-fm answering org.freedesktop.FileManager1.

WHY THE MIME ASSOCIATION IS NOT ENOUGH.

Setting `inode/directory` to sea-fm makes `xdg-open /some/folder` do the right
thing, and that is what most of the desktop uses. But "reveal this file" is a
different question — it asks for a folder to be opened *with one item selected*,
which a MIME handler has no way to express — and the answer to it is a D-Bus
interface instead:

    org.freedesktop.FileManager1
        ShowFolders(as uris, s startup_id)
        ShowItems(as uris, s startup_id)              -- open parent, select item
        ShowItemProperties(as uris, s startup_id)

Firefox's "Open Containing Folder", Chromium's "Show in folder", Steam, VS Code
and most Electron applications call that, not xdg-open. The name is claimed by
whichever file manager shipped a D-Bus service file — on a machine with GNOME's
packages installed that is Nautilus — and it is claimed regardless of what the
MIME database says, so sea-fm could be the declared file manager and still never
see one of these. Which is exactly what happened.

So sea-fm answers it too. The service file that points the name at us lives in
$XDG_DATA_HOME/dbus-1/services, which the session bus searches BEFORE the system
directories, and it is written by sea-defaults.py only while sea-fm is the chosen
file manager — taking the name from Nautilus is a thing to do because the user
asked for it, not because we happen to be installed.

WHY A THREAD. The same reason sea_fm_menu.py uses one: answering a method call
needs a GLib main loop running the context the object was registered on. Qt
happens to pump the default GLib context today, but that is a property of its
event dispatcher and not a promise. Requests cross back to Qt as signals, which
is a queued delivery, so the handler runs on Qt's own thread and may touch QML.
"""

import os
import threading
from urllib.parse import unquote, urlparse

HAVE_GI = True
try:
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import GLib, Gio
except Exception:                                     # pragma: no cover
    HAVE_GI = False

from PySide6.QtCore import QObject, Signal

BUS_NAME = "org.freedesktop.FileManager1"
OBJ_PATH = "/org/freedesktop/FileManager1"

INTROSPECTION = """
<node>
  <interface name="org.freedesktop.FileManager1">
    <method name="ShowFolders">
      <arg type="as" name="URIs" direction="in"/>
      <arg type="s" name="StartupId" direction="in"/>
    </method>
    <method name="ShowItems">
      <arg type="as" name="URIs" direction="in"/>
      <arg type="s" name="StartupId" direction="in"/>
    </method>
    <method name="ShowItemProperties">
      <arg type="as" name="URIs" direction="in"/>
      <arg type="s" name="StartupId" direction="in"/>
    </method>
  </interface>
</node>
"""


def path_from_uri(uri):
    """file:// URIs only. Anything else is not ours to open."""
    if not uri:
        return ""
    if uri.startswith("/"):
        return uri                      # some callers pass a bare path
    parsed = urlparse(uri)
    if parsed.scheme and parsed.scheme != "file":
        return ""
    return unquote(parsed.path or "")


class FileManager1(QObject):
    """Owns the name and turns calls into Qt signals on the main thread."""

    showFolders = Signal(list)          # [path, ...]
    showItems = Signal(list)            # [path, ...] — select each in its parent
    showItemProperties = Signal(list)   # [path, ...]

    def __init__(self, parent=None):
        super().__init__(parent)
        self._conn = None
        self._owned = threading.Event()

    def start(self):
        """Own the name, if nobody already has it. False if we could not."""
        if not HAVE_GI:
            return False
        threading.Thread(target=self._run, name="sea-fm-fm1", daemon=True).start()
        self._owned.wait(0.8)
        return self._conn is not None and self._owned.is_set()

    # ---- the thread ----------------------------------------------------

    def _run(self):
        try:
            ctx = GLib.MainContext.new()
            ctx.push_thread_default()
            conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            self._conn = conn
            node = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION)
            conn.register_object(OBJ_PATH, node.interfaces[0], self._call, None, None)

            def acquired(*_a):
                self._owned.set()

            # DO_NOT_QUEUE: if another file manager already holds the name we do
            # not want to be handed it later, when the user has long since gone
            # somewhere else. Not owning it is a fine outcome — it means
            # something else is answering, and one of us should.
            Gio.bus_own_name_on_connection(
                conn, BUS_NAME, Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
                acquired, lambda *_a: None)
            GLib.MainLoop.new(ctx, False).run()
        except Exception as exc:                      # pragma: no cover
            import sys
            sys.stderr.write("sea-fm: FileManager1 export failed: %s\n" % exc)

    def _call(self, _conn, _sender, _path, _iface, method, params, invocation):
        try:
            uris = list(params[0]) if params and len(params) else []
            paths = [p for p in (path_from_uri(u) for u in uris) if p]
            if method == "ShowFolders":
                self.showFolders.emit(paths)
            elif method == "ShowItems":
                self.showItems.emit(paths)
            elif method == "ShowItemProperties":
                self.showItemProperties.emit(paths)
            else:
                invocation.return_error_literal(
                    Gio.dbus_error_quark(),
                    Gio.DBusError.UNKNOWN_METHOD, "no such method")
                return
            # Answered immediately. The caller is waiting to know the request was
            # accepted, not for a window to finish appearing, and blocking it
            # until then is how "open containing folder" comes to feel slow.
            invocation.return_value(None)
        except Exception as exc:                      # pragma: no cover
            try:
                invocation.return_error_literal(
                    Gio.dbus_error_quark(), Gio.DBusError.FAILED, str(exc))
            except Exception:
                pass

# The service file that points the name here is written by sea-defaults.py, when
# you choose sea-fm as your file manager — see install_filemanager1_service()
# there. It is not written from this side, because claiming the name for good is
# a decision about defaults and this file only answers what arrives.
