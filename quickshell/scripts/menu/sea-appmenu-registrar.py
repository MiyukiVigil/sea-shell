#!/usr/bin/env python3
"""Tiny AppMenu registrar sidecar for the Rust sea-appmenu daemon.

No Atspi — only Gio — so RSS stays small. Persists registrations across restarts
the same way sea-appmenu.py does (appmenu-registered.json).
"""
import json
import os
import sys
import tempfile
import time

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME",
                     os.path.join(os.path.expanduser("~"), ".cache")),
                     "sea-shell")
REG_NAME = "com.canonical.AppMenu.Registrar"
REG_PATH = "/com/canonical/AppMenu/Registrar"
REG_STATE = os.path.join(CACHE, "appmenu-registered.json")
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

_REG = {}
_OWNED = False


def save():
    try:
        os.makedirs(CACHE, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=".reg-")
        with os.fdopen(fd, "w") as fh:
            json.dump({"v": 1, "reg": {str(k): list(v) for k, v in _REG.items()}}, fh)
        os.replace(tmp, REG_STATE)
    except Exception:
        pass


def load(conn):
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
        try:
            # Keep only live senders
            conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                           "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                           GLib.Variant("(s)", (sender,)),
                           GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 500, None)
            _REG[wid] = (sender, path)
        except Exception:
            pass


def on_call(conn, sender, _opath, _iface, method, params, inv):
    try:
        if method == "RegisterWindow":
            wid, obj = params.unpack()
            _REG[int(wid)] = (sender, obj)
            save()
            inv.return_value(None)
        elif method == "UnregisterWindow":
            wid, = params.unpack()
            _REG.pop(int(wid), None)
            save()
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


def main():
    global _OWNED
    ctx = GLib.MainContext.new()
    ctx.push_thread_default()
    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    node = Gio.DBusNodeInfo.new_for_xml(REG_XML)
    conn.register_object(REG_PATH, node.interfaces[0], on_call, None, None)

    def acquired(*_a):
        global _OWNED
        _OWNED = True
        load(conn)

    def lost(*_a):
        global _OWNED
        _OWNED = False

    Gio.bus_own_name_on_connection(
        conn, REG_NAME, Gio.BusNameOwnerFlags.DO_NOT_QUEUE, acquired, lost)
    for _ in range(50):
        if _OWNED:
            break
        time.sleep(0.02)
    if not _OWNED:
        sys.stderr.write("sea-appmenu-registrar: name not acquired (someone else owns it)\n")
    GLib.MainLoop.new(ctx, False).run()


if __name__ == "__main__":
    main()
