#!/usr/bin/env python3
"""sea-kdeconnect — JSON bridge between the KDE Connect daemon and the shell.

Everything goes over D-Bus (`busctl --json=short`) rather than kdeconnect-cli:
one call per interface instead of one process per property, and JSON out
instead of `s "some name"` lines that break on quotes in a device name.

  --list                    print the device array once and exit
  --watch                   print it again on every change (D-Bus driven)

  --pair | --unpair | --accept | --reject   <id>
  --ring <id>               ring the phone (findmyphone)
  --ping <id>               send a ping notification
  --send-file <id> [path…]  share files — no path opens a file picker
  --send-clipboard <id>     send this machine's clipboard to the device
  --browse <id>             mount the device over sftp and open the file manager
  --sms <id>                open the SMS app for the device
"""
import json
import os
import re
import select
import shutil
import subprocess
import sys
import time

BUS = "org.kde.kdeconnect"
ROOT = "/modules/kdeconnect"
DEV_IFACE = "org.kde.kdeconnect.device"

# how long the watcher waits after a D-Bus signal before re-reading (signals
# arrive in bursts — one battery refresh fans out to several properties)
DEBOUNCE = 0.35
# safety-net re-read, in case a plugin changes state without signalling
FULL_POLL = 20.0


def dev_path(dev_id, plugin=""):
    return "%s/devices/%s%s" % (ROOT, dev_id, "/" + plugin if plugin else "")


