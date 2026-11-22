#!/usr/bin/env python3
"""sea-shell — turn the laptop's own screen off when an external display takes over.

Two switches (Settings → Display → laptop screen), both only ever act while an external
display is connected and on — the laptop panel is never turned off when it is the only screen:

  external_only   laptop screen off for as long as an external display is connected.
                  Hyprland composites on the iGPU and copies every frame over to the dGPU
                  for the HDMI port; not also drawing the 165 Hz panel leaves it more room.
  lid_off         laptop screen off while the lid is closed (clamshell), back when it opens.

The panel is *disabled* (not just DPMS-off), so its workspaces move to the external display
and the cursor cannot get lost on a dark screen.

Subcommands:
  --get              print the settings as JSON
  --set KEY 0|1      change one setting and apply it right away
  --sync             apply the settings to the current monitors + lid state once
  --watch            stay resident (started by the bar): re-sync on monitor hotplug, config
                     reload, lid open/close and settings changes

Store: ~/.config/sea-shell/laptop-panel.json
"""
import fcntl
import glob
import json
import os
import select
import socket
import subprocess
import sys
import time

CFG = os.path.expanduser("~/.config/sea-shell/laptop-panel.json")
# sea-display.py --persist remembers every display's mode; reuse it to bring the panel back
# at the refresh rate the user picked instead of "preferred".
PERSIST = os.path.expanduser("~/.config/sea-shell/display-persist.json")
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
# panels this script turned off — only those are turned back on, so a panel the user
# disabled themselves (a display profile, Settings) stays off
STATE = os.path.join(RUNTIME, "sea-panel-off.json")
DEFAULTS = {"external_only": False, "lid_off": True}
INTERNAL = ("eDP", "LVDS", "DSI")


def _hypr(*args):
    try:
        return subprocess.run(["hyprctl", *args], capture_output=True,
                              text=True, timeout=6).stdout
    except Exception:
        return ""


def load_cfg():
    cfg = dict(DEFAULTS)
    try:
        with open(CFG) as f:
            d = json.load(f)
        if isinstance(d, dict):
            cfg.update({k: bool(d[k]) for k in DEFAULTS if k in d})
    except Exception:
        pass
    return cfg


def save_cfg(cfg):
    os.makedirs(os.path.dirname(CFG), exist_ok=True)
    with open(CFG + ".tmp", "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(CFG + ".tmp", CFG)


def _load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def lid_closed():
    for p in glob.glob("/proc/acpi/button/lid/*/state"):
        try:
            with open(p) as f:
                if "closed" in f.read():
                    return True
        except Exception:
            pass
    return False


def _monitors():
    try:
        return json.loads(_hypr("monitors", "all", "-j") or "[]")
    except Exception:
        return []


def _is_internal(m):
    return m.get("name", "").startswith(INTERNAL)


def _enable(m):
    desc = (m.get("description") or "").strip()
    saved = _load_json(PERSIST, {}).get(desc) or {}
    if saved.get("w"):
        mode = "%dx%d@%s" % (saved["w"], saved["h"], saved["rate"])
        pos, scale = "%dx%d" % (saved["x"], saved["y"]), saved["scale"]
    else:
        mode, pos, scale = "preferred", "auto", 1
    # `disabled = false` is required: a rule without it leaves a disabled output disabled
    _hypr("eval", 'hl.monitor({ output = "%s", mode = "%s", position = "%s", scale = %s, disabled = false })'
          % (m["name"], mode, pos, scale))


def sync():
    cfg = load_cfg()
    mons = _monitors()
    if not mons:
        return
    external_on = any(not _is_internal(m) and not m.get("disabled") for m in mons)
    want_off = external_on and (cfg["external_only"] or (cfg["lid_off"] and lid_closed()))
    ours = set(_load_json(STATE, []))
    nothing_on = not any(not m.get("disabled") for m in mons)
    for m in mons:
        if not _is_internal(m):
            continue
        name = m["name"]
        if want_off and not m.get("disabled"):
            _hypr("eval", 'hl.monitor({ output = "%s", disabled = true })' % name)
            ours.add(name)
        elif not want_off and m.get("disabled") and (name in ours or nothing_on):
            _enable(m)
            ours.discard(name)
        elif not m.get("disabled"):
            ours.discard(name)
    with open(STATE + ".tmp", "w") as f:
        json.dump(sorted(ours), f)
    os.replace(STATE + ".tmp", STATE)


def _event_socket():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    path = os.path.join(RUNTIME, "hypr", sig, ".socket2.sock")
    if not sig or not os.path.exists(path):
        # the bar can outlive a compositor restart with a stale signature; take the newest
        socks = sorted(glob.glob(os.path.join(RUNTIME, "hypr", "*", ".socket2.sock")),
                       key=os.path.getmtime)
        if not socks:
            return None
        path = socks[-1]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    return s


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def watch():
    lock = open(os.path.join(RUNTIME, "sea-panel.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return                                 # another watcher already runs
    sock = _event_socket()
    if sock is None:
        return
    sync()
    lid, cfg_m = lid_closed(), _mtime(CFG)
    buf, due = b"", 0.0
    while True:
        r, _, _ = select.select([sock], [], [], 1.0)
        if r:
            chunk = sock.recv(4096)
            if not chunk:
                return                         # compositor gone; the bar restarts us
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for ln in lines:
                ev = ln.split(b">>", 1)[0]
                if ev in (b"monitoradded", b"monitoraddedv2", b"monitorremoved",
                          b"monitorremovedv2", b"configreloaded"):
                    due = time.monotonic() + 0.6   # let a hotplugged output finish modesetting
        # the lid has no Hyprland event; the ACPI state file is cheap to poll
        now_lid, now_cfg = lid_closed(), _mtime(CFG)
        if now_lid != lid or now_cfg != cfg_m:
            lid, cfg_m = now_lid, now_cfg
            due = due or time.monotonic()
        if due and time.monotonic() >= due:
            due = 0.0
            sync()


def main(argv):
    op = argv[0] if argv else "--get"
    if op == "--get":
        laptop = bool(glob.glob("/proc/acpi/button/lid/*")) or any(_is_internal(m) for m in _monitors())
        print(json.dumps({**load_cfg(), "laptop": laptop}))
    elif op == "--set" and len(argv) > 2 and argv[1] in DEFAULTS:
        cfg = load_cfg()
        cfg[argv[1]] = argv[2] in ("1", "true", "on")
        save_cfg(cfg)
        sync()
        print(json.dumps(cfg))
    elif op == "--sync":
        sync()
    elif op == "--watch":
        watch()
    else:
        print(json.dumps({"ok": False, "error": "usage"}))
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
