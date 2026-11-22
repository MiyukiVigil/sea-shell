#!/usr/bin/env python3
"""sea-shell — the short list of things that need you.

  sea-attention.py           JSON lines, most urgent first: {id, level, title, detail, action...}
  sea-attention.py dismiss ID  stop showing this until it changes
  sea-attention.py notify      one notification per new act-now problem, for when no page is open

Health check, drive health, fan setup and backups each know something and live on their own
page, so a failing drive stays quiet until you happen to open Disks. This only reads them and
says the part that matters: an empty list means there is nothing to do. It never changes
anything itself; a row's action is something the page does when you press it.

level: bad (act now) | warn (soon) | info (when convenient, can be dismissed)
action: {"tab": N} opens a Settings page, {"run": "fans"} is a named command from RUNS below.
"""
import glob
import hashlib
import json
import os
import platform
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
HOME = os.path.expanduser("~")
DISMISSED = os.path.join(HOME, ".config/sea-shell/attention-dismissed.json")
NOTIFIED = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "sea-shell/attention-notified.json")
ORDER = {"bad": 0, "warn": 1, "info": 2}
BACKUP_STALE_DAYS = 45
TAB_SYSTEM, TAB_DISKS, TAB_POWER = 8, 19, 6


def output(argv, timeout=10):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, "LC_ALL": "C"})
        return r.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def row(id_, level, title, detail, **action):
    return {"id": id_, "level": level, "title": title, "detail": detail, **action}


def doctor_rows(lines):
    """Problems from the health check. Missing optional tools are one row, not ten: each is a
    choice the user may have made on purpose, and a list that nags stops being read."""
    rows, optional = [], []
    for line in lines:
        parts = line.split("|", 3)
        if len(parts) < 4 or parts[0] == "ok":
            continue
        status, area, item, detail = parts
        if area == "optional":
            optional.append(item)
        elif status == "crit":
            rows.append(row("doctor:%s:%s" % (area, item), "bad", "%s: %s" % (area.capitalize(), item), detail,
                            tab=TAB_SYSTEM))
        elif area == "crashes":
            rows.append(row("doctor:crashes", "warn", "The bar has been crashing", detail, tab=TAB_SYSTEM))
    if optional:
        names = ", ".join(sorted(optional))
        rows.append(row("doctor:optional:" + names, "info",
                        "%d optional tool%s missing" % (len(optional), "" if len(optional) == 1 else "s"),
                        "Features that use them won't work: " + names + ".", tab=TAB_SYSTEM))
    return rows


def drive_rows(info):
    rows = []
    for dev, h in info.get("drives", {}).items():
        if h.get("status") == "bad":
            rows.append(row("drive:bad:" + dev, "bad", "%s may be failing" % dev,
                            "The drive reports a serious problem. Back up what matters now.", tab=TAB_DISKS))
        elif h.get("status") == "warn":
            rows.append(row("drive:warn:" + dev, "warn", "%s is wearing out" % dev,
                            "It still works, but plan to back it up and replace it.", tab=TAB_DISKS))
        if h.get("temp", 0) >= 75:
            rows.append(row("drive:hot:" + dev, "warn", "%s is running hot" % dev,
                            "It's at %d°C." % h["temp"], tab=TAB_DISKS))
    return rows


def space_rows(free, total):
    if not total:
        return []
    pct = 100 * (1 - free / total)
    if pct < 85:
        return []
    return [row("space", "bad" if pct >= 95 else "warn", "Your drive is %d%% full" % pct,
                "Disks can show what's safe to clear.", tab=TAB_DISKS)]


def kernel_row(running, modules_dir):
    """Arch removes the running kernel's modules when it upgrades, so new hardware and some USB
    devices stop working until the restart. The folder being gone is the whole signal."""
    if os.path.isdir(os.path.join(modules_dir, running)):
        return []
    return [row("kernel:" + running, "warn", "Restart to finish a kernel update",
                "You're running %s, which has been replaced. Some devices may not work until you restart." % running,
                tab=TAB_POWER)]


def failed_unit_rows(system, user):
    names = system + user
    if not names:
        return []
    return [row("units:" + ",".join(sorted(names)), "warn",
                "%d background service%s failed" % (len(names), "" if len(names) == 1 else "s"),
                ", ".join(names) + ". Check with systemctl status.")]