def busctl(args, timeout=6):
    """Run busctl and parse its JSON. None on any failure — callers decide."""
    try:
        res = subprocess.run(["busctl", "--user", "--json=short"] + args,
                             capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    out = res.stdout.strip()
    if not out:
        return {}
    try:
        return json.loads(out)
    except ValueError:
        return None


def get_props(path, iface):
    """All properties of one interface in a single call, unwrapped from a{sv}."""
    res = busctl(["call", BUS, path, "org.freedesktop.DBus.Properties", "GetAll", "s", iface])
    if not res:
        return {}
    data = res.get("data") or []
    if not data or not isinstance(data[0], dict):
        return {}
    return {k: v.get("data") for k, v in data[0].items()}


def call(path, iface, member, signature="", *args):
    argv = ["call", BUS, path, iface, member]
    if signature:
        argv.append(signature)
        argv.extend(str(a) for a in args)
    return busctl(argv, timeout=25)


def notify(body, summary="KDE Connect", icon="smartphone", urgency="normal"):
    try:
        subprocess.Popen(["notify-send", "-a", "sea-shell", "-i", icon,
                          "-u", urgency, summary, body],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


# ---------------------------------------------------------------- discovery

def device_ids():
    """Every known device id. None (not []) when the daemon can't be reached."""
    res = busctl(["call", BUS, ROOT, "org.kde.kdeconnect.daemon", "devices", "bb", "false", "false"])
    if res is None:
        return None
    data = res.get("data") or []
    return data[0] if data and isinstance(data[0], list) else []


PLUGIN_PATH = re.compile(r"/modules/kdeconnect/devices/([0-9a-zA-Z_.-]+)/([a-z_0-9]+)\s*$")


def loaded_plugins():
    """dev id → set of *enabled* plugins, read from the object tree in one call.

    `supportedPlugins` lists what the phone can do; a plugin only gets an object
    path once it is actually loaded here, which is what the UI has to gate on.
    """
    out = {}
    try:
        res = subprocess.run(["busctl", "--user", "tree", BUS],
                             capture_output=True, text=True, timeout=6)
    except (OSError, subprocess.SubprocessError):
        return out
    for line in res.stdout.splitlines():
        m = PLUGIN_PATH.search(line.rstrip())
        if m:
            out.setdefault(m.group(1), set()).add(m.group(2))
    return out


def get_devices():
    ids = device_ids()
    if not ids:
        return []
    plugins = loaded_plugins()
    devices = []
    for dev_id in ids:
        p = get_props(dev_path(dev_id), DEV_IFACE)
        if not p or "name" not in p:
            continue
        loaded = plugins.get(dev_id, set())
        paired = bool(p.get("isPaired"))
        reachable = bool(p.get("isReachable"))

        charge, charging = -1, False
        if reachable and "battery" in loaded:
            b = get_props(dev_path(dev_id, "battery"), DEV_IFACE + ".battery")
            charge = b.get("charge", -1)
            charging = bool(b.get("isCharging"))

        signal, network = -1, ""
        if reachable and "connectivity_report" in loaded:
            c = get_props(dev_path(dev_id, "connectivity_report"), DEV_IFACE + ".connectivity_report")
            signal = c.get("cellularNetworkStrength", -1)
            network = c.get("cellularNetworkType", "") or ""

        devices.append({
            "id": dev_id,
            "name": p.get("name", dev_id),
            "type": p.get("type", "desktop"),
            "isPaired": paired,
            "isReachable": reachable,
            "verificationKey": p.get("verificationKey", ""),
            "isPairRequested": bool(p.get("isPairRequested")),
            "isPairRequestedByPeer": bool(p.get("isPairRequestedByPeer")),
            "address": (p.get("reachableAddresses") or [""])[0],
            "charge": charge,
            "isCharging": charging,
            "signal": signal,
            "network": network,
            # the actions the bar is allowed to offer for this device
            "canRing": "findmyphone" in loaded,
            "canPing": "ping" in loaded,
            "canShare": "share" in loaded,
            "canClipboard": "clipboard" in loaded,
            "canBrowse": "sftp" in loaded,
            "canSms": "sms" in loaded,
        })

    # online first, then paired-but-away, then everything else — the bar shows
    # devices[0] when nothing is explicitly selected
    devices.sort(key=lambda d: (not (d["isPaired"] and d["isReachable"]),
                                not d["isPaired"], d["name"].lower()))
    return devices


def ensure_daemon():
    """Start kdeconnectd if it isn't on the bus (it is not D-Bus activatable)."""
    if device_ids() is not None:
        return
    for cand in ("kdeconnectd", "/usr/lib/kdeconnectd", "/usr/lib/kdeconnect/kdeconnectd"):
        path = shutil.which(cand) if "/" not in cand else (cand if os.path.exists(cand) else None)
        if not path:
            continue
        try:
            subprocess.Popen([path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError:
            continue
        for _ in range(20):          # give it up to ~2s to claim the name
            time.sleep(0.1)
            if device_ids() is not None:
                return
        return


# ------------------------------------------------------------------- watch

def watch():
    """Stream the device array — one compact JSON line per actual change."""
    ensure_daemon()
    mon = None
    try:
        mon = subprocess.Popen(
            ["dbus-monitor", "--session", "type='signal',path_namespace='" + ROOT + "'"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        mon = None                    # no dbus-monitor → plain polling below

    last = None
    dirty_at = None
    next_poll = 0.0
    while True:
        now = time.monotonic()
        if now >= next_poll or (dirty_at is not None and now >= dirty_at):
            dirty_at = None
            next_poll = now + FULL_POLL
            cur = json.dumps(get_devices(), separators=(",", ":"))
            if cur != last:
                last = cur
                try:
                    sys.stdout.write(cur + "\n")
                    sys.stdout.flush()
                except (BrokenPipeError, OSError):
                    return            # the bar went away
            now = time.monotonic()

        wait = next_poll - now
        if dirty_at is not None:
            wait = min(wait, dirty_at - now)
        wait = max(0.05, min(wait, FULL_POLL))

        if mon is not None and mon.poll() is None:
            ready, _, _ = select.select([mon.stdout], [], [], wait)
            if ready:
                if not mon.stdout.read1(65536):
                    mon = None        # monitor died; fall back to polling
                elif dirty_at is None:
                    dirty_at = time.monotonic() + DEBOUNCE
        else:
            mon = None
            time.sleep(min(wait, 5.0))
            next_poll = min(next_poll, time.monotonic())   # poll every ≤5s without a monitor


# ----------------------------------------------------------------- actions

def device_name(dev_id):
    return get_props(dev_path(dev_id), DEV_IFACE).get("name", "device")


def pick_files():
    if not shutil.which("zenity"):
        notify("install zenity to pick files, or share from your file manager",
               "no file picker", urgency="critical")
        return []
    try:
        res = subprocess.run(["zenity", "--file-selection", "--multiple", "--separator=\n",
                              "--title=Send to your device"],
                             capture_output=True, text=True)
    except OSError:
        return []
    return [p for p in res.stdout.splitlines() if p]


def send_files(dev_id, paths):
    paths = paths or pick_files()
    if not paths:
        return
    sent = 0
    for p in paths:
        p = os.path.abspath(os.path.expanduser(p))
        if not os.path.exists(p):
            continue
        if call(dev_path(dev_id, "share"), DEV_IFACE + ".share", "shareUrl", "s",
                "file://" + p) is not None:
            sent += 1
    name = device_name(dev_id)
    if sent:
        notify("%d file%s → %s" % (sent, "" if sent == 1 else "s", name), "sending")
    else:
        notify("nothing was sent to %s" % name, "share failed", urgency="critical")


def send_clipboard(dev_id):
    text = ""
    if shutil.which("wl-paste"):
        try:
            res = subprocess.run(["wl-paste", "-n"], capture_output=True, text=True, timeout=4)
            text = res.stdout
        except (OSError, subprocess.SubprocessError):
            text = ""
    if not text.strip():
        notify("the clipboard is empty", "nothing to send", urgency="critical")
        return
    call(dev_path(dev_id, "share"), DEV_IFACE + ".share", "shareText", "s", text)
    notify("clipboard → %s" % device_name(dev_id), "sent")


def browse(dev_id):
    sftp = dev_path(dev_id, "sftp")
    iface = DEV_IFACE + ".sftp"
    res = call(sftp, iface, "mountAndWait")
    mount = call(sftp, iface, "mountPoint")
    point = ""
    if mount and mount.get("data"):
        point = mount["data"][0]
    if point and os.path.isdir(point) and shutil.which("xdg-open"):
        subprocess.Popen(["xdg-open", point], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        return
    if res is not None:
        call(sftp, iface, "startBrowsing")   # last resort: let kio open it
        return
    notify("could not mount %s — is sshfs installed?" % device_name(dev_id),
           "browse failed", urgency="critical")


def open_sms(dev_id):
    if call(dev_path(dev_id, "sms"), DEV_IFACE + ".sms", "launchApp") is None:
        notify("install kdeconnect-sms to read messages here", "sms unavailable",
               urgency="critical")


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__.strip())
        return 1
    cmd, rest = argv[0], argv[1:]

    if cmd == "--list":
        print(json.dumps(get_devices(), separators=(",", ":")))
        return 0
    if cmd == "--watch":
        watch()
        return 0

    if not rest:
        print("error: %s needs a device id" % cmd, file=sys.stderr)
        return 1
    dev_id, args = rest[0], rest[1:]

    simple = {
        "--pair":   (DEV_IFACE, "", "requestPairing"),
        "--unpair": (DEV_IFACE, "", "unpair"),
        "--accept": (DEV_IFACE, "", "acceptPairing"),
        "--reject": (DEV_IFACE, "", "cancelPairing"),
        "--ring":   (DEV_IFACE + ".findmyphone", "findmyphone", "ring"),
        "--ping":   (DEV_IFACE + ".ping", "ping", "sendPing"),
    }
    if cmd in simple:
        iface, plugin, member = simple[cmd]
        ok = call(dev_path(dev_id, plugin), iface, member) is not None
        if cmd == "--ring":
            notify("ringing %s" % device_name(dev_id) if ok else "could not ring the device",
                   "find my phone", urgency="low" if ok else "critical")
        elif not ok:
            print("error: %s failed" % cmd, file=sys.stderr)
            return 1
        return 0

    if cmd == "--send-file":
        send_files(dev_id, args)
    elif cmd == "--send-clipboard":
        send_clipboard(dev_id)
    elif cmd == "--browse":
        browse(dev_id)
    elif cmd == "--sms":
        open_sms(dev_id)
    else:
        print("unknown command: %s" % cmd, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, BrokenPipeError):
        os._exit(0)      # skip the shutdown flush — the reader is already gone
