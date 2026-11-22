#!/usr/bin/env python3
"""Recreate one Xwayland window's mapping after image corruption, without restarting it."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def hypr(*args):
    r = subprocess.run(['hyprctl', *args], capture_output=True, text=True, timeout=5)
    if r.returncode or 'error' in r.stdout.lower():
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return r.stdout


def recover(pid=None):
    from Xlib import X, display
    active = json.loads(hypr('activewindow', '-j'))
    clients = json.loads(hypr('clients', '-j'))
    target = next((c for c in clients if c['pid'] == pid), None) if pid else active
    if not target or not target.get('xwayland'):
        raise RuntimeError('Select an Xwayland window, or pass its PID with --pid.')
    owner = (Path('/proc') / str(target['pid'])).stat().st_uid
    if owner != os.getuid():
        raise RuntimeError('Only windows owned by the current user can be recovered.')
    d = display.Display()
    try:
        atom = d.intern_atom('_NET_WM_PID')
        ids = d.screen().root.get_full_property(d.intern_atom('_NET_CLIENT_LIST'), X.AnyPropertyType)
        matches = []
        for xid in ([] if ids is None else ids.value):
            w = d.create_resource_object('window', int(xid))
            prop = w.get_full_property(atom, X.AnyPropertyType)
            if prop is not None and int(prop.value[0]) == target['pid']:
                matches.append(w)
        if len(matches) != 1:
            raise RuntimeError('Window PID is ambiguous; no windows were changed.')
        w = matches[0]
        try:
            w.unmap()
            d.sync()
            time.sleep(0.25)
        finally:
            w.map()
            d.sync()
        time.sleep(0.5)
        selector = 'address:' + target['address']
        # Remapping can activate application placement rules; restore its prior workspace.
        hypr('dispatch', 'hl.dsp.window.move({ window = ' + json.dumps(selector)
             + ', workspace = ' + str(target['workspace']['id']) + ', follow = false })')
        if active.get('address'):
            hypr('dispatch', 'hl.dsp.focus({ window = '
                 + json.dumps('address:' + active['address']) + ' })')
    finally:
        d.close()
    print('Recreated the window surface; application process was not restarted.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, help='PID of the application window; defaults to focused window')
    args = parser.parse_args()
    try:
        recover(args.pid)
    except (RuntimeError, OSError, ImportError) as e:
        parser.exit(1, str(e) + '\n')

if __name__ == '__main__':
    main()