def fan_row(has_controls, installed, shipped, active):
    if not has_controls:
        return []
    if not installed:
        return [row("fans:setup", "warn", "Finish setting up the fans",
                    "The fan controller needs installing once. It asks for your password.", run="fans")]
    current = shipped if isinstance(shipped, (list, tuple, set)) else (shipped,)
    if shipped is not None and installed not in current:
        return [row("fans:stale", "warn", "Update the fan controller",
                    "The installed one is older than this version of sea-shell. It asks for your password.", run="fans")]
    if not active:
        return [row("fans:stopped", "warn", "The fan controller isn't running",
                    "The firmware's curve is in charge until it's back. It asks for your password.", run="fans")]
    return []


def backup_row(newest, now):
    if newest is None:
        return [row("backup:none", "info", "You have no backups of your settings",
                    "One click saves your settings, pins and keybinds.", run="backup")]
    days = (now - newest) / 86400
    if days < BACKUP_STALE_DAYS:
        return []
    return [row("backup:%d" % (newest // 86400 // BACKUP_STALE_DAYS), "info", "Your last settings backup is %d days old" % days,
                "One click saves a new one.", run="backup")]


def digest(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def json_of(argv):
    try:
        return json.loads(output(argv, 15))
    except ValueError:
        return {}


def units(*scope):
    lines = output(["systemctl", *scope, "--failed", "--no-legend", "--plain"]).splitlines()
    return [line.split()[0] for line in lines if line.strip()]


def gather():
    rows = []
    rows += doctor_rows(output(["sh", os.path.join(HERE, "sea-doctor.sh")], 30).splitlines())
    rows += drive_rows(json_of([sys.executable, os.path.join(HERE, "sea-disk.py"), "info"]))
    stat = os.statvfs(HOME)
    rows += space_rows(stat.f_bavail * stat.f_frsize, stat.f_blocks * stat.f_frsize)
    rows += kernel_row(platform.release(), "/usr/lib/modules")
    rows += failed_unit_rows(units("--system"), units("--user"))
    has_controls = any(open(p).read().strip() == "acer" for p in glob.glob("/sys/class/hwmon/hwmon*/name"))
    active = output(["systemctl", "is-active", "sea-fand"]).strip() == "active"
    shipped = [digest(os.path.join(HERE, "sea-fand.py"))]
    rust = os.path.join(HERE, "sea-fand")
    if os.path.isfile(rust):
        shipped.append(digest(rust))
    rows += fan_row(has_controls, digest("/usr/local/bin/sea-fand"), shipped, active)
    backups = glob.glob(os.path.join(HOME, "Documents/sea-shell-backup-*"))
    rows += backup_row(max((os.path.getmtime(b) for b in backups), default=None), time.time())
    return rows


def load_dismissed():
    try:
        with open(DISMISSED) as f:
            return set(json.load(f))
    except (OSError, ValueError):
        return set()


def visible(rows, dismissed):
    # Only "when convenient" rows can be dismissed. A failing drive doesn't get a "not now".
    kept = [r for r in rows if r["level"] != "info" or r["id"] not in dismissed]
    return sorted(kept, key=lambda r: ORDER[r["level"]])


def notify(rows):
    """A failing drive can't wait for someone to open Settings. Once per problem, and the list is
    rewritten each run so a problem that clears and returns is news again."""
    try:
        with open(NOTIFIED) as f:
            seen = set(json.load(f))
    except (OSError, ValueError):
        seen = set()
    bad = [r for r in rows if r["level"] == "bad"]
    for r in bad:
        if r["id"] not in seen:
            subprocess.run(["notify-send", "-u", "critical", "-a", "sea-shell", r["title"], r["detail"]], check=False)
    os.makedirs(os.path.dirname(NOTIFIED), exist_ok=True)
    with open(NOTIFIED + ".tmp", "w") as f:
        json.dump(sorted(r["id"] for r in bad), f)
    os.replace(NOTIFIED + ".tmp", NOTIFIED)


def main():
    if sys.argv[1:] == ["notify"]:
        notify(gather())
        return
    if sys.argv[1:2] == ["dismiss"] and len(sys.argv) == 3:
        ids = load_dismissed() | {sys.argv[2]}
        os.makedirs(os.path.dirname(DISMISSED), exist_ok=True)
        with open(DISMISSED + ".tmp", "w") as f:
            json.dump(sorted(ids), f)
        os.replace(DISMISSED + ".tmp", DISMISSED)
        return
    for r in visible(gather(), load_dismissed()):
        print(json.dumps(r), flush=True)


if __name__ == "__main__":
    main()
